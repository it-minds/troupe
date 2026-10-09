defmodule Troupe.Skills.Local do
  @moduledoc """
  The skills a person keeps themselves, in two layers beside the MCP servers
  (Decision 700).

      <config>/skills/<name>/SKILL.md          the user's, on every workspace
      <workspace>/.troupe/skills/<name>/SKILL.md   the workspace's

  A skill is a directory in the Agent Skills convention, the same shape a bundle
  carries and the same shape `~/.claude/skills` holds, so one is *imported* by copying
  its directory into a layer, or *linked* by writing the directory it lives in into
  the layer's `skills.json` (`{"include": [path]}`), which reads it in place. Each entry
  of `include` is a directory of skills — `~/.claude/skills` — or one skill's own
  directory; both are read.

  Below those two sit the `.agents/skills` directories of the convention other tools
  read, in place and never written (Decision 822):

      ~/.agents/skills/<name>/SKILL.md      the person's, on every workspace
      <dir>/.agents/skills/<name>/SKILL.md  in the workspace and each directory above it,
                                            up to the repository root

  Names are resolved up one ladder, lowest first: `~/.agents/skills`, each
  `.agents/skills` from the repository root down to the workspace, the user's layer, the
  workspace's. A name higher up wins, so the nearest `.agents/skills` beats one farther
  out, Troupe's own layers beat `.agents/`, and the workspace's beats the user's, as the
  MCP layers do; within a layer its own directory wins over what it links. Each skill a
  name higher up hid is listed as `skipped`, saying which one is used (`resolve/2`). An
  `.agents/skills`, or a skill in it, that is really outside its edge (the repository
  root, or `~/.agents` for the person's), through a link, is listed as `outside` and not
  read, as instruction files are (Decision 798).

  Unlike a bundle's skills, which a profile lists by name because an admin published
  them for particular agents, a person's own skills are offered to every agent of the
  session: the person put them there, for their own work, and a skill nobody can call
  is not one. The files beside a skill are read with `read_file`, so the layers'
  directories, the `.agents/skills` outside the workspace and the linked roots are read
  roots of the session (`Troupe.Session.build_opts/1`).
  """

  alias Troupe.Config.{JSONC, Migrate}
  alias Troupe.Instructions
  alias Troupe.Protocol.{AgentDefinition, Bundle}
  alias Troupe.Workspace

  @typedoc """
  Where a skill comes from, lowest on the ladder first: `user_agents` (`~/.agents/skills`),
  `agents` (an `.agents/skills` in the repository), `user` (`<config>/skills`) and
  `workspace` (`.troupe/skills`). Only the last two are written to.
  """
  @type layer :: :user_agents | :agents | :user | :workspace

  @typedoc "One skill as the layers give it: what a prompt lists, and where it is."
  @type skill :: %{
          name: String.t(),
          description: String.t(),
          layer: layer(),
          dir: Path.t(),
          source: Path.t(),
          linked?: boolean()
        }

  @typedoc """
  A skill the layers hold and do not offer, and why, in `reason`: `skipped` when a name
  higher on the ladder hid it, or when its directory's name is not one a skill may have;
  `outside` when it is really outside its edge and was not read. An `.agents/skills`
  that is itself a link out is one entry, with no `name`, and is not looked into.
  """
  @type left_out :: %{
          name: String.t() | nil,
          layer: layer(),
          dir: Path.t(),
          source: Path.t(),
          linked?: boolean(),
          status: :skipped | :outside,
          reason: String.t()
        }

  @outside_repository "not read: outside the repository"
  @outside_home "not read: outside ~/.agents"
  @not_a_name "skipped: not a skill name: lower-case letters, digits and dashes"

  # -- where -------------------------------------------------------------------------

  @doc "The user's skills directory, beside `config.yaml`."
  @spec user_dir(keyword()) :: Path.t()
  def user_dir(opts \\ []),
    do: Keyword.get(opts, :user_dir) || Path.join(Troupe.Paths.config_dir(), "skills")

  @doc """
  The person's own `.agents` directory, in their home, whose `skills/` is the user level
  of the `.agents/skills` convention; `nil` when there is no home to look in. A test
  names another with `agents_home:`, or for a whole suite the `:troupe_core, :agents_home`
  setting.
  """
  @spec agents_home(keyword()) :: Path.t() | nil
  def agents_home(opts \\ []) do
    Keyword.get(opts, :agents_home) || Application.get_env(:troupe_core, :agents_home) ||
      case System.user_home() do
        nil -> nil
        home -> Path.join(home, ".agents")
      end
  end

  @doc "A workspace's `.troupe/skills`."
  @spec workspace_dir(Path.t()) :: Path.t()
  def workspace_dir(workspace), do: Path.join(Troupe.Paths.project_dir(workspace), "skills")

  @typedoc "Where a layer keeps its skills, and the `skills.json` beside it that links others."
  @type paths :: %{dir: Path.t(), links: Path.t()}

  @doc "The layer's directory, and the `skills.json` beside it that links others."
  @spec layer_paths(layer(), Path.t() | nil, keyword()) :: {:ok, paths()} | {:error, String.t()}
  def layer_paths(:user, _workspace, opts) do
    dir = user_dir(opts)
    {:ok, %{dir: dir, links: Path.join(Path.dirname(dir), "skills.json")}}
  end

  def layer_paths(:workspace, workspace, _opts) when is_binary(workspace) do
    {:ok,
     %{
       dir: workspace_dir(workspace),
       links: Path.join(Troupe.Paths.project_dir(workspace), "skills.json")
     }}
  end

  def layer_paths(:workspace, nil, _opts), do: {:error, "the workspace scope needs a workspace"}

  def layer_paths(other, _workspace, _opts),
    do: {:error, "scope must be user or workspace, not #{inspect(other)}"}

  # -- reading -----------------------------------------------------------------------

  @doc """
  Every skill the layers give a workspace, by name, the one highest on the ladder.
  `nil` for the workspace reads the person's layers alone.
  """
  @spec list(Path.t() | nil, keyword()) :: [skill()]
  def list(workspace, opts \\ []), do: resolve(workspace, opts).skills

  @doc """
  What `list/2` offers, and every skill the layers hold and do not offer, with why
  (Decision 822): each one a name higher on the ladder hid, saying which is used, and
  each one outside its edge, never read. The ladder is enforced here and nowhere else;
  `skipped` is in ladder order, lowest first.
  """
  @spec resolve(Path.t() | nil, keyword()) :: %{skills: [skill()], skipped: [left_out()]}
  def resolve(workspace, opts \\ []) do
    found = ladder(workspace, opts)

    offered =
      found
      |> Enum.reject(&Map.has_key?(&1, :status))
      |> Enum.reduce(%{}, fn skill, acc -> Map.put(acc, skill.name, skill) end)

    skipped =
      for entry <- found, Map.get(offered, entry.name) != entry, do: left_out(entry, offered)

    %{skills: offered |> Map.values() |> Enum.sort_by(& &1.name), skipped: skipped}
  end

  # Lowest first: what is later in the list wins a name.
  defp ladder(workspace, opts) do
    agents =
      Enum.flat_map(agents_dirs(workspace, opts), fn {layer, dir, edge, outside} ->
        agents_skills(layer, dir, edge, outside)
      end)

    layers = [:user] ++ if(workspace, do: [:workspace], else: [])

    agents ++
      Enum.flat_map(layers, fn layer ->
        {:ok, paths} = layer_paths(layer, workspace, opts)
        layer_skills(layer, paths)
      end)
  end

  defp left_out(%{status: _} = entry, _offered), do: Map.drop(entry, [:description])

  defp left_out(skill, offered) do
    used = Map.fetch!(offered, skill.name)

    skill
    |> Map.drop([:description])
    |> Map.merge(%{status: :skipped, reason: "skipped: #{show(used.dir)} is used"})
  end

  @doc """
  The directories a session must be able to read for its local skills' files: the
  user's layer, the `.agents/skills` inside their edges, and every linked root. The
  workspace's own layer is inside the workspace already. Only what exists, since a read
  root that is not there resolves nothing.
  """
  @spec roots(Path.t() | nil, keyword()) :: [Path.t()]
  def roots(workspace, opts \\ []) do
    {:ok, user} = layer_paths(:user, nil, opts)

    workspace_links =
      case workspace && layer_paths(:workspace, workspace, opts) do
        {:ok, paths} -> links(paths.links)
        _ -> []
      end

    agents =
      for {_layer, dir, edge, _outside} <- agents_dirs(workspace, opts),
          File.dir?(dir) and under?(key(dir), key(edge)),
          do: dir

    (agents ++ [user.dir] ++ links(user.links) ++ workspace_links)
    |> Enum.filter(&File.dir?/1)
    |> Enum.uniq()
  end

  # Linked roots first, then the layer's own directory, so the latter's names win.
  defp layer_skills(layer, paths) do
    linked =
      paths.links
      |> links()
      |> Enum.flat_map(fn root ->
        Enum.map(skills_at(root), &Map.merge(&1, %{source: root, linked?: true}))
      end)

    own =
      Enum.map(
        Bundle.list_skills_in(paths.dir),
        &Map.merge(&1, %{source: paths.dir, linked?: false})
      )

    Enum.map(linked ++ own, &Map.put(&1, :layer, layer))
  end

  # -- .agents/skills ----------------------------------------------------------------

  # Every `.agents/skills` to look in, lowest first, each with its edge and what to say of
  # one outside it: the person's own, held to `~/.agents`, then the repository's from its
  # root down to the workspace, held to the root, so the nearest comes last and wins. The
  # root is the instruction files' (`Troupe.Instructions.repository_root/1`); the person's
  # own directory is not read twice when the repository is their home. Where an edge
  # really is is asked only of a directory that is there, since this runs at every turn.
  defp agents_dirs(workspace, opts) do
    user =
      case agents_home(opts) do
        nil -> []
        home -> [{:user_agents, Path.join(home, "skills"), home, @outside_home}]
      end

    user ++ repository_agents_dirs(workspace, user)
  end

  defp repository_agents_dirs(nil, _user), do: []

  defp repository_agents_dirs(workspace, user) do
    workspace = Path.expand(workspace)
    root = Instructions.repository_root(workspace)
    theirs = for {_layer, dir, _edge, _outside} <- user, do: Workspace.compare_key(dir)

    workspace
    |> up_to(root)
    |> Enum.reverse()
    |> Enum.map(&Path.join(&1, ".agents/skills"))
    |> Enum.reject(&(Workspace.compare_key(&1) in theirs))
    |> Enum.map(&{:agents, &1, root, @outside_repository})
  end

  # `dir` and each directory above it up to `root`, nearest first.
  defp up_to(dir, root) do
    parent = Path.dirname(dir)

    cond do
      Workspace.compare_key(dir) == Workspace.compare_key(root) -> [dir]
      parent == dir -> [dir]
      true -> [dir | up_to(parent, root)]
    end
  end

  # One `.agents/skills`: not there, wholly outside its edge (listed once, not looked
  # into, so not even the names of what is there are said), or each skill in it, in name
  # order. A skill is judged where its `SKILL.md` really is, so a skill directory or a
  # manifest linked out is `outside` and its frontmatter is never read.
  defp agents_skills(layer, dir, edge, outside) do
    if File.dir?(dir), do: agents_skills_in(layer, dir, key(edge), outside), else: []
  end

  defp agents_skills_in(layer, dir, bound, outside) do
    if under?(key(dir), bound) do
      dir
      |> Troupe.Paths.glob_escape()
      |> Path.join("*/SKILL.md")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.flat_map(&agents_skill(&1, layer, dir, bound, outside))
    else
      entry = %{name: nil, layer: layer, dir: dir, source: dir, linked?: false}
      [Map.merge(entry, %{status: :outside, reason: outside})]
    end
  end

  defp agents_skill(manifest, layer, source, bound, outside) do
    dir = Path.dirname(manifest)
    name = Path.basename(dir)
    entry = %{name: name, layer: layer, dir: dir, source: source, linked?: false}

    cond do
      not under?(key(manifest), bound) ->
        [Map.merge(entry, %{status: :outside, reason: outside})]

      not AgentDefinition.valid_name?(name) ->
        [Map.merge(entry, %{status: :skipped, reason: @not_a_name})]

      true ->
        case File.read(manifest) do
          {:ok, text} -> [Map.put(entry, :description, description(text))]
          {:error, _reason} -> []
        end
    end
  end

  # The frontmatter's description, as `Troupe.Protocol.Bundle.list_skills_in/1` reads it.
  defp description(text) do
    {frontmatter, _body} = AgentDefinition.split_frontmatter(text)

    case YamlElixir.read_from_string(frontmatter) do
      {:ok, %{"description" => description}} when is_binary(description) -> description
      _ -> ""
    end
  end

  defp under?(key, bound), do: key == bound or String.starts_with?(key, bound <> "/")

  # Where a path really is, links followed, in the form the platform compares paths in.
  defp key(path) do
    case Workspace.real_path(path) do
      {:ok, real} -> Workspace.compare_key(real)
      {:error, _reason} -> Workspace.compare_key(Path.expand(path))
    end
  end

  # A linked path is a directory of skills, or one skill's own directory.
  defp skills_at(root) do
    if File.regular?(Path.join(root, "SKILL.md")) do
      name = Path.basename(root)
      root |> Path.dirname() |> Bundle.list_skills_in() |> Enum.filter(&(&1.name == name))
    else
      Bundle.list_skills_in(root)
    end
  end

  @doc "The roots a layer's `skills.json` links, expanded relative to the file."
  @spec links(Path.t()) :: [Path.t()]
  def links(links_path) do
    with {:ok, text} <- File.read(links_path),
         {:ok, %{"include" => paths}} when is_list(paths) <- JSONC.decode(text) do
      paths
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.map(&Path.expand(&1, Path.dirname(links_path)))
    else
      _ -> []
    end
  end

  # -- writing -----------------------------------------------------------------------

  @doc """
  Bring skills in: copied into the layer's directory (`link?: false`), or read in
  place by adding their root to the layer's `skills.json` (`link?: true`). `from` is a
  directory of skills, such as `~/.claude/skills`, or one skill's directory. The answer
  names what the layer now has from it.
  """
  @spec add(layer(), Path.t() | nil, Path.t(), boolean(), keyword()) ::
          {:ok,
           %{
             path: Path.t(),
             from: Path.t(),
             added: [String.t()],
             skipped: [map()],
             linked: boolean()
           }}
          | {:error, String.t()}
  def add(scope, workspace, from, link?, opts \\ []) do
    from = Path.expand(from)

    with {:ok, paths} <- layer_paths(scope, workspace, opts),
         :ok <- directory(from),
         {:ok, found, skipped} <- found_at(from) do
      if link?, do: link(paths, from, found, skipped), else: copy(paths, from, found, skipped)
    end
  end

  defp link(paths, from, found, skipped) do
    with :ok <- write_links(paths.links, Enum.uniq(links(paths.links) ++ [from])) do
      {:ok,
       %{
         path: paths.links,
         from: from,
         added: Enum.map(found, & &1.name),
         skipped: skipped,
         linked: true
       }}
    end
  end

  defp copy(paths, from, found, skipped) do
    result = %{path: paths.dir, from: from, added: [], skipped: skipped, linked: false}

    Enum.reduce_while(found, {:ok, result}, fn skill, {:ok, acc} ->
      case copy_one(skill, paths.dir) do
        :ok -> {:cont, {:ok, %{acc | added: acc.added ++ [skill.name]}}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  # A copy replaces what the layer had under that name, so importing again is an update.
  defp copy_one(skill, dir) do
    target = Path.join(dir, skill.name)

    with :ok <- File.mkdir_p(dir),
         {:ok, _} <- File.rm_rf(target),
         {:ok, _} <- File.cp_r(skill.dir, target) do
      :ok
    else
      {:error, reason, file} ->
        {:error, "could not copy #{show(file)}: #{:file.format_error(reason)}"}

      {:error, reason} ->
        {:error, "could not copy #{show(skill.dir)}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Take a skill out of a layer: its copied directory is deleted, or a linked root is
  taken off `skills.json` (`%{include: path}`). A skill that comes only from a linked
  root is not the layer's to delete, and the answer names the root.
  """
  @spec remove(layer(), Path.t() | nil, %{name: String.t()} | %{include: Path.t()}, keyword()) ::
          {:ok, %{path: Path.t(), removed: [String.t()]}} | {:error, String.t()}
  def remove(scope, workspace, what, opts \\ []) do
    with {:ok, paths} <- layer_paths(scope, workspace, opts) do
      case what do
        %{name: name} -> remove_named(paths, name)
        %{include: included} -> unlink(paths, Path.expand(included, Path.dirname(paths.links)))
      end
    end
  end

  defp remove_named(paths, name) do
    target = Path.join(paths.dir, name)

    cond do
      not AgentDefinition.valid_name?(name) ->
        {:error, "#{inspect(name)} is not a skill name: lower-case letters, digits and dashes"}

      File.regular?(Path.join(target, "SKILL.md")) ->
        delete(target, paths.dir, name)

      root =
          Enum.find(links(paths.links), fn root ->
            Enum.any?(skills_at(root), &(&1.name == name))
          end) ->
        {:error,
         "#{name} comes from #{show(root)}, which #{show(paths.links)} links; " <>
           "unlink it with include: #{Jason.encode!(root)}"}

      true ->
        {:error, "#{show(paths.dir)} has no skill named #{name}"}
    end
  end

  defp delete(target, dir, name) do
    case File.rm_rf(target) do
      {:ok, _} ->
        {:ok, %{path: dir, removed: [name]}}

      {:error, reason, file} ->
        {:error, "could not remove #{show(file)}: #{:file.format_error(reason)}"}
    end
  end

  defp unlink(paths, wanted) do
    same? = &(Workspace.compare_key(&1) == Workspace.compare_key(wanted))

    case Enum.split_with(links(paths.links), same?) do
      {[], _kept} ->
        {:error, "#{show(paths.links)} does not include #{show(wanted)}"}

      {[gone | _], kept} ->
        with :ok <- write_links(paths.links, kept),
             do: {:ok, %{path: paths.links, removed: Enum.map(skills_at(gone), & &1.name)}}
    end
  end

  defp write_links(links_path, roots),
    do: Migrate.write_text(links_path, Jason.encode!(%{"include" => roots}, pretty: true) <> "\n")

  defp directory(path) do
    if File.dir?(path), do: :ok, else: {:error, "#{show(path)} is not a directory"}
  end

  # What `from` holds: one skill, or a directory of them. A directory with a name a
  # skill may not have is skipped and said so, as the plane would refuse it.
  defp found_at(from) do
    found = skills_at(from)

    skipped =
      if File.regular?(Path.join(from, "SKILL.md")) do
        []
      else
        from
        |> Troupe.Paths.glob_escape()
        |> Path.join("*/SKILL.md")
        |> Path.wildcard()
        |> Enum.map(&Path.basename(Path.dirname(&1)))
        |> Enum.reject(&AgentDefinition.valid_name?/1)
        |> Enum.map(
          &%{name: &1, reason: "is not a skill name: lower-case letters, digits and dashes"}
        )
      end

    case {found, skipped} do
      {[], []} -> {:error, "#{show(from)} holds no SKILL.md, and no directory with one"}
      _ -> {:ok, found, skipped}
    end
  end

  defp show(path), do: Troupe.Paths.display(path)
end
