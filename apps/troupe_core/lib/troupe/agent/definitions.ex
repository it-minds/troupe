defmodule Troupe.Agent.Definitions do
  @moduledoc """
  The immutable snapshot of every agent definition available to a session.

  Loaded once at session start and passed down in `Agent.Node` child specs. There is
  deliberately no process here: definitions cannot change while a session runs, so
  they are data, and a subagent three levels down reads them without a message.

  Precedence, lowest to highest: built-ins shipped in `priv/agents/`, the session's
  config bundle, the global config dir's `agents/`, the agents other tools wrote into
  the workspace (Claude Code's `.claude/agents/`, then the `agent` entries of its
  `opencode.json`, `Troupe.Agent.Imported`, Decision 819), then the project's
  `.troupe/agents/`. A file at a higher level replaces the same name below it. On a
  worker the global and project directories are empty by design, so the bundle is the
  effective source; on a laptop there is no bundle and nothing changes.

  `skipped` lists what was not read as an agent, each with why in words: another tool's
  file or entry Troupe could not read, and one a file of the same name at a higher level
  hid.
  """

  alias Troupe.Agent.{Definition, Imported}
  alias Troupe.Paths

  @enforce_keys [:by_name]
  defstruct [:by_name, skipped: []]

  @type t :: %__MODULE__{
          by_name: %{optional(String.t()) => Definition.t()},
          skipped: [Imported.skip()]
        }

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

  `config:` is the session's configuration, against which another tool's `model` is
  judged (`Troupe.Agent.Imported`): kept when its provider is known to serve it, else
  the agent runs on the session's model.
  """
  @spec load(Path.t(), keyword()) :: t()
  def load(workspace_root, opts \\ []) do
    below =
      %{}
      |> merge_dir(builtin_dir(), :builtin)
      |> merge_bundle(Keyword.get(opts, :bundle_dir))
      |> merge_dir(Path.join(Paths.config_dir(), "agents"), :global)

    imported = Imported.load(workspace_root, below, opts)

    project =
      merge_dir(
        %{},
        Path.join(Paths.project_dir(workspace_root), "agents"),
        :project,
        workspace_root
      )

    by_name =
      below
      |> Map.merge(Map.new(imported.definitions, &{&1.name, &1}))
      |> Map.merge(project)
      |> merge_acp(Keyword.get(opts, :acp_agents, []))
      |> entitled(Keyword.get(opts, :entitled))

    %__MODULE__{
      by_name: by_name,
      skipped: imported.skipped ++ hidden(imported.definitions, project)
    }
  end

  # Troupe's own file of a name wins over another tool's (Decision 819), and the one it
  # hid is said, so nobody edits a `.claude/agents/` file that is never read.
  defp hidden(imported, project) do
    for %Definition{name: name, file: file} <- imported,
        %Definition{file: own} <- [project[name]] do
      %{name: name, file: file, reason: "skipped: #{own} is used"}
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

  # One opencode made both stays a subagent where it is not granted as a primary.
  defp entitled(by_name, names) when is_list(names) do
    allowed = MapSet.new(names)

    by_name
    |> Map.filter(fn {name, definition} ->
      definition.mode != :primary or MapSet.member?(allowed, name)
    end)
    |> Map.new(fn
      {name, %Definition{mode: :all} = definition} ->
        if MapSet.member?(allowed, name),
          do: {name, definition},
          else: {name, %{definition | mode: :subagent}}

      entry ->
        entry
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
  def subagents(%__MODULE__{} = defs), do: Enum.filter(all(defs), &Definition.subagent?/1)

  @doc "Definitions the user may switch the root agent between."
  @spec primaries(t()) :: [Definition.t()]
  def primaries(%__MODULE__{} = defs), do: Enum.filter(all(defs), &Definition.primary?/1)

  @doc false
  @spec builtin_dir() :: Path.t()
  def builtin_dir, do: Application.app_dir(:troupe_core, "priv/agents")

  defp merge_bundle(acc, nil), do: acc
  defp merge_bundle(acc, dir), do: merge_dir(acc, Path.join(dir, "agents"), :bundle)

  defp merge_dir(acc, dir, source, workspace_root \\ nil) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.reduce(acc, fn entry, acc ->
          merge_file(acc, Path.join(dir, entry), source, workspace_root)
        end)

      {:error, _} ->
        acc
    end
  end

  defp merge_file(acc, path, source, workspace_root) do
    name = Path.basename(path, ".md")

    with {:ok, contents} <- File.read(path),
         {:ok, definition} <- Definition.parse(name, contents, source) do
      Map.put(acc, name, %{definition | file: shown(path, source, workspace_root)})
    else
      {:error, reason} ->
        require Logger
        Logger.warning("troupe: skipping agent definition #{path}: #{inspect(reason)}")
        acc
    end
  end

  # Where a person changes the agent: the workspace's file by its place in the workspace,
  # the person's own in full. A built-in's and a bundle's are nobody's to edit here.
  defp shown(path, :project, root), do: Paths.display(Path.relative_to(path, root))
  defp shown(path, :global, _root), do: Paths.display(path)
  defp shown(_path, _source, _root), do: nil
end
