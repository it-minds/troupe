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
  """

  @behaviour Troupe.Tool

  alias Troupe.Agent.Writes
  alias Troupe.Log.Fold
  alias Troupe.Protocol.Event
  alias Troupe.Session.Log
  alias Troupe.Sessions.Index

  @impl Troupe.Tool
  def name, do: "read_branch"

  @impl Troupe.Tool
  def description do
    "List this session's branches, or read what a finished one was asked and answered. A " <>
      "subagent is no branch: its finish is its delegate call's result; only its diff is " <>
      "read here, by `child`."
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
        "child" => %{"type" => "string", "description" => "A subagent, as its finish names it."},
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
  defp read_child(ctx, id, child, diff?) do
    events = events(id, ctx)
    path = child_path(child, ctx)
    mine = Enum.filter(events, &(&1.agent == path))

    case Enum.find(mine, &(&1.type == "agent_started")) do
      nil ->
        {:error, no_child(child, events)}

      %Event{data: data} ->
        with {:ok, summary} <- child_finished(mine, child) do
          {:ok,
           """
           subagent #{Enum.join(path, "/")} (#{data["profile"]})
           brief:
           #{child_brief(mine) || "(none)"}

           finish:
           #{summary}\
           """ <> diff(events, path, diff?)}
        end
    end
  end

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

  defp child_finished(events, child) do
    events
    |> Enum.filter(&(&1.type == "agent_done"))
    |> List.last()
    |> case do
      %Event{data: %{"reason" => "finished"} = data} -> {:ok, data["summary"] || "(no summary)"}
      %Event{data: %{"reason" => reason}} -> {:ok, "(ended: #{reason})"}
      nil -> {:error, "subagent #{child} has not finished"}
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
