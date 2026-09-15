defmodule Troupe.Tools.TodoWrite do
  @moduledoc "Schema only; executed by `Agent.Server` because it mutates agent state."
  @behaviour Troupe.Tool

  @impl true
  def name, do: "todo_write"

  @impl true
  def description,
    do:
      "Replace the whole task list. Items have `id`, `content` and `status` (pending | in_progress | completed | cancelled). At most one item may be in_progress."

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "items" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{"type" => "string"},
              "content" => %{"type" => "string"},
              "status" => %{
                "type" => "string",
                "enum" => ["pending", "in_progress", "completed", "cancelled"]
              }
            },
            "required" => ["id", "content", "status"]
          }
        }
      },
      "required" => ["items"]
    }
  end

  @impl true
  def default_permission, do: :auto

  @impl true
  def run(_args, _ctx), do: {:error, "todo_write is executed by the agent"}
end

defmodule Troupe.Tools.TodoRead do
  @moduledoc "Schema only; executed by `Agent.Server`."
  @behaviour Troupe.Tool

  @impl true
  def name, do: "todo_read"

  @impl true
  def description, do: "Return the current task list."

  @impl true
  def schema, do: %{"type" => "object", "properties" => %{}}

  @impl true
  def default_permission, do: :auto

  @impl true
  def run(_args, _ctx), do: {:error, "todo_read is executed by the agent"}
end

defmodule Troupe.Tools.Finish do
  @moduledoc "Schema only; executed by `Agent.Server`."
  @behaviour Troupe.Tool

  @impl true
  def name, do: "finish"

  @impl true
  def description,
    do:
      "Finish your work and return a final summary. Call this exactly once when the task is complete or cannot proceed. For a branch this ends the branch."

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{"summary" => %{"type" => "string"}},
      "required" => ["summary"]
    }
  end

  @impl true
  def default_permission, do: :auto

  @impl true
  def run(_args, _ctx), do: {:error, "finish is executed by the agent"}
end
