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

  Names are resolved the way the MCP layers are: the workspace's skill wins over the
  user's of the same name, and a layer's own directory wins over what it links. Unlike
  a bundle's skills, which a profile lists by name because an admin published them for
  particular agents, a person's own skills are offered to every agent of the session:
  the person put them there, for their own work, and a skill nobody can call is not one.
  The files beside a skill are read with `read_file`, so the layers' directories and
  linked roots are read roots of the session (`Troupe.Session.build_opts/1`).
  """

  alias Troupe.Config.{JSONC, Migrate}
  alias Troupe.Protocol.{AgentDefinition, Bundle}
  alias Troupe.Workspace

  @type layer :: :user | :workspace

  @typedoc "One skill as the layers give it: what a prompt lists, and where it is."
  @type skill :: %{
          name: String.t(),
          description: String.t(),
          layer: layer(),
          dir: Path.t(),
          source: Path.t(),
          linked?: boolean()
        }

  # -- where -------------------------------------------------------------------------

  @doc "The user's skills directory, beside `config.yaml`."
  @spec user_dir(keyword()) :: Path.t()
  def user_dir(opts \\ []),
    do: Keyword.get(opts, :user_dir) || Path.join(Troupe.Paths.config_dir(), "skills")

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
  Every skill the layers give a workspace, by name, the workspace's over the user's.
  `nil` for the workspace reads the user's layer alone.
  """
  @spec list(Path.t() | nil, keyword()) :: [skill()]
  def list(workspace, opts \\ []) do
    layers = [:user] ++ if(workspace, do: [:workspace], else: [])

    layers
    |> Enum.flat_map(fn layer ->
      {:ok, paths} = layer_paths(layer, workspace, opts)
      layer_skills(layer, paths)
    end)
    |> Enum.reduce(%{}, fn skill, acc -> Map.put(acc, skill.name, skill) end)
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  The directories a session must be able to read for its local skills' files: the
  user's layer and every linked root. The workspace's own layer is inside the workspace
  already. Only what exists, since a read root that is not there resolves nothing.
  """
  @spec roots(Path.t() | nil, keyword()) :: [Path.t()]
  def roots(workspace, opts \\ []) do
    {:ok, user} = layer_paths(:user, nil, opts)

    workspace_links =
      case workspace && layer_paths(:workspace, workspace, opts) do
        {:ok, paths} -> links(paths.links)
        _ -> []
      end

    ([user.dir] ++ links(user.links) ++ workspace_links)
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

    (linked ++ own)
    |> Enum.map(&Map.put(&1, :layer, layer))
    |> Enum.reduce(%{}, fn skill, acc -> Map.put(acc, skill.name, skill) end)
    |> Map.values()
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
