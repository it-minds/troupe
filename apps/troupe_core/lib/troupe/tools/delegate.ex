defmodule Troupe.Tools.Delegate do
  @moduledoc """
  Hand a self-contained task to a subagent.

  Inline, and deferred: spawning a child means starting a supervised `Agent.Node`
  under *this agent's* `Agent.Children` supervisor and monitoring it, which only the
  agent process can do. `run/2` validates and returns `{:defer, {:delegate, ...}}`;
  the agent does the spawning and completes the tool call when
  `{:child_result, ref, result}` arrives.

  The description is generated from the definitions actually loaded, so a project
  that ships its own subagents advertises them without a code change.
  """

  @behaviour Troupe.Tool

  alias Troupe.Agent.{Definition, Definitions}
  alias Troupe.Tool

  @impl Troupe.Tool
  def name, do: "delegate"

  @impl Troupe.Tool
  def mode, do: :inline

  @impl Troupe.Tool
  def description do
    "Delegate a self-contained task to a subagent and receive its summary."
  end

  @impl Troupe.Tool
  def describe(ctx) do
    """
    Delegate a self-contained task to a subagent. You get back only its final
    summary, never its transcript, so give it everything it needs in `task` and ask
    for what you need back.

    Independent work should be delegated in parallel: issue several `delegate` calls
    in the same turn and they run concurrently.

    Available agents:
    #{agent_list(ctx)}
    """
    |> String.trim()
  end

  defp agent_list(%{definitions: nil}), do: "  (none loaded)"

  defp agent_list(%{definitions: definitions}) do
    case Definitions.subagents(definitions) do
      [] -> "  (none loaded)"
      agents -> Enum.map_join(agents, "\n", fn a -> "  - #{a.name}: #{a.description}" end)
    end
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "agent" => %{"type" => "string", "description" => "Which subagent to use."},
        "task" => %{
          "type" => "string",
          "description" => "The complete task, including any context the subagent needs."
        }
      },
      "required" => ["agent", "task"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, agent} <- Tool.fetch_string(args, "agent"),
         {:ok, task} <- Tool.fetch_string(args, "task"),
         :ok <- check_depth(ctx),
         {:ok, definition} <- fetch_definition(ctx, agent),
         :ok <- check_mode(definition) do
      {:defer, {:delegate, definition.name, task}}
    end
  end

  # Depth is `length(agent_path) - 1`, so the root is 0 and the default cap of 3
  # allows root -> child -> grandchild -> great-grandchild.
  defp check_depth(ctx) do
    depth = length(ctx.agent_path) - 1
    if depth >= ctx.max_depth, do: {:error, {:max_depth, ctx.max_depth}}, else: :ok
  end

  defp fetch_definition(%{definitions: nil}, agent), do: {:error, {:unknown_agent, agent}}

  defp fetch_definition(%{definitions: definitions}, agent),
    do: Definitions.fetch(definitions, agent)

  defp check_mode(%Definition{mode: :subagent}), do: :ok

  defp check_mode(%Definition{name: name}) do
    {:error, "#{name} is a primary profile, not a subagent. Delegate to a subagent instead."}
  end
end

defmodule Troupe.Tools.Finish do
  @moduledoc """
  How a subagent returns its result to its parent.

  Deferred like `delegate`: the agent turns it into a `{:child_result, ref, result}`
  message to the parent and moves to `:done`. The parent sees only this summary.
  """

  @behaviour Troupe.Tool

  alias Troupe.Tool

  @impl Troupe.Tool
  def name, do: "finish"

  @impl Troupe.Tool
  def mode, do: :inline

  @impl Troupe.Tool
  def description do
    """
    Finish your task and return a summary to whoever delegated it to you.

    The summary is all your parent will see — not this conversation, not the tool
    calls. State what you did, which files you touched, what you concluded, and
    anything the parent needs in order to continue.
    """
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "summary" => %{"type" => "string", "description" => "The result, in full."}
      },
      "required" => ["summary"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, _ctx) do
    with {:ok, summary} <- Tool.fetch_string(args, "summary") do
      {:defer, {:finish, summary}}
    end
  end
end
