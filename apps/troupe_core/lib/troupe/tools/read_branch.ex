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
  """

  @behaviour Troupe.Tool

  alias Troupe.Log.Fold
  alias Troupe.Protocol.Event
  alias Troupe.Session.Log
  alias Troupe.Sessions.Index

  @impl Troupe.Tool
  def name, do: "read_branch"

  @impl Troupe.Tool
  def description do
    "List this session's branches, or read what a finished one was asked and what it " <>
      "answered. A branch is a separate session started from this one, by the person or " <>
      "by the librarian. A subagent you started with `delegate` is not a branch: what it " <>
      "found is the result of the delegate call that started it."
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "session_id" => %{
          "type" => "string",
          "description" =>
            "The session id of the branch to read, as the listing gives it. Leave out to " <>
              "list every branch of this session with its state."
        }
      },
      "required" => []
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, ctx) do
    case Map.get(args, "session_id") do
      nil -> {:ok, list(ctx)}
      id when is_binary(id) -> read(ctx, id)
      other -> {:error, {:invalid_args, "session_id must be a string, got #{inspect(other)}"}}
    end
  end

  # -- listing -----------------------------------------------------------------

  defp list(ctx) do
    case family(ctx) do
      [] -> "no branches"
      branches -> Enum.map_join(branches, "\n", &line(&1, ctx))
    end
  end

  # The branches of this session and, when this session is itself a branch, its
  # siblings and the session they all came from: what a person looking at the same
  # workspace would see grouped together.
  defp family(ctx) do
    mine = Index.list(%{"parent" => ctx.session_id})

    others =
      case Index.get(ctx.session_id) do
        %{parent: parent} when is_binary(parent) ->
          [Index.get(parent) | Index.list(%{"parent" => parent})]

        _ ->
          []
      end

    (mine ++ others)
    |> Enum.reject(&(is_nil(&1) or &1.id == ctx.session_id))
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.created_at)
  end

  defp line(meta, ctx) do
    events = events(meta.id, ctx)
    prompt = first_line(prompt_of(events)) || "(no prompt)"

    case done_summary(events) do
      nil -> "#{meta.id}  #{meta.profile}  #{state_of(meta)}  #{prompt}"
      summary -> "#{meta.id}  #{meta.profile}  finished  #{prompt}\n    #{first_line(summary)}"
    end
  end

  defp state_of(%{state: :active, status: status}), do: to_string(status)
  defp state_of(%{state: state}), do: to_string(state)

  # -- one branch --------------------------------------------------------------

  defp read(ctx, id) do
    with {:ok, meta} <- fetch_branch(ctx, id),
         events = events(id, ctx),
         {:ok, summary} <- finished(events, id) do
      todos = todos_of(events)

      {:ok,
       """
       branch #{id} (#{meta.profile})
       prompt: #{prompt_of(events) || "(none)"}

       summary:
       #{summary}

       task list:
       #{render_todos(todos)}
       """
       |> String.trim_trailing()}
    end
  end

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
