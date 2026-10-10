defmodule Troupe.Agent.Definitions do
  @moduledoc """
  The immutable snapshot of every agent definition available to a session.

  Loaded once at session start and passed down in `Agent.Node` child specs. There is
  deliberately no process here: definitions do not change under a running agent, so
  they are data, and a subagent three levels down reads them without a message. The one
  exception is a person's: switching a session's agent reads them again from their files
  (`reload/1`), so the agent switched to is the file as it is now (Decision 841).

  Precedence on a laptop, lowest to highest: built-ins shipped in `priv/agents/`, the
  global config dir's `agents/`, then the project's `.troupe/agents/`. A file at a higher
  level replaces the same name below it.

  On a pod the session is pinned to a config bundle, the plane's word, and the agents
  Troupe ships and the bundle's beat every file on the pod's disk of the same name, the
  working copy's above all: a file that arrives with a clone does not stand in for
  `build`, nor for an agent an admin published (Decision 826). Such a file is not read,
  and is listed in `skipped` with the reason. The order there is the directories, then
  the built-ins, then the bundle. A profile that lets a repository's agents win
  (`spec.repositoryOverridesBundle`) puts the laptop's order back, with the bundle between
  the built-ins and the directories, as it was before.

  In a git worktree the project layer is the worktree's own `.troupe/agents/` over the
  main checkout's, of which only what the checkout has committed is read
  (`Troupe.Worktree`).

  A file that does not parse is not read either, and is listed in `skipped` with what is
  wrong with it in words (Decision 841), so a client can show it rather than the person
  finding it in the daemon's log.

  The project layer is held to its workspace (the main checkout's to the checkout) by
  where each file really is, links followed (Decision 829): a file that is a link out of
  it, or a `.troupe/agents` that is one, is not read, and is listed in `skipped`, the
  directory once with no name and not looked into.
  """

  alias Troupe.Agent.{Definition, Validate}
  alias Troupe.{Paths, Workspace, Worktree}

  @enforce_keys [:by_name]
  # `loaded` is how `load/2` read the snapshot and `trusted` how `trust/3` stamped it, so
  # `reload/1` can read it again the same way; `nil` for one built from a list.
  defstruct [:by_name, skipped: [], loaded: nil, trusted: nil]

  @outside_workspace "not read: outside the workspace"
  @outside_checkout "not read: outside the main checkout"

  @typedoc """
  A file found and not read, with why: an agent, a skill (`Troupe.Skills.skipped/2`), a
  command (`Troupe.Commands.Local.skipped/1`) or a workflow (`Troupe.Workflow.skipped/1`),
  the name it would have had, where it is, and a sentence a person can act on. A
  directory not looked into has no name.
  """
  @type skipped :: %{
          kind: :agent | :skill | :command | :workflow,
          name: String.t() | nil,
          path: Path.t(),
          reason: String.t()
        }

  @doc "Why a workspace's own file, linked out of it, is not read (Decision 829)."
  @spec outside_workspace() :: String.t()
  def outside_workspace, do: @outside_workspace

  @doc "Why a worktree's main checkout's file, linked out of the checkout, is not read."
  @spec outside_checkout() :: String.t()
  def outside_checkout, do: @outside_checkout

  @type t :: %__MODULE__{
          by_name: %{optional(String.t()) => Definition.t()},
          skipped: [skipped()],
          loaded: {Path.t() | nil, keyword()} | nil,
          trusted: {boolean(), Path.t()} | nil
        }

  @doc """
  Whether the bundle and the built-ins beat the files on a session's disk of the same
  names, agents and skills alike: wherever the session is pinned to a bundle, which only a
  pod is — a pod whose channel has nothing published is pinned to nothing, and that is a
  pin too — unless the profile lets a repository's files win (Decision 826). The one rule
  both merges ask.
  """
  @spec bundle_wins?(map() | nil) :: boolean()
  def bundle_wins?(%{} = pin), do: Map.get(pin, :repository_overrides) != true
  def bundle_wins?(nil), do: false

  @doc """
  Why a file of a name the bundle has (`owner` `:bundle`), or Troupe ships (`:builtin`), is
  not read on a pod.
  """
  @spec lost_to_bundle(:agent | :skill, String.t(), :bundle | :builtin) :: String.t()
  def lost_to_bundle(kind, name, owner \\ :bundle)

  def lost_to_bundle(kind, name, :bundle) do
    "the session's bundle has #{kind_name(kind)} named #{name}, and on a pod the bundle's " <>
      "beats a repository's unless the profile allows the repository's"
  end

  def lost_to_bundle(kind, name, :builtin) do
    "#{name} is #{kind_name(kind)} Troupe ships, and on a pod Troupe's own beats a " <>
      "repository's unless the profile allows the repository's"
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

  `bundle:` is the session's pin (`t:Troupe.Skills.bundle/0`), whose `dir`'s `agents/` is
  read as the `:bundle` source; it and the built-ins are above every directory unless the
  pin says `repository_overrides: true` (`bundle_wins?/1`). `bundle_dir:` with
  `repository_overrides:` says the same without a pin. Unparseable files are skipped with
  a warning rather than failing the session: one broken custom agent should not stop the
  user from working.

  A `workspace_root` of `nil` has no project layer: the built-ins, the bundle's and the
  person's own, for a client asking about an agent with no workspace in hand.

  `entitled:` is the list of agent names this session's team was granted, or `nil` for
  no restriction. It is applied *after* the whole search order is merged, so an agent
  the team may not run is not in the map at all and nothing further has to know — not
  `fetch/2`, not `primaries/1`, not the delegation tool's list. Filtering at the point
  the bundle is merged would have left a built-in of the same name standing in for it,
  which is a different agent answering to a name somebody was refused.
  """
  @spec load(Path.t() | nil, keyword()) :: t()
  def load(workspace_root, opts \\ []) do
    pin = pin(opts)
    bundle = bundle_layer(pin && pin[:dir])
    project = project_layer(workspace_root)
    {checkout, uncommitted} = checkout_layer(workspace_root, project)
    disk = [layer(Path.join(Paths.config_dir(), "agents"), :global)] ++ checkout ++ [project]
    outside = Enum.flat_map(disk, &Map.get(&1, :outside, []))

    wins? = bundle_wins?(pin)
    acp = Keyword.get(opts, :acp_agents, [])
    {layers, lost} = ordered(layer(builtin_dir(), :builtin), bundle, disk, wins?, acp)
    {by_name, failed} = Enum.reduce(layers, {%{}, []}, &merge_layer/2)

    by_name =
      by_name
      |> merge_acp(acp)
      |> entitled(Keyword.get(opts, :entitled))

    %__MODULE__{
      by_name: by_name,
      skipped: outside ++ uncommitted ++ lost ++ failed,
      loaded: {workspace_root, opts}
    }
  end

  @doc """
  The same definitions read again from their files, as `load/2` read them for this
  snapshot and stamped as `trust/3` stamped it: what a switch of agent reads (Decision
  841), so an agent written or edited since the session started is the one switched to,
  and a restarted agent that was switched comes back on it. One built from a list
  (`from_list/1`) has no files, and is itself.
  """
  @spec reload(t()) :: t()
  def reload(%__MODULE__{loaded: nil} = defs), do: defs

  def reload(%__MODULE__{loaded: {workspace_root, opts}, trusted: trusted}) do
    fresh = load(workspace_root, opts)

    case trusted do
      {trusted?, workspace} -> trust(fresh, trusted?, workspace)
      nil -> fresh
    end
  end

  # The pin, given whole, or as the directory and the profile's word on it.
  defp pin(opts) do
    case Keyword.fetch(opts, :bundle) do
      {:ok, pin} ->
        pin

      :error ->
        case Keyword.get(opts, :bundle_dir) do
          nil -> nil
          dir -> %{dir: dir, repository_overrides: Keyword.get(opts, :repository_overrides)}
        end
    end
  end

  # A layer is a directory, its source, and the names of the files read from it.
  defp layer(dir, source), do: %{dir: dir, source: source, names: names_in(dir)}

  # No workspace, no project layer.
  defp project_layer(nil), do: %{dir: nil, source: :project, names: []}

  defp project_layer(workspace_root) do
    dir = Path.join(Paths.project_dir(workspace_root), "agents")
    held_layer(dir, workspace_root, @outside_workspace)
  end

  # A repository's layer, held to `root` (Decision 829): what is really outside it is not
  # read, and is `outside`, with why; a directory that is itself a link out, once.
  defp held_layer(dir, root, reason) do
    case Workspace.files_within(dir, ".md", root) do
      :outside ->
        %{dir: dir, source: :project, names: [], outside: [skip_dir(dir, reason)]}

      {inside, outside} ->
        %{
          dir: dir,
          source: :project,
          names: inside |> Enum.map(&Path.basename(&1, ".md")) |> Enum.sort(),
          outside: Enum.map(outside, &skip(dir, Path.basename(&1, ".md"), reason))
        }
    end
  end

  defp bundle_layer(nil), do: nil
  defp bundle_layer(dir), do: layer(Path.join(dir, "agents"), :bundle)

  defp ordered(builtin, bundle, disk, false, _acp),
    do: {[builtin | List.wrap(bundle)] ++ disk, []}

  # Where the bundle wins, every directory's file of a built-in's name, the bundle's or its
  # ACP agents', is taken out of its layer, unread, rather than read and replaced: a file
  # that is not read cannot fail to parse into a warning, and the answer names it as what
  # it is, skipped, saying whose name it is. The bundle's is said where a name is both,
  # since that is the one that runs.
  defp ordered(builtin, bundle, disk, true, acp) do
    owners =
      Map.merge(
        Map.new(builtin.names, &{&1, :builtin}),
        Map.new(names_of(bundle) ++ Enum.map(acp, & &1.name), &{&1, :bundle})
      )

    {disk, lost} =
      Enum.map_reduce(disk, [], fn layer, lost ->
        {gone, kept} = Enum.split_with(layer.names, &Map.has_key?(owners, &1))
        skipped = Enum.map(gone, &skip(layer.dir, &1, lost_to_bundle(:agent, &1, owners[&1])))
        {%{layer | names: kept}, lost ++ skipped}
      end)

    {[builtin | disk] ++ List.wrap(bundle), lost}
  end

  defp names_of(nil), do: []
  defp names_of(layer), do: layer.names

  # In a worktree, the main checkout's committed agents, below the worktree's own, held to
  # the checkout. One the checkout has not committed, or that is a link out of it, is
  # listed, unless the worktree has its own of that name and would not have read the
  # checkout's anyway.
  defp checkout_layer(nil, _project), do: {[], []}

  defp checkout_layer(workspace_root, project) do
    with main when is_binary(main) <- Worktree.main(workspace_root),
         dir = Path.join(Paths.project_dir(main), "agents"),
         found = held_layer(dir, main, @outside_checkout),
         outside = Enum.reject(found.outside, &(&1.name in project.names)),
         names = found.names -- project.names,
         true <- names != [] or outside != [] do
      committed =
        if names == [], do: MapSet.new(), else: Worktree.committed(main, ".troupe/agents")

      {kept, drafts} =
        Enum.split_with(names, &MapSet.member?(committed, ".troupe/agents/#{&1}.md"))

      {[%{found | names: kept, outside: outside}],
       Enum.map(drafts, &skip(dir, &1, Worktree.uncommitted(main)))}
    else
      _none -> {[], []}
    end
  end

  defp skip(dir, name, reason),
    do: %{kind: :agent, name: name, path: Path.join(dir, name <> ".md"), reason: reason}

  defp skip_dir(dir, reason), do: %{kind: :agent, name: nil, path: dir, reason: reason}

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

  @doc """
  Say whether `workspace` is trusted, for every definition read from it
  (`Definition.trust/3`, Decision 825): its `auto` entries apply only when it is.
  """
  @spec trust(t(), boolean(), Path.t()) :: t()
  def trust(%__MODULE__{by_name: by_name} = defs, trusted?, workspace) do
    stamp = &Definition.trust(&1, trusted?, workspace)

    %{
      defs
      | by_name: Map.new(by_name, fn {name, definition} -> {name, stamp.(definition)} end),
        trusted: {trusted?, workspace}
    }
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

  # A file that cannot be read or parsed is listed with why, in words, as well as logged:
  # the log is where nobody looks (Decision 841).
  defp merge_file({by_name, failed}, path, source) do
    name = Path.basename(path, ".md")

    with {:ok, contents} <- File.read(path),
         {:ok, definition} <- Definition.parse(name, contents, source) do
      {Map.put(by_name, name, %{definition | path: path}), failed}
    else
      {:error, reason} ->
        require Logger
        Logger.warning("troupe: skipping agent definition #{path}: #{inspect(reason)}")
        why = "not read: " <> Validate.describe(reason)
        {by_name, failed ++ [skip(Path.dirname(path), name, why)]}
    end
  end
end
