defmodule Troupe.Log.Fold do
  @moduledoc """
  The canonical fold of a log, and its hash.

  A session's state is a fold over its events, and that is the property every fixture
  test rests on: the same log must produce the same state in every build that can read
  it. The hash is what makes that checkable — recorded when a release ships and compared
  on every later build, so a fold that quietly changed meaning is caught by CI rather
  than by somebody noticing their session looks wrong.

  ## What this folds, and why it is not the agent's own state

  Rebuilding an agent needs things a log does not contain — the blob store its tool
  results were spilled to, the definitions its profile names refer to — so replaying one
  outside a session is not possible and a fixture test that tried would be testing its
  own scaffolding.

  What is folded instead is a *witness*: every durable event type the agent's replay acts
  on, projected into a shape that changes whenever the meaning of those events changes.
  A clause that stops handling `compacted`, an upcaster that drops `usage`, a `done`
  reason that starts being recorded differently — each moves the hash. That is the whole
  job.

  `witnessed_types/0` is the list, and `Troupe.Log.FoldTest` asserts it still covers what
  the agent replays: adding an event type to the agent's replay without adding it here
  makes CI say so, rather than leaving a blind spot nobody knows about.
  """

  alias Troupe.Log.Upcast
  alias Troupe.Protocol.{Canonical, Event}
  alias Troupe.Session.Summary

  @empty %{
    "agents" => %{},
    "summary" => %{},
    "events" => 0,
    "last_seq" => 0
  }

  @agent %{
    "messages" => 0,
    "last_role" => nil,
    "todos" => [],
    "profile" => nil,
    "done_reason" => nil,
    "input_tokens" => 0,
    "output_tokens" => 0,
    "turns" => 0,
    "tools" => [],
    "approvals" => %{},
    "compactions" => 0
  }

  @doc """
  The durable event types this fold acts on.

  Everything the agent's own replay acts on, plus the ones the summary projection needs.
  """
  @spec witnessed_types() :: [String.t()]
  def witnessed_types do
    ~w(
      agent_started agent_done agent_restarted
      user_input llm_response llm_error
      tool_call_started tool_call_completed tool_results
      todo_updated profile_switched compacted
      approval_requested approval_decided
      session_created session_dormant session_activated config_upgraded
    )
  end

  @doc "Fold a log into the witness a fixture hash is taken over."
  @spec state([Event.t()]) :: map()
  def state(events) do
    events
    |> Upcast.log()
    |> Enum.reduce(@empty, &apply_event(&2, &1))
  end

  @doc """
  The hash of a log's fold: what a fixture records and a later build reproduces.

  Over canonical JSON, so key order and float formatting cannot make two builds that
  agree about the state disagree about the hash.
  """
  @spec hash([Event.t()] | map()) :: String.t()
  def hash(events) when is_list(events), do: events |> state() |> hash()

  def hash(%{} = state) do
    "sha256:" <> (:sha256 |> :crypto.hash(Canonical.encode(state)) |> Base.encode16(case: :lower))
  end

  @doc "Read a JSONL log from disk and fold it."
  @spec file(Path.t()) :: {:ok, map(), String.t()} | {:error, term()}
  def file(path) do
    case File.read(path) do
      {:ok, contents} ->
        events = contents |> String.split("\n", trim: true) |> Enum.map(&decode/1)
        folded = state(events)
        {:ok, folded, hash(folded)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode(line), do: line |> Jason.decode!() |> Event.from_json()

  # -- the witness ------------------------------------------------------------

  defp apply_event(state, %Event{} = event) do
    state
    |> Map.put("events", state["events"] + 1)
    |> Map.put("last_seq", max(state["last_seq"], event.seq || 0))
    |> Map.put("summary", Summary.fold(state["summary"], event))
    |> update_agent(event)
  end

  defp update_agent(state, %Event{agent: nil}), do: state

  defp update_agent(state, %Event{agent: path} = event) do
    key = Enum.join(path, "/")
    agent = Map.get(state["agents"], key, @agent)
    update_in(state, ["agents", key], fn _ -> agent_fold(agent, event) end)
  end

  defp agent_fold(agent, %Event{type: "agent_started", data: data}) do
    %{agent | "profile" => data["profile"]}
  end

  defp agent_fold(agent, %Event{type: "user_input"}) do
    %{agent | "messages" => agent["messages"] + 1, "last_role" => "user"}
  end

  defp agent_fold(agent, %Event{type: "llm_response", data: data}) do
    usage = data["usage"] || %{}

    %{
      agent
      | "messages" => agent["messages"] + 1,
        "last_role" => "assistant",
        "turns" => agent["turns"] + 1,
        "input_tokens" => agent["input_tokens"] + (usage["input_tokens"] || 0),
        "output_tokens" => agent["output_tokens"] + (usage["output_tokens"] || 0)
    }
  end

  defp agent_fold(agent, %Event{type: "tool_results", data: data}) do
    %{
      agent
      | "messages" => agent["messages"] + length(data["results"] || []),
        "last_role" => "tool"
    }
  end

  defp agent_fold(agent, %Event{type: "tool_call_completed", data: data}) do
    %{agent | "tools" => agent["tools"] ++ [%{"name" => data["name"], "ok" => data["ok"]}]}
  end

  defp agent_fold(agent, %Event{type: "todo_updated", data: data}) do
    todos =
      for item <- data["items"] || [], do: %{"content" => item["content"], "status" => item["status"]}

    %{agent | "todos" => todos}
  end

  defp agent_fold(agent, %Event{type: "profile_switched", data: data}) do
    %{agent | "profile" => data["to"]}
  end

  # Compaction replaces the conversation rather than appending to it, which is the one
  # place the message count can go *down* — and therefore the one place a fold that
  # ignored it would drift silently.
  defp agent_fold(agent, %Event{type: "compacted", data: data}) do
    %{
      agent
      | "messages" => length(data["conversation"] || []),
        "compactions" => agent["compactions"] + 1
    }
  end

  defp agent_fold(agent, %Event{type: "agent_done", data: data}) do
    %{agent | "done_reason" => data["reason"]}
  end

  defp agent_fold(agent, %Event{type: "approval_requested", data: data}) do
    put_in(agent, ["approvals", data["call_id"]], "requested")
  end

  defp agent_fold(agent, %Event{type: "approval_decided", data: data}) do
    put_in(agent, ["approvals", data["call_id"]], data["decision"])
  end

  defp agent_fold(agent, %Event{}), do: agent
end
