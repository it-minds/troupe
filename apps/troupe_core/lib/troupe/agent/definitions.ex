defmodule Troupe.Agent.Definitions do
  @moduledoc """
  The immutable snapshot of every agent definition available to a session.

  Loaded once at session start and passed down in `Agent.Node` child specs. There is
  deliberately no process here: definitions cannot change while a session runs, so
  they are data, and a subagent three levels down reads them without a message.

  Precedence, lowest to highest: built-ins shipped in `priv/agents/`, the session's
  config bundle, the global config dir's `agents/`, then the project's
  `.troupe/agents/`. A file at a higher level replaces the same name below it. On a
  worker the global and project directories are empty by design, so the bundle is the
  effective source; on a laptop there is no bundle and nothing changes.
  """

  alias Troupe.Agent.Definition
  alias Troupe.Paths

  @enforce_keys [:by_name]
  defstruct [:by_name]

  @type t :: %__MODULE__{by_name: %{optional(String.t()) => Definition.t()}}

  @doc """
  Load every definition visible from a workspace.

  `bundle_dir:` names a materialised bundle whose `agents/` is read as the `:bundle`
  source. Unparseable files are skipped with a warning rather than failing the
  session: one broken custom agent should not stop the user from working.

  `entitled:` is the list of agent names this session's team was granted, or `nil` for
  no restriction. It is applied *after* the whole search order is merged, so an agent
  the team may not run is not in the map at all and nothing further has to know — not
  `fetch/2`, not `primaries/1`, not the delegation tool's list. Filtering at the point
  the bundle is merged would have left a built-in of the same name standing in for it,
  which is a different agent answering to a name somebody was refused.
  """
  @spec load(Path.t(), keyword()) :: t()
  def load(workspace_root, opts \\ []) do
    by_name =
      %{}
      |> merge_dir(builtin_dir(), :builtin)
      |> merge_bundle(Keyword.get(opts, :bundle_dir))
      |> merge_dir(Path.join(Paths.config_dir(), "agents"), :global)
      |> merge_dir(Path.join(Paths.project_dir(workspace_root), "agents"), :project)
      |> entitled(Keyword.get(opts, :entitled))

    %__MODULE__{by_name: by_name}
  end

  # A subagent is not narrowed by the set: the plane's set names primaries, which is
  # what `Bundles.primaries/1` offers and what `session.create` refuses by name. A
  # subagent is reached only by an agent the team *is* entitled to, and narrowing it
  # here would break a bundle's own internal delegation for a team that had simply not
  # listed a name it never names.
  defp entitled(by_name, nil), do: by_name

  defp entitled(by_name, names) when is_list(names) do
    allowed = MapSet.new(names)

    Map.filter(by_name, fn {name, definition} ->
      definition.mode != :primary or MapSet.member?(allowed, name)
    end)
  end

  @doc "Build a snapshot directly from definitions. Tests and embedding."
  @spec from_list([Definition.t()]) :: t()
  def from_list(definitions) do
    %__MODULE__{by_name: Map.new(definitions, &{&1.name, &1})}
  end

  @spec fetch(t(), String.t()) :: {:ok, Definition.t()} | {:error, {:unknown_agent, String.t()}}
  def fetch(%__MODULE__{by_name: by_name}, name) do
    case Map.fetch(by_name, name) do
      {:ok, definition} -> {:ok, definition}
      :error -> {:error, {:unknown_agent, name}}
    end
  end

  @spec fetch!(t(), String.t()) :: Definition.t()
  def fetch!(%__MODULE__{} = defs, name) do
    case fetch(defs, name) do
      {:ok, definition} -> definition
      {:error, reason} -> raise ArgumentError, "no such agent: #{inspect(reason)}"
    end
  end

  @spec all(t()) :: [Definition.t()]
  def all(%__MODULE__{by_name: by_name}), do: by_name |> Map.values() |> Enum.sort_by(& &1.name)

  @doc "Definitions the model may delegate to."
  @spec subagents(t()) :: [Definition.t()]
  def subagents(%__MODULE__{} = defs), do: Enum.filter(all(defs), &(&1.mode == :subagent))

  @doc "Definitions the user may switch the root agent between."
  @spec primaries(t()) :: [Definition.t()]
  def primaries(%__MODULE__{} = defs), do: Enum.filter(all(defs), &(&1.mode == :primary))

  @doc false
  @spec builtin_dir() :: Path.t()
  def builtin_dir, do: Application.app_dir(:troupe_core, "priv/agents")

  defp merge_bundle(acc, nil), do: acc
  defp merge_bundle(acc, dir), do: merge_dir(acc, Path.join(dir, "agents"), :bundle)

  defp merge_dir(acc, dir, source) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.reduce(acc, fn entry, acc -> merge_file(acc, Path.join(dir, entry), source) end)

      {:error, _} ->
        acc
    end
  end

  defp merge_file(acc, path, source) do
    name = Path.basename(path, ".md")

    with {:ok, contents} <- File.read(path),
         {:ok, definition} <- Definition.parse(name, contents, source) do
      Map.put(acc, name, definition)
    else
      {:error, reason} ->
        require Logger
        Logger.warning("troupe: skipping agent definition #{path}: #{inspect(reason)}")
        acc
    end
  end
end
