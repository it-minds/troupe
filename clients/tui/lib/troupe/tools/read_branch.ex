defmodule Troupe.Tools.ReadBranch do
  @moduledoc false
  @behaviour Troupe.Tool

  alias Troupe.Session.Log

  @impl true
  def name, do: "read_branch"

  @impl true
  def description,
    do:
      "Return the final summary and task list of a finished branch in this session, by its agent path (for example `code-1`). Without a path, lists the finished branches."

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{"agent_path" => %{"type" => "string"}}
    }
  end

  @impl true
  def default_permission, do: :auto

  @impl true
  def run(args, ctx) do
    case Map.get(args, "agent_path") do
      nil ->
        branches = Log.finished_branches(ctx.session_id)
        {:ok, if(branches == [], do: "no finished branches", else: Enum.join(branches, "\n"))}

      path ->
        case Log.branch_summary(ctx.session_id, path) do
          {:ok, %{summary: summary, todos: todos, prompt: prompt}} ->
            todo_text =
              Enum.map_join(todos, "\n", fn t -> "- [#{t.status}] #{t.content}" end)

            {:ok,
             "branch #{path}\nprompt: #{prompt}\n\nsummary:\n#{summary}\n\ntask list:\n#{todo_text}"}

          {:error, :not_finished} ->
            {:error, "branch #{path} has not finished"}

          {:error, :not_found} ->
            {:error, "no branch #{path}"}
        end
    end
  end
end
