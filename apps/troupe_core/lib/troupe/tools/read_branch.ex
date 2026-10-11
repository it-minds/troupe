defmodule Troupe.Tools.ReadBranch do
  @moduledoc """
  What a branch of this session said when it finished.

  A branch is a session of its own, created with `parent` set to this one (Decision
  646). It works in its own worktree and its own transcript, and the only thing its
  parent's agent is meant to see is the result — the prompt it was given, the summary
  it finished with, and its task list — which is what a person would read before
  merging it. The transcript itself stays out of the parent's context on purpose:
  that is what keeps a branch cheap to consult.

  Everything here is read off the log on disk (`Troupe.Session.Log.read_session/2`),
  so a branch that has gone dormant reads the same as one still running.

  A subagent is not a branch: what a `delegate` call's subagent found comes back as that
  call's result. An agent that has just delegated takes this tool for the way to read its
  subagents, so the description says otherwise, and a wrong id is answered with the ids
  that exist: a bare "no branch 7" once had a model guess ids one call at a time, for
  hundreds of calls (#116).

  The one thing a finished subagent's result leaves out is the diff of what it wrote: its
  `finish` says what changed as a stat and names the `child` to read here, with `diff`,
  for the rest (#554, Decision 847). The diff is given only when it is asked for, of a
  branch as of a subagent, since a diff handed back unasked is the context a delegation
  exists to save (`Troupe.Agent.Writes`).

  A subagent still at work reads as what it is doing (#554, Decision 853): its goal, its turn,
  the tools in flight or that it waits on its model, its last line, what it has cost so far
  and what runs under it. That is how a parent that started one in the background, and goes
  on working, looks in on it before deciding to wait or to stop it.
  """

  @behaviour Troupe.Tool

  alias Troupe.Agent.{Background, BudgetQuestion, Spend, Writes}
  alias Troupe.LLM.Usage
  alias Troupe.Log.Fold
  alias Troupe.Protocol.Event
  alias Troupe.Session.Log
  alias Troupe.Sessions.Index

  @impl Troupe.Tool
  def name, do: "read_branch"

  @impl Troupe.Tool
  def description do
    "List this session's branches, or read what a finished one was asked and answered. A " <>
      "subagent is no branch: its finish is its delegate call's result; `child` reads one " <>
      "here while it runs, or its diff."
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "session_id" => %{
          "type" => "string",
          "description" => "The branch to read. Leave out to list them."
        },
        "child" => %{"type" => "string", "description" => "A subagent, by its path."},
        "diff" => %{"type" => "boolean", "description" => "Add the full diff of what it wrote."}
      },
      "required" => []
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, ctx) do
    diff? = Map.get(args, "diff") == true

    case {Map.get(args, "session_id"), Map.get(args, "child")} do
      {nil, nil} ->
        {:ok, list(ctx)}

      {id, nil} when is_binary(id) ->
        read(ctx, id, diff?)

      {nil, child} when is_binary(child) ->
        read_child(ctx, ctx.session_id, child, diff?)

      {id, child} when is_binary(id) and is_binary(child) ->
        read_branch_child(ctx, id, child, diff?)

      {id, nil} ->
        {:error, {:invalid_args, "session_id must be a string, got #{inspect(id)}"}}

      {_id, child} ->
        {:error, {:invalid_args, "child must be a string, got #{inspect(child)}"}}
    end
  end

  # -- listing -----------------------------------------------------------------

  # A listing where nothing has finished says so: `/ask`, asked before any branch had, read
  # the states and answered as if one had (D105).
  defp list(ctx) do
    case Enum.map(family(ctx), &line(&1, ctx)) do
      [] ->
        "no branches"

      lines ->
        listing = Enum.map_join(lines, "\n", &elem(&1, 0))

        if Enum.any?(lines, &elem(&1, 1)),
          do: listing,
          else: listing <> "\nNone of them has finished yet, so there is no summary to read."
    end
  end

  # The branches of this session and, when this session is itself a branch, its
  # siblings: what a person looking at the same workspace would see grouped together.
  # Not the session they all came from, which is no branch: `/ask`, a branch of it, read
  # it as one that never started (Decision 843).
  defp family(ctx) do
    mine = Index.list(%{"parent" => ctx.session_id})

    others =
      case Index.get(ctx.session_id) do
        %{parent: parent} when is_binary(parent) -> Index.list(%{"parent" => parent})
        _ -> []
      end

    (mine ++ others)
    |> Enum.reject(&(is_nil(&1) or &1.id == ctx.session_id))
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.created_at)
  end

  # A branch's line, and whether it has finished.
  defp line(meta, ctx) do
    events = events(meta.id, ctx)
    prompt = first_line(prompt_of(events)) || "(no prompt)"

    case done_summary(events) do
      nil ->
        {"#{meta.id}  #{meta.profile}  #{state_of(meta)}  #{prompt}", false}

      summary ->
        {"#{meta.id}  #{meta.profile}  finished  #{prompt}\n    #{first_line(summary)}", true}
    end
  end

  defp state_of(%{state: :active, status: status}), do: to_string(status)
  defp state_of(%{state: state}), do: to_string(state)

  # -- one branch --------------------------------------------------------------

  defp read(ctx, id, diff?) do
    with {:ok, meta} <- fetch_branch(ctx, id),
         events = events(id, ctx),
         {:ok, summary} <- finished(events, id) do
      todos = todos_of(events)

      {:ok,
       ("""
        branch #{id} (#{meta.profile})
        prompt: #{prompt_of(events) || "(none)"}

        summary:
        #{summary}

        task list:
        #{render_todos(todos)}
        """
        |> String.trim_trailing()) <> diff(events, ["root"], diff?)}
    end
  end

  # -- a subagent ----------------------------------------------------------------

  defp read_branch_child(ctx, id, child, diff?) do
    with {:ok, _meta} <- fetch_branch(ctx, id), do: read_child(ctx, id, child, diff?)
  end

  # A subagent of the session `id`, named by its path as its finish gives it, or by its
  # last part when it is one of the reader's own: its brief, what it finished with, and
  # the diff of its writes when that is asked for.
  #
  # One still at work says what it is doing instead (Decision 853): the parent wrote its brief
  # and wants its state, read off the log like the rest.
  defp read_child(ctx, id, child, diff?) do
    events = events(id, ctx)
    path = child_path(child, ctx)
    mine = Enum.filter(events, &(&1.agent == path))

    case Enum.find(mine, &(&1.type == "agent_started")) do
      nil ->
        {:error, no_child(child, events)}

      %Event{data: data} ->
        case child_finished(mine) do
          {:ok, summary} ->
            {:ok,
             """
             subagent #{Enum.join(path, "/")} (#{data["profile"]})
             brief:
             #{child_brief(mine) || "(none)"}

             finish:
             #{summary}\
             """ <> diff(events, path, diff?)}

          :running ->
            {:ok, running(ctx, events, path, data["profile"]) <> diff(events, path, diff?)}
        end
    end
  end

  # What a subagent still at work is doing, from the log: its goal, the model calls it has
  # made, the tools in flight and for how long or that it waits on its model, the last line
  # it wrote, what it and the agents under it have cost, and which of those still run.
  defp running(ctx, events, path, profile) do
    mine = Enum.filter(events, &(&1.agent == path))

    started =
      Enum.find(
        events,
        &match?(%Event{type: "delegation_started", data: %{"child_path" => ^path}}, &1)
      )

    turns = Enum.count(mine, &(&1.type == "llm_request"))

    under =
      events
      |> Enum.filter(
        &(&1.type == "agent_started" and List.starts_with?(&1.agent, path) and &1.agent != path)
      )
      |> Enum.map(& &1.agent)
      |> Enum.reject(fn agent ->
        Enum.any?(events, &(&1.agent == agent and &1.type == "agent_done"))
      end)

    [
      "subagent #{Enum.join(path, "/")} (#{profile}), running",
      "goal: #{goal(started, mine)}",
      "now: turn #{turns}, #{doing(mine)}",
      "last line: #{last_line(events, path)}",
      "cost so far: #{cost(Spend.of(events, path))}"
    ]
    |> Kernel.++(
      if under == [],
        do: [],
        else: ["running under it: " <> Enum.map_join(under, ", ", &Enum.join(&1, "/"))]
    )
    |> Kernel.++(stop_line(ctx, path, started))
    |> Enum.join("\n")
  end

  defp goal(%Event{data: %{"brief" => %{"goal" => goal}}}, _mine) when is_binary(goal), do: goal
  defp goal(_started, mine), do: first_line(child_brief(mine)) || "(none)"

  # The calls it has open, each with how long it has been running, or else what it last did.
  defp doing(mine) do
    case Background.open_calls(mine) do
      [] ->
        last =
          mine
          |> Enum.filter(&(&1.type in ~w(llm_request llm_response llm_error turn_ended)))
          |> List.last()

        case last do
          %Event{type: "llm_request"} = event -> "waiting on its model#{since(event)}"
          %Event{type: "turn_ended"} -> "resting: waiting on subagents of its own"
          _ -> "between steps"
        end

      open ->
        ids = MapSet.new(open, &elem(&1, 0))

        mine
        |> Enum.filter(
          &(&1.type == "tool_call_started" and MapSet.member?(ids, &1.data["call_id"]))
        )
        |> Enum.map_join(", ", &"#{&1.data["name"]} #{brief_args(&1.data["args"])}#{since(&1)}")
        |> then(&("running " <> &1))
    end
  end

  defp brief_args(args) when is_map(args) and map_size(args) > 0 do
    case Jason.encode(args) do
      {:ok, json} when byte_size(json) > 120 -> String.slice(json, 0, 117) <> "..."
      {:ok, json} -> json
      _ -> ""
    end
  end

  defp brief_args(_args), do: ""

  defp since(%Event{ts: ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, at, _offset} -> " for #{max(DateTime.diff(DateTime.utc_now(), at), 0)}s"
      _ -> ""
    end
  end

  defp since(_event), do: ""

  defp last_line(events, path) do
    case Background.last_text(events, path) do
      nil -> "(nothing yet)"
      text -> text |> String.split("\n", trim: true) |> List.last() |> String.slice(0, 300)
    end
  end

  defp cost(%Spend{calls: calls, usage: usage, cost_micros: micros, unpriced: unpriced}) do
    money = if micros > 0, do: ", " <> BudgetQuestion.money(micros), else: ""

    "#{calls} model call#{if calls == 1, do: "", else: "s"}, #{Usage.total_input(usage)} tokens in, " <>
      "#{usage.output_tokens} out#{money}#{if unpriced > 0, do: ", #{unpriced} unpriced", else: ""}"
  end

  # Said to the agent that started it in the background, which is the one that may stop it.
  defp stop_line(ctx, path, %Event{agent: parent, data: %{"wait" => false}}) do
    if parent == ctx.agent_path do
      p = Enum.join(path, "/")
      ["stop_child(child: \"#{p}\") stops it; its end comes to you once it ends."]
    else
      []
    end
  end

  defp stop_line(_ctx, _path, _started), do: []

  defp child_path(child, ctx) do
    case String.split(child, "/", trim: true) do
      [_one] = name -> ctx.agent_path ++ name
      path -> path
    end
  end

  defp child_brief(events) do
    Enum.find_value(events, fn
      %Event{type: "user_input", data: %{"text" => text}} -> text
      _ -> nil
    end)
  end

  # A subagent ended without a finish says how, and what it had done when its parent wrote
  # one for it (Decision 853).
  defp child_finished(events) do
    events
    |> Enum.filter(&(&1.type == "agent_done"))
    |> List.last()
    |> case do
      %Event{data: %{"reason" => "finished"} = data} ->
        {:ok, data["summary"] || "(no summary)"}

      %Event{data: %{"reason" => reason, "summary" => summary}} ->
        {:ok, "(ended: #{reason})\n#{summary}"}

      %Event{data: %{"reason" => reason}} ->
        {:ok, "(ended: #{reason})"}

      nil ->
        :running
    end
  end

  # A wrong path is answered with the subagents there are, as a wrong branch id is.
  defp no_child(child, events) do
    known =
      for %Event{type: "delegation_started", data: %{"child_path" => path}} <- events,
          do: Enum.join(path, "/")

    listed =
      case known do
        [] -> "This session has no subagents."
        _ -> "The subagents there are: " <> Enum.join(known, ", ") <> "."
      end

    "no subagent #{inspect(child)}. #{listed}"
  end

  defp diff(_events, _path, false), do: ""

  defp diff(events, path, true),
    do: "\n\ndiff:\n" <> (events |> Writes.of(path) |> Writes.diff())

  # Only a session in the family is readable: a branch is not a way to open any log on
  # the machine by guessing an id. So a wrong id is answered with the right ones.
  defp fetch_branch(ctx, id) do
    branches = family(ctx)

    case Enum.find(branches, &(&1.id == id)) do
      nil -> {:error, no_branch(id, branches)}
      meta -> {:ok, meta}
    end
  end

  defp no_branch(id, branches) do
    known =
      case branches do
        [] ->
          "This session has no branches."

        _ ->
          "The branches you can read: " <>
            Enum.map_join(branches, ", ", &"#{&1.id} (#{&1.profile})") <> "."
      end

    "no branch #{inspect(id)}. #{known} A subagent started with `delegate` is not a " <>
      "branch: what it found is the result of the delegate call that started it."
  end

  defp finished(events, id) do
    case done_summary(events) do
      nil -> {:error, "branch #{id} has not finished"}
      summary -> {:ok, summary}
    end
  end

  defp events(id, ctx), do: Log.read_session(id, ctx.config && ctx.config.state_dir)

  defp done_summary(events) do
    events
    |> Enum.filter(&match?(%Event{type: "agent_done", agent: ["root"]}, &1))
    |> List.last()
    |> case do
      %Event{data: %{"reason" => "finished"} = data} -> data["summary"] || "(no summary)"
      %Event{data: %{"reason" => reason}} -> "(ended: #{reason})"
      _ -> nil
    end
  end

  defp prompt_of(events) do
    Enum.find_value(events, fn
      %Event{type: "user_input", agent: ["root"], data: %{"text" => text}} -> text
      _ -> nil
    end)
  end

  defp todos_of(events) do
    events
    |> Fold.state()
    |> get_in(["agents", "root", "todos"])
    |> List.wrap()
  end

  defp render_todos([]), do: "(empty)"

  defp render_todos(todos),
    do: Enum.map_join(todos, "\n", &"- [#{&1["status"]}] #{&1["content"]}")

  defp first_line(nil), do: nil

  defp first_line(text) do
    text |> String.split("\n", parts: 2) |> List.first() |> String.trim()
  end
end
