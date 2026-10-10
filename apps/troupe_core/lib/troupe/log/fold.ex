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
  `delegation_started` is read by the agent for the number its next child takes (Decision
  688) and adds nothing here: the children it started are in the witness already, each an
  agent under its own path, so a change in how those paths are made moves the hash.
  """
  @spec witnessed_types() :: [String.t()]
  def witnessed_types do
    ~w(
      agent_started agent_done agent_woken agent_restarted
      user_input llm_response llm_error
      tool_call_started tool_call_completed tool_results
      todo_updated profile_switched compacted
      goal_set goal_cleared cancelled
      delegation_started
      approval_requested approval_decided
      session_created session_dormant session_activated config_upgraded
      session_tainted user_shell
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

  # The note of the person's own commands the agent was given (Decision 813) is a message
  # like the rest, and gives what it held.
  defp agent_fold(agent, %Event{type: "user_input", data: %{"source" => "shell"}}) do
    agent
    |> Map.merge(%{"messages" => agent["messages"] + 1, "last_role" => "user"})
    |> Map.delete("shell_notes")
  end

  defp agent_fold(agent, %Event{type: "user_input"}) do
    %{agent | "messages" => agent["messages"] + 1, "last_role" => "user"}
  end

  # A person's command the next model call is to be given (Decision 813): held, and present
  # only while one is, as the goal is, so a log without one folds to the map it always did.
  defp agent_fold(agent, %Event{type: "user_shell", data: %{"agent" => true}}),
    do: Map.update(agent, "shell_notes", 1, &(&1 + 1))

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

  # How a `shell` command ended (Decision 837), present only where the event says, as the
  # goal is: a log written before it folds to the map it always did.
  defp agent_fold(agent, %Event{type: "tool_call_completed", data: data}) do
    call =
      data
      |> Map.take(["exit_status", "timed_out"])
      |> Map.merge(%{"name" => data["name"], "ok" => data["ok"]})

    %{agent | "tools" => agent["tools"] ++ [call]}
  end

  defp agent_fold(agent, %Event{type: "todo_updated", data: data}) do
    todos =
      for item <- data["items"] || [], do: %{"content" => item["content"], "status" => item["status"]}

    %{agent | "todos" => todos}
  end

  defp agent_fold(agent, %Event{type: "profile_switched", data: data}) do
    %{agent | "profile" => data["to"]}
  end

  # A key that is present only while there is a goal, rather than one more field in
  # `@agent`: every log written before goals existed then folds to exactly the map it
  # always did, and its recorded hash stands.
  defp agent_fold(agent, %Event{type: "goal_set", data: data}) do
    Map.put(agent, "goal", data["text"])
  end

  defp agent_fold(agent, %Event{type: "goal_cleared"}), do: Map.delete(agent, "goal")

  # A cancel ends the turn it stopped, and what the next one costs is counted from nothing
  # (Decision 769). Present only once there has been one, as the goal is, so a log without
  # a cancel folds to the map it always did.
  defp agent_fold(agent, %Event{type: "cancelled", data: data}),
    do: agent |> Map.update("cancels", 1, &(&1 + 1)) |> add_stopped(data)

  # Compaction replaces the conversation rather than appending to it, which is the one
  # place the message count can go *down* — and therefore the one place a fold that
  # ignored it would drift silently. The summariser's tokens are the agent's (Decision
  # 769); a `compacted` written before it carries none, and adds nothing.
  defp agent_fold(agent, %Event{type: "compacted", data: data}) do
    usage = data["usage"] || %{}

    %{
      agent
      | "messages" => length(data["conversation"] || []),
        "compactions" => agent["compactions"] + 1,
        "input_tokens" => agent["input_tokens"] + (usage["input_tokens"] || 0),
        "output_tokens" => agent["output_tokens"] + (usage["output_tokens"] || 0)
    }
  end

  # The note a root's failed request left in its conversation (Decision 693), a message
  # like the rest. An `llm_error` written before it was has none, so every recorded
  # fixture folds as it did.
  defp agent_fold(agent, %Event{type: "llm_error", data: %{"note" => note} = data})
       when is_binary(note) do
    add_stopped(%{agent | "messages" => agent["messages"] + 1, "last_role" => "user"}, data)
  end

  defp agent_fold(agent, %Event{type: "llm_error", data: data}), do: add_stopped(agent, data)

  defp agent_fold(agent, %Event{type: "agent_done", data: data}) do
    %{agent | "done_reason" => data["reason"]}
  end

  defp agent_fold(agent, %Event{type: "agent_woken"}) do
    %{agent | "done_reason" => nil}
  end

  defp agent_fold(agent, %Event{type: "approval_requested", data: data}) do
    put_in(agent, ["approvals", data["call_id"]], "requested")
  end

  defp agent_fold(agent, %Event{type: "approval_decided", data: data}) do
    put_in(agent, ["approvals", data["call_id"]], data["decision"])
  end

  defp agent_fold(agent, %Event{}), do: agent

  # A call the agent gave up on, on the `llm_error` or `cancelled` that says so (Decision
  # 788): what it had reported is the agent's, as a reply's is. One written before it says
  # nothing, so no recorded fixture's hash moves.
  defp add_stopped(agent, %{"stopped" => %{"usage" => %{} = usage}}) do
    %{
      agent
      | "input_tokens" => agent["input_tokens"] + (usage["input_tokens"] || 0),
        "output_tokens" => agent["output_tokens"] + (usage["output_tokens"] || 0)
    }
  end

  defp add_stopped(agent, _data), do: agent
end
