defmodule Troupe.Agents do
  @moduledoc """
  Loads agent definitions once per session into an immutable snapshot:
  project `.troupe/agents/` over the global config dir's `agents/` over built-ins.
  """

  alias Troupe.Agents.Definition
  alias Troupe.Paths

  @type snapshot :: %{optional(String.t()) => Definition.t()}

  @spec load(String.t()) :: snapshot()
  def load(workspace) do
    builtin = load_dir(Path.join(:code.priv_dir(:troupe), "agents"), :builtin)
    global = load_dir(Path.join(Paths.config_dir(), "agents"), :global)
    project = load_dir(Path.join([workspace, ".troupe", "agents"]), :project)

    builtin |> Map.merge(global) |> Map.merge(project)
  end

  @spec primaries(snapshot()) :: [Definition.t()]
  def primaries(defs),
    do: defs |> Map.values() |> Enum.filter(&(&1.mode == :primary)) |> Enum.sort_by(& &1.name)

  @spec subagents(snapshot()) :: [Definition.t()]
  def subagents(defs),
    do: defs |> Map.values() |> Enum.filter(&(&1.mode == :subagent)) |> Enum.sort_by(& &1.name)

  defp load_dir(dir, source) do
    dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn file, acc ->
      name = Path.basename(file, ".md")

      case Definition.parse(name, File.read!(file), source) do
        {:ok, def} -> Map.put(acc, name, def)
        {:error, _} -> acc
      end
    end)
  end
end
