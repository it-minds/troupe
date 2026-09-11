defmodule Troupe.Tools.TodoWrite do
  @moduledoc """
  Replace the agent's whole task list.

  Runs inline in the agent process: the todo list *is* agent state, so a task would
  need either a synchronous call back into the agent or a second copy of the list to
  drift from. It cannot block, so running it in the mailbox is safe.
  """

  @behaviour Troupe.Tool

  alias Troupe.Todo

  @impl Troupe.Tool
  def name, do: "todo_write"

  @impl Troupe.Tool
  def mode, do: :inline

  @impl Troupe.Tool
  def description do
    """
    Replace your task list with the given items. Send the whole list every time, not
    a delta. Exactly one item may be `in_progress`; a list with more is rejected.

    Write the list before you start work on anything with more than two steps, mark
    an item `in_progress` when you begin it, and `completed` the moment it is done.
    """
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "items" => %{
          "type" => "array",
          "description" => "The complete task list, in order.",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{"type" => "string", "description" => "Stable id. Generated if omitted."},
              "content" => %{"type" => "string", "description" => "What the task is."},
              "status" => %{
                "type" => "string",
                "enum" => ["pending", "in_progress", "completed", "cancelled"]
              }
            },
            "required" => ["content"]
          }
        }
      },
      "required" => ["items"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, _ctx) do
    with {:ok, todos} <- Todo.parse_list(Map.get(args, "items", [])) do
      {:ok, "Task list updated:\n" <> Todo.render(todos), %{todos: todos}}
    end
  end
end

defmodule Troupe.Tools.TodoRead do
  @moduledoc "Read the agent's current task list. Inline, for the same reason as `todo_write`."

  @behaviour Troupe.Tool

  alias Troupe.Todo

  @impl Troupe.Tool
  def name, do: "todo_read"

  @impl Troupe.Tool
  def mode, do: :inline

  @impl Troupe.Tool
  def description, do: "Read your current task list."

  @impl Troupe.Tool
  def schema, do: %{"type" => "object", "properties" => %{}, "required" => []}

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(_args, ctx), do: {:ok, Todo.render(ctx.todos)}
end
