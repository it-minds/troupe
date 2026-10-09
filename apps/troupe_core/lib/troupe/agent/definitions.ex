defmodule Troupe.Agent.Definitions do
  @moduledoc """
  The immutable snapshot of every agent definition available to a session.

  Loaded once at session start and passed down in `Agent.Node` child specs. There is
  deliberately no process here: definitions cannot change while a session runs, so
  they are data, and a subagent three levels down reads them without a message.

  Precedence, lowest to highest: built-ins shipped in `priv/agents/`, the global config
  dir's `agents/`, the project's `.troupe/agents/`, and the session's config bundle. A
  file at a higher level replaces the same name below it. A bundle is the plane's word
  and only a pod has one, so its agents beat every file on the pod's disk of the same
  name, the working copy's above all: a file that arrives with a clone does not stand in
  for an agent an admin published (Decision 826). Such a file is not read, and is listed
  in `skipped` with the reason. A profile that lets a repository's agents replace the
  bundle's (`spec.repositoryOverridesBundle`) puts the bundle back below the directories,
  as it was before; on a laptop there is no bundle and nothing changes.

  In a git worktree the project layer is the worktree's own `.troupe/agents/` over the
  main checkout's, of which only what the checkout has committed is read
  (`Troupe.Worktree`).
  """

  alias Troupe.Agent.Definition
  alias Troupe.{Paths, Worktree}

  @enforce_keys [:by_name]
  defstruct [:by_name, skipped: []]

  @typedoc """
  A file found and not read, with why: an agent or a skill (`Troupe.Skills.skipped/2`),
  the name it would have had, where it is, and a sentence a person can act on.
  """
  @type skipped :: %{kind: :agent | :skill, name: String.t(), path: Path.t(), reason: String.t()}

  @type t :: %__MODULE__{
          by_name: %{optional(String.t()) => Definition.t()},
          skipped: [skipped()]
        }

  @doc """
  Whether a session's bundle beats the files on its disk of the same names, agents and
  skills alike: wherever there is a bundle, unless the profile that pinned it lets a
  repository's files replace the bundle's (Decision 826). The one rule both merges ask.
  """
  @spec bundle_wins?(map() | nil) :: boolean()
  def bundle_wins?(%{dir: dir} = bundle) when is_binary(dir),
    do: Map.get(bundle, :repository_overrides) != true

  def bundle_wins?(_bundle), do: false

  @doc "Why a file of a name the bundle has is not read on a pod."
  @spec lost_to_bundle(:agent | :skill, String.t()) :: String.t()
  def lost_to_bundle(kind, name) do
    "the session's bundle has #{kind_name(kind)} named #{name}, and on a pod the bundle's " <>
      "beats a repository's unless the profile allows the repository's"
  end

  defp kind_name(:agent), do: "an agent"
  defp kind_name(:skill), do: "a skill"

  @doc "The files found and not read, each with why."
  @spec skipped(t()) :: [skipped()]
  def skipped(%__MODULE__{skipped: skipped}), do: skipped

  @doc "A skipped file as `files_skipped` records it."
  @spec skipped_to_json(skipped()) :: map()
  def skipped_to_json(%{kind: kind, name: name, path: path, reason: reason}) do
    %{
      "kind" => to_string(kind),
      "name" => name,
      "path" => Paths.display(path),
      "reason" => reason
    }
  end

  @doc """
  Load every definition visible from a workspace.

  `bundle_dir:` names a materialised bundle whose `agents/` is read as the `:bundle`
  source, above every directory unless `repository_overrides: true` says the profile
  lets the repository's replace it (`bundle_wins?/1`). Unparseable files are skipped
  with a warning rather than failing the session: one broken custom agent should not
  stop the user from working.

  `entitled:` is the list of agent names this session's team was granted, or `nil` for
  no restriction. It is applied *after* the whole search order is merged, so an agent
  the team may not run is not in the map at all and nothing further has to know — not
  `fetch/2`, not `primaries/1`, not the delegation tool's list. Filtering at the point
  the bundle is merged would have left a built-in of the same name standing in for it,
  which is a different agent answering to a name somebody was refused.
  """
  @spec load(Path.t(), keyword()) :: t()
  def load(workspace_root, opts \\ []) do
    bundle_dir = Keyword.get(opts, :bundle_dir)
    bundle = bundle_layer(bundle_dir)
    project = layer(Path.join(Paths.project_dir(workspace_root), "agents"), :project)
    {checkout, uncommitted} = checkout_layer(workspace_root, project)
    disk = [layer(Path.join(Paths.config_dir(), "agents"), :global)] ++ checkout ++ [project]

    wins? =
      bundle_wins?(%{
        dir: bundle_dir,
        repository_overrides: Keyword.get(opts, :repository_overrides)
      })

    acp = Keyword.get(opts, :acp_agents, [])
    {layers, lost} = ordered(layer(builtin_dir(), :builtin), bundle, disk, wins?, acp)

    by_name =
      layers
      |> Enum.reduce(%{}, &merge_layer/2)
      |> merge_acp(acp)
      |> entitled(Keyword.get(opts, :entitled))

    %__MODULE__{by_name: by_name, skipped: uncommitted ++ lost}
  end

  # A layer is a directory, its source, and the names of the files read from it.
  defp layer(dir, source), do: %{dir: dir, source: source, names: names_in(dir)}

  defp bundle_layer(nil), do: nil
  defp bundle_layer(dir), do: layer(Path.join(dir, "agents"), :bundle)

  # Where the bundle wins, every directory's file of a bundle name, its ACP agents'
  # included, is taken out of its layer, unread, rather than read and replaced: a file
  # that is not read cannot fail to parse into a warning, and the answer names it as what
  # it is, skipped.
  defp ordered(builtin, nil, disk, _wins?, _acp), do: {[builtin | disk], []}
  defp ordered(builtin, bundle, disk, false, _acp), do: {[builtin, bundle | disk], []}

  defp ordered(builtin, bundle, disk, true, acp) do
    taken = MapSet.new(bundle.names ++ Enum.map(acp, & &1.name))

    {disk, lost} =
      Enum.map_reduce(disk, [], fn layer, lost ->
        {gone, kept} = Enum.split_with(layer.names, &MapSet.member?(taken, &1))
        skipped = Enum.map(gone, &skip(layer.dir, &1, lost_to_bundle(:agent, &1)))
        {%{layer | names: kept}, lost ++ skipped}
      end)

    {[builtin | disk] ++ [bundle], lost}
  end

  # In a worktree, the main checkout's committed agents, below the worktree's own. One the
  # checkout has not committed is listed, unless the worktree has its own of that name and
  # would not have read the checkout's anyway.
  defp checkout_layer(workspace_root, project) do
    with main when is_binary(main) <- Worktree.main(workspace_root),
         dir = Path.join(Paths.project_dir(main), "agents"),
         [_ | _] = names <- names_in(dir) -- project.names do
      committed = Worktree.committed(main, ".troupe/agents")

      {kept, drafts} =
        Enum.split_with(names, &MapSet.member?(committed, ".troupe/agents/#{&1}.md"))

      {[%{dir: dir, source: :project, names: kept}],
       Enum.map(drafts, &skip(dir, &1, Worktree.uncommitted(main)))}
    else
      _none -> {[], []}
    end
  end

  defp skip(dir, name, reason),
    do: %{kind: :agent, name: name, path: Path.join(dir, name <> ".md"), reason: reason}

  defp names_in(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&Path.basename(&1, ".md"))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  # A bundle's ACP agents become ordinary subagent definitions carrying a command instead
  # of a prompt. Doing it here rather than beside the delegation tool is what keeps the rest
  # of the system from learning there is a second kind of delegate: `fetch/2` finds it,
  # `delegate` accepts it, the depth limit applies to it, and it takes a budget slice like
  # anything else.
  #
  # Merged last, after every directory, because a bundle entry is the plane's word and a
  # file on the pod's disk should not be able to stand in for one.
  defp merge_acp(by_name, []), do: by_name

  defp merge_acp(by_name, entries) do
    Enum.reduce(entries, by_name, fn entry, acc ->
      Map.put(acc, entry.name, %Definition{
        name: entry.name,
        mode: :subagent,
        prompt: "",
        description: Map.get(entry, :description) || "An ACP agent: #{entry.command}",
        source: :bundle,
        acp: entry
      })
    end)
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

  defp merge_layer(%{dir: dir, source: source, names: names}, acc) do
    Enum.reduce(names, acc, fn name, acc ->
      merge_file(acc, Path.join(dir, name <> ".md"), source)
    end)
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
