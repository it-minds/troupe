defmodule Troupe.Agent.Validate do
  @moduledoc """
  An agent definition checked as it is saved (#503, Decision 841): everything a file can
  get wrong that the loader forgives or drops, as errors and warnings, each naming the
  field it is about with a sentence. `agents.put` writes nothing while there is an error;
  `agents.validate` answers the same list and writes nothing either way.

  The loader is lenient on purpose, since one broken agent should not stop a person
  working: a misspelt key is ignored, a `max_turns` of `"ten"` is no cap, a missing `mode`
  is `subagent`, and a file whose `mode` it does not know is left out with a line in a log.
  The moment somebody writes the file is the one to be loud.

  The rules are `Troupe.Protocol.AgentCheck`'s, which the plane checks a bundle's agents
  with too, so a definition refused here is refused by the console in the same words.
  What only the harness knows is given to it from here: the tools a session has (every
  built-in, a host's own and the pod's MCP servers'), and a model checked against the
  list of what each provider serves that the daemon already keeps (Decision 778), so
  nothing is asked of a provider and a save never waits on one.
  """

  alias Troupe.Config
  alias Troupe.LLM.Catalog.Store
  alias Troupe.Protocol.AgentCheck

  @type finding :: AgentCheck.finding()
  @type result :: AgentCheck.result()

  @doc """
  Check a definition's text. `name:` is the name it would be saved under (checked when
  given); `config:` the `Troupe.Config` its model is checked against (unchecked, with a
  warning, without one).
  """
  @spec check(String.t(), keyword()) :: result()
  def check(source, opts \\ []) when is_binary(source) do
    AgentCheck.check(source,
      name: opts[:name],
      known_tool?: &known_tool?/1,
      tools: Enum.map(Troupe.Tools.all(), &Troupe.Tool.name/1) ++ AgentCheck.scoped_tools(),
      model: model_check(opts[:config])
    )
  end

  @doc """
  What the shared parser's error says, in words: the reason a file that does not load is
  listed with (`Troupe.Agent.Definitions`), and a file that cannot be read.
  """
  @spec describe(term()) :: String.t()
  def describe(reason), do: AgentCheck.describe(reason)

  defp known_tool?(name),
    do: name in AgentCheck.scoped_tools() or match?({:ok, _tool}, Troupe.Tools.fetch(name))

  defp model_check(nil), do: nil
  defp model_check(%Config{} = config), do: &model(&1, config)

  defp model(model, config) do
    case Config.resolve_model(config, model) do
      resolved when is_binary(resolved) and resolved != "" -> served(model, resolved, config)
      _none -> [AgentCheck.error("model", "#{model} names a model the configuration does not set")]
    end
  end

  defp served(model, resolved, config) do
    case Store.served(config, resolved) do
      {:served, _source} ->
        []

      {:not_served, _source, nearest} ->
        [
          AgentCheck.error(
            "model",
            "#{named(model, resolved)} is not a model the provider serves#{near(nearest)}"
          )
        ]

      :unknown ->
        [
          AgentCheck.warning(
            "model",
            "not checked: the provider has not listed its models on this machine " <>
              "(troupe models --refresh asks it)"
          )
        ]
    end
  end

  defp named(model, model), do: model
  defp named(model, resolved), do: "#{model} (#{resolved})"

  defp near([]), do: ""
  defp near(nearest), do: ": the nearest it serves are " <> Enum.join(nearest, ", ")
end
