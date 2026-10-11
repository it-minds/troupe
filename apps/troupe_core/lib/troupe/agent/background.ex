defmodule Troupe.Agent.Background do
  @moduledoc """
  The subagents a parent started with `wait: false` (#554, Decision 853): what the parent is
  told as one starts, what it is handed once one ends, and what a stop writes.

  A background child runs as a waited-for one does, under its parent's `Agent.Children`,
  with its brief, its slice of the budget and its depth. What differs is the parent: its
  `delegate` call answers at once (`started/1`), and the child's end reaches it later, once,
  as a message of its own (`reported/2`, `from_done/2`), which the parent writes as a
  `user_input` from `subagent` before its next model call (`input/1`). That record is how a
  restart knows which ends were handed over and which it still owes (`held/2`).

  A stop is the parent's to write (`stop/4`): it has ended the child's Node, which took
  every agent under it, and it closes their logs as a restart closes a child nothing starts
  again (Decision 693): each call still open, then `agent_done`. The child's carries a report
  in Decision 847's parts, its `changed` counted from what it wrote before it was stopped.
  """

  alias Troupe.Agent.{Spend, Writes}
  alias Troupe.LLM.Message
  alias Troupe.Protocol.Event
  alias Troupe.Session.Log
  alias Troupe.Tools.Finish

  @typedoc "An end held for the parent's model: whose it is, how it ended, what it is told."
  @type ended :: %{path: [String.t()], ended: String.t(), text: String.t()}

  # What an end is called, by the `agent_done` reason it came with. Every way a subagent
  # ends short of its finish that hands over what it had (Decisions 659, 660, 688) is cut
  # short; the rest are the stops this decision adds and a restart's.
  @own ~w(finished stopped cancelled interrupted failed)

  @doc "A subagent's path as a reader writes it: its whole path, or its last part for one of the reader's own."
  @spec path(String.t(), [String.t()]) :: [String.t()]
  def path(child, agent_path) do
    case String.split(child, "/", trim: true) do
      [_one] = name -> agent_path ++ name
      path -> path
    end
  end

  @doc "A path as the tools and the messages name it: `root/general#1`."
  @spec label([String.t()]) :: String.t()
  def label(path), do: Enum.join(path, "/")

  @doc "What a `delegate` call answers when its child starts in the background."
  @spec started([String.t()]) :: String.t()
  def started(path) do
    p = label(path)

    "#{p} is working in the background. Its end comes to you once, as a message of its own: " <>
      "before your next step, or as your next turn once you end yours, which is how to wait " <>
      "for it. Meanwhile read_branch(child: \"#{p}\") says what it is doing, and " <>
      "stop_child(child: \"#{p}\") stops it."
  end

  @doc "A child's end as it reported it: its finish, or what it had when it was cut short."
  @spec reported([String.t()], {:ok | :partial, String.t(), term()}) :: ended()
  def reported(path, {:ok, summary, _spent}), do: ended(path, "finished", summary)
  def reported(path, {:partial, summary, _spent}), do: ended(path, "cut_short", summary)

  @doc "An end as the child's `agent_done` says it."
  @spec from_done([String.t()], map()) :: ended()
  def from_done(path, data) do
    ended = if data["reason"] in @own, do: data["reason"], else: "cut_short"
    ended(path, ended, data["summary"] || "(no report)")
  end

  @doc "The `user_input` an end is handed over as."
  @spec input(ended()) :: map()
  def input(%{path: path, ended: ended, text: text}),
    do: %{"source" => "subagent", "text" => text, "child_path" => path, "ended" => ended}

  defp ended(path, ended, report),
    do: %{path: path, ended: ended, text: header(label(path), ended) <> "\n\n" <> report}

  defp header(p, "finished"),
    do: "[#{p}, which you started in the background, has finished. Its report:]"

  defp header(p, "stopped"), do: "[You stopped #{p} before it finished. What it had done:]"

  defp header(p, "cancelled"),
    do:
      "[#{p}, which you started in the background, was stopped when the turn was cancelled. What it had done:]"

  defp header(p, "interrupted"),
    do:
      "[#{p}, which you started in the background, was stopped when you restarted. What it had done:]"

  defp header(p, "failed"),
    do: "[#{p}, which you started in the background, failed past its restarts. What it had done:]"

  defp header(p, _cut_short),
    do: "[#{p}, which you started in the background, ended before it finished. Its report:]"

  @doc """
  Close the log of a child its parent has just ended, and of every agent under it, and say
  what it had done. `reason` is `stopped` (by `by`, its parent), `cancelled`, `interrupted`
  or `failed`. A child that wrote its `agent_done` just before is left as it is, and its own
  end is the one handed over. Returns the end and what the log says the child spent.
  """
  @spec stop(String.t(), [String.t()], String.t(), [String.t()] | nil) :: {ended(), Spend.t()}
  def stop(session_id, path, reason, by) do
    events = Log.replay(session_id)
    spent = Spend.of(events, path)

    case last_done(events, path) do
      %Event{type: "agent_done", data: data} ->
        {from_done(path, data), spent}

      _running ->
        report = stopped_report(events, path, session_id, reason)

        child =
          %{
            "reason" => reason,
            "summary" => Finish.render(report),
            "report" => report,
            "turn" => Spend.to_json(spent)
          }
          |> then(&if(by, do: Map.put(&1, "by", by), else: &1))

        close(session_id, events, path, reason, child)
        {ended(path, reason, child["summary"]), spent}
    end
  end

  # What a child ended without a finish had done: what it last said, and what its file tools
  # changed, counted as a finish's is (Decision 847). Nothing it did not say is taken as
  # checked.
  defp stopped_report(events, path, session_id, reason) do
    summary =
      case last_text(events, path) do
        nil -> "#{how(reason)} before it said anything."
        text -> "#{how(reason)} before it finished. The last it said:\n#{text}"
      end

    %{
      "summary" => summary,
      "ran" => "not said",
      "passed" => "not said",
      "unverified" => "all of it: it did not finish",
      "needs" => "not said",
      "changed" => Writes.changed(events, path, session_id)
    }
  end

  defp how("stopped"), do: "It was stopped by its parent"
  defp how("cancelled"), do: "It was stopped when the turn was cancelled"
  defp how("interrupted"), do: "It was stopped when its parent restarted"
  defp how(_failed), do: "It failed past its restarts"

  # Deepest first, as a restart closes them, so an agent's own `agent_done` follows its
  # children's.
  defp close(session_id, events, path, reason, child) do
    events
    |> Enum.filter(&under?(&1.agent, path))
    |> Enum.group_by(& &1.agent)
    |> Enum.sort_by(fn {agent, _own} -> -length(agent) end)
    |> Enum.each(fn {agent, own} ->
      for {call_id, name} <- open_calls(own) do
        Log.append(session_id, agent, :tool_call_completed, %{
          "call_id" => call_id,
          "name" => name,
          "ok" => false,
          "content" => "#{reason}: the subagent was ended before this finished"
        })
      end

      cond do
        agent == path -> Log.append(session_id, agent, :agent_done, child)
        match?(%Event{type: "agent_done"}, last_done(own, agent)) -> :ok
        true -> Log.append(session_id, agent, :agent_done, %{"reason" => reason})
      end
    end)
  end

  @doc """
  The ends of the background children of the agent at `agent_path` that it was never
  handed, oldest first, for a restart to hold again: one that ended is handed over as its
  `agent_done` says; one with no end went down with this agent's Node and is closed here
  as `interrupted`. Only a delegation whose call had answered: one that had not is taken up
  again or closed with its call.
  """
  @spec held(String.t(), [String.t()]) :: [ended()]
  def held(session_id, agent_path) do
    events = Log.replay(session_id)
    mine = Enum.filter(events, &(&1.agent == agent_path))

    answered =
      for %Event{type: "tool_call_completed", data: %{"call_id" => id}} <- mine,
          into: MapSet.new(),
          do: id

    handed =
      for %Event{type: "user_input", data: %{"source" => "subagent", "child_path" => path}} <-
            mine,
          into: MapSet.new(),
          do: path

    for %Event{type: "delegation_started", data: %{"wait" => false} = data} <- mine,
        MapSet.member?(answered, data["call_id"]),
        path = data["child_path"],
        is_list(path) and not MapSet.member?(handed, path) do
      case last_done(events, path) do
        %Event{type: "agent_done", data: done} ->
          from_done(path, done)

        _running ->
          {ended, _spent} = stop(session_id, path, "interrupted", nil)
          ended
      end
    end
  end

  @doc "Whether this agent ever started a child in the background, which `held/2` reads the whole log for."
  @spec any?([Event.t()]) :: boolean()
  def any?(events),
    do:
      Enum.any?(events, &match?(%Event{type: "delegation_started", data: %{"wait" => false}}, &1))

  @doc "The last line of text the agent at `path` wrote, trimmed, or `nil` before it wrote any."
  @spec last_text([Event.t()], [String.t()]) :: String.t() | nil
  def last_text(events, path) do
    events
    |> Enum.filter(&match?(%Event{type: "llm_response", agent: ^path}, &1))
    |> Enum.reverse()
    |> Enum.find_value(fn %Event{data: data} ->
      case data["message"] do
        %{} = message ->
          message |> Message.from_json() |> Message.text() |> String.trim() |> blank()

        _ ->
          nil
      end
    end)
  end

  defp blank(""), do: nil
  defp blank(text), do: text

  @doc "The calls of one agent's events that started and never completed, oldest first."
  @spec open_calls([Event.t()]) :: [{String.t(), String.t()}]
  def open_calls(events) do
    completed =
      for %Event{type: "tool_call_completed", data: %{"call_id" => id}} <- events,
          into: MapSet.new(),
          do: id

    for %Event{type: "tool_call_started", data: %{"call_id" => id} = data} <- events,
        not MapSet.member?(completed, id),
        do: {id, data["name"]}
  end

  defp last_done(events, path) do
    events
    |> Enum.filter(&(&1.agent == path and &1.type in ["agent_done", "agent_woken"]))
    |> List.last()
  end

  defp under?(agent, path) when is_list(agent), do: List.starts_with?(agent, path)
  defp under?(_agent, _path), do: false
end
