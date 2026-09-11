defmodule Troupe.Tools.Delegate do
  @moduledoc "Schema only; executed by `Agent.Server`, which spawns the child under `Agent.Children`."
  @behaviour Troupe.Tool

  alias Troupe.Agents.Definition

  @impl true
  def name, do: "delegate"

  @impl true
  def description, do: description(%{})

  @doc "Description generated from the subagent definitions, naming each model alias."
  @spec description(%{optional(String.t()) => Definition.t()}) :: String.t()
  def description(definitions) do
    subagents =
      definitions
      |> Map.values()
      |> Enum.filter(&(&1.mode == :subagent))
      |> Enum.sort_by(& &1.name)
      |> Enum.map_join("\n", fn d -> "- `#{d.name}` (model: #{d.model}): #{d.description}" end)

    """
    Delegate a self-contained task to a subagent and get back its final summary (never its transcript). Several delegate calls in one turn run concurrently. Choose the agent by cost and capability:
    #{subagents}
    """
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "agent" => %{"type" => "string", "description" => "Subagent name"},
        "prompt" => %{"type" => "string", "description" => "Complete, self-contained instructions"}
      },
      "required" => ["agent", "prompt"]
    }
  end

  @impl true
  def default_permission, do: :auto

  @impl true
  def run(_args, _ctx), do: {:error, "delegate is executed by the agent"}
end
