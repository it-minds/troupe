defmodule Troupe.Skills do
  @moduledoc """
  Skills: instructions an admin published in a config bundle, read on demand.

  A skill is a directory in the Agent Skills convention — `SKILL.md` with a name and a
  description in its frontmatter and the instructions in its body, beside whatever
  files the instructions refer to. They are used progressively. The system prompt of
  an agent whose definition lists them carries one line per skill, a name and a
  description, and nothing else; the body is loaded only when the model asks for it
  through the `skill` tool; and the files beside it are readable through `read_file`
  under the read-only `skills:/<name>/` mount.

  The tool is a `Troupe.Tool` value rather than a module, like an MCP tool, because
  whether it exists at all is a property of the session — which bundle it is pinned
  to, and whether its profile asked for any skills — rather than of the code. It reads
  from the pinned bundle's directory and from the person's own layers
  (`Troupe.Skills.Local`, Decision 700), and its call and result land in the log as
  any tool's do, so a transcript shows which skill was consulted and when. Nothing
  else is logged: the tool call *is* the record.

  A bundle's skills are gated by the profile's `skills:` list and the team's
  entitlements, since an admin published them for particular agents. A person's own
  skills are offered to every agent of the session, because the person put them there
  for their own work. A skill on the disk of the same name as one of the bundle's is not
  read, whether or not this agent may consult the bundle's: a bundle is the plane's word,
  only a pod has one, and a file that arrived with a clone does not stand in for a skill
  an admin published, as an agent's does not (Decision 826). `skipped/2` lists such a
  file with the reason. A profile that lets a repository's skills replace the bundle's
  puts the nearer layer back on top, as it was before.

  In a git worktree the workspace's layer is the worktree's own `.troupe/skills/` over
  the main checkout's committed ones (`Troupe.Worktree`), held to the checkout.

  `trusted: true` in the options says the session's workspace is trusted, as the session
  stamps it when it starts (`Troupe.Workspace`'s `trusted?`): only then is what the
  workspace's `skills.json` links from outside the repository read (Decision 829).
  """

  alias Troupe.Agent.{Definition, Definitions}
  alias Troupe.{Paths, Workspace, Worktree}
  alias Troupe.Protocol.Bundle
  alias Troupe.Skills.Local

  defmodule Tool do
    @moduledoc "The `skill` tool, as a value."

    @enforce_keys [:name, :description, :schema, :run]
    defstruct [:name, :description, :schema, :run, default_permission: :auto]

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t(),
            schema: map(),
            run: (map(), Troupe.Tool.Ctx.t() -> Troupe.Tool.result()),
            default_permission: :auto | :ask | :deny
          }
  end

  @typedoc """
  What a session knows about its bundle: `%{version, hash, channel, dir, entitlements,
  repository_overrides}`.

  `entitlements` is the set the plane resolved for this session's team, by name, or
  `nil` for no restriction — which is what a local session, a laptop and every grant
  nobody has narrowed all send. `repository_overrides` is `true` where the profile lets
  a repository's agents and skills replace the bundle's and the built-ins (Decision 826);
  anything else is those winning. A pod whose channel has nothing published is pinned to
  nothing: `version` and `dir` nil.
  """
  @type bundle :: %{
          optional(:version) => term(),
          optional(:hash) => String.t() | nil,
          optional(:channel) => String.t() | nil,
          optional(:entitlements) => map() | nil,
          optional(:repository_overrides) => boolean(),
          required(:dir) => Path.t() | nil
        }

  @doc "Where a materialised bundle keeps its skills."
  @spec dir(bundle() | nil) :: Path.t() | nil
  def dir(%{dir: dir}) when is_binary(dir), do: Path.join(dir, "skills")
  def dir(_bundle), do: nil

  @doc """
  The mount entry for a bundle's skills, or `nil` when the bundle has none.

  A bundle with no skills adds no mount, so a session on a profile that only carries
  MCP servers records the same `mounts_resolved` it did before skills existed.
  """
  @spec mount(bundle() | nil) :: map() | nil
  def mount(bundle) do
    case dir(bundle) do
      nil -> nil
      path -> if File.dir?(path), do: %{name: "skills", kind: :bundle, root: path, mode: :ro}
    end
  end

  @doc """
  The skills a profile may consult: the bundle's it is allowed, then the person's own.

  For the bundle the definition's `skills` decides: `all` is every skill in the bundle,
  a list is those names, and the default — no skills — is an empty list however many
  the bundle carries. A name the definition lists and the bundle lacks is simply
  absent; the plane refused such a definition at publish, so here it can only mean a
  bundle that was materialised by hand. The person's own skills (`Troupe.Skills.Local`)
  come from the config directory and the workspace given, every one of them, whatever
  the definition lists, but for those of a name the bundle has where the bundle wins
  (`Troupe.Agent.Definitions.bundle_wins?/1`); `nil` reads no local layer.
  """
  @type listed :: %{
          name: String.t(),
          description: String.t(),
          layer: :bundle | Local.layer(),
          dir: Path.t()
        }

  @spec available(bundle() | nil, Definition.t(), Path.t() | nil, keyword()) :: [listed()]
  def available(bundle, %Definition{} = definition, workspace \\ nil, opts \\ []) do
    from_bundle =
      case {definition.skills, bundle} do
        {[], _} ->
          []

        {_, %{dir: dir}} when is_binary(dir) ->
          dir
          |> Bundle.list_skills()
          |> allowed(definition)
          |> entitled(bundle)
          |> Enum.map(&Map.put(&1, :layer, :bundle))

        _ ->
          []
      end

    {local, _skipped} = local(bundle, workspace, opts)

    (from_bundle ++ local)
    |> by_name()
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  The skills found on disk that a session does not offer, each with why: on a pod, one
  of a name the bundle has (Decision 826); in a worktree, one the main checkout has not
  committed; anywhere, one not read because it is outside its edge or waits for the
  workspace to be trusted, or whose `SKILL.md` can't be read (Decision 829). Shaped as
  `Troupe.Agent.Definitions.skipped/1` gives an agent.
  """
  @spec skipped(bundle() | nil, Path.t() | nil, keyword()) :: [Definitions.skipped()]
  def skipped(bundle, workspace, opts \\ []) do
    {_local, skipped} = local(bundle, workspace, opts)
    Enum.sort_by(skipped, & &1.name)
  end

  @doc """
  The directories a session reads its own skills' files from: the person's layers and
  the roots they link (`Troupe.Skills.Local.roots/2`, the workspace's from outside the
  repository only with `trusted: true`), and in a worktree the main checkout's
  `.troupe/skills`, whose committed skills it offers, when it really is in the checkout.
  """
  @spec roots(Path.t(), keyword()) :: [Path.t()]
  def roots(workspace, opts \\ []) do
    checkout =
      with main when is_binary(main) <- Worktree.main(workspace),
           dir = Path.join(Paths.project_dir(main), "skills"),
           true <- Workspace.within?(dir, main) do
        [dir]
      else
        _ -> []
      end

    (Local.roots(workspace, opts) ++ checkout) |> Enum.filter(&File.dir?/1) |> Enum.uniq()
  end

  # The person's own skills and the repository's, with the main checkout's committed ones
  # below the worktree's own; then, where the bundle wins, every one of a name the bundle
  # has taken out, whichever layer it came from. What was not read at all is listed too.
  defp local(_bundle, nil, _opts), do: {[], []}

  defp local(bundle, root, opts) do
    %{skills: skills, skipped: left_out} = Local.resolve(root, opts)
    # Not what a name higher up hid, nor a folder no skill may be called: what was not read.
    unread = for %{status: status} = entry <- left_out, status != :skipped, do: unread(entry)

    {listed, uncommitted} =
      skills
      |> Enum.map(&Map.take(&1, [:name, :description, :layer, :dir]))
      |> with_checkout(root)

    # Troupe ships no skills of its own, so the bundle's are the only names that win here;
    # one it shipped would win as a built-in agent does.
    if Definitions.bundle_wins?(bundle) do
      taken = MapSet.new(bundle_skills(bundle), & &1.name)
      {lost, kept} = Enum.split_with(listed, &MapSet.member?(taken, &1.name))

      {kept,
       unread ++
         uncommitted ++ Enum.map(lost, &skip(&1, Definitions.lost_to_bundle(:skill, &1.name)))}
    else
      {listed, unread ++ uncommitted}
    end
  end

  # Above every lower layer and below the worktree's own `.troupe/skills`, as the
  # checkout's `.troupe/skills` is above them there, and held to the checkout.
  defp with_checkout(listed, root) do
    own = for %{layer: :workspace, name: name} <- listed, into: MapSet.new(), do: name

    case Worktree.main(root) do
      nil ->
        {listed, []}

      main ->
        {found, left_out} =
          main
          |> Paths.project_dir()
          |> Path.join("skills")
          |> Local.held(main, Definitions.outside_checkout())

        found = Enum.reject(found, &MapSet.member?(own, &1.name))

        unread =
          for %{status: status} = entry <- left_out,
              status != :skipped and not MapSet.member?(own, entry.name),
              do: unread(entry)

        {checkout, drafts} = committed(found, main)
        {lower, nearest} = Enum.split_with(listed, &(&1.layer != :workspace))

        {by_name(lower ++ checkout ++ nearest),
         unread ++ Enum.map(drafts, &skip(&1, Worktree.uncommitted(main)))}
    end
  end

  # What the checkout has committed, as the workspace's layer, and what it has not.
  defp committed([], _main), do: {[], []}

  defp committed(found, main) do
    committed = Worktree.committed(main, ".troupe/skills")

    {kept, drafts} =
      Enum.split_with(found, &MapSet.member?(committed, ".troupe/skills/#{&1.name}/SKILL.md"))

    checkout = for skill <- kept, do: Map.take(skill, [:name, :description, :dir])
    {Enum.map(checkout, &Map.put(&1, :layer, :workspace)), drafts}
  end

  # A skill not read at all, as the log lists it: a directory not looked into by itself.
  defp unread(%{name: nil, dir: dir, reason: reason}),
    do: %{kind: :skill, name: nil, path: dir, reason: reason}

  defp unread(entry), do: skip(entry, entry.reason)

  # A pin with nothing pinned, or no directory on this pod, has no skills.
  defp bundle_skills(bundle) do
    case dir(bundle) do
      nil -> []
      path -> Bundle.list_skills_in(path)
    end
  end

  defp skip(skill, reason),
    do: %{kind: :skill, name: skill.name, path: Path.join(skill.dir, "SKILL.md"), reason: reason}

  defp by_name(skills) do
    skills
    |> Enum.reduce(%{}, fn skill, acc -> Map.put(acc, skill.name, skill) end)
    |> Map.values()
  end

  defp allowed(skills, definition) do
    Enum.filter(skills, &Definition.allows_skill?(definition, &1.name))
  end

  # The team's set, applied after the definition's own list. Two narrowings that compose
  # in the only order that is safe: a skill has to be both something this agent consults
  # and something this team was granted. A session with no set is unrestricted, which is
  # a laptop, a local session, and every team nobody has narrowed.
  defp entitled(skills, %{entitlements: %{"skills" => names}}) when is_list(names) do
    entitled = MapSet.new(names)
    Enum.filter(skills, &MapSet.member?(entitled, &1.name))
  end

  defp entitled(skills, _bundle), do: skills

  @doc """
  The `skill` tool for a session, or none.

  Offered only when there is something to read: a bundle directory with skills in it
  and a profile that lists at least one of them, or a skill of the person's own. A model
  that sees the tool can call it; one that does not has nothing it could ask for.
  """
  @spec tools(bundle() | nil, Definition.t(), Path.t() | nil, keyword()) :: [Tool.t()]
  def tools(bundle, %Definition{} = definition, workspace \\ nil, opts \\ []) do
    case available(bundle, definition, workspace, opts) do
      [] -> []
      skills -> [tool(skills)]
    end
  end

  @doc """
  The lines a system prompt carries: one per skill the profile lists, or nothing.

  Names and descriptions only. The instructions themselves are behind the tool, so a
  profile with thirty skills costs thirty lines of prompt rather than thirty
  documents, and the log says which of them the model actually read.
  """
  @spec prompt_section(bundle() | nil, Definition.t(), Path.t() | nil, keyword()) :: String.t()
  def prompt_section(bundle, %Definition{} = definition, workspace \\ nil, opts \\ []) do
    case available(bundle, definition, workspace, opts) do
      [] ->
        ""

      skills ->
        lines = Enum.map_join(skills, "\n", &("- " <> &1.name <> ": " <> &1.description))
        "Skills available — call the skill tool with a name to read one:\n" <> lines
    end
  end

  defp tool(skills) do
    names = Enum.map(skills, & &1.name)
    by_name = Map.new(skills, &{&1.name, &1})

    %Tool{
      name: "skill",
      description: description(skills),
      schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "The skill to read. One of: " <> Enum.join(names, ", ") <> "."
          }
        },
        "required" => ["name"]
      },
      default_permission: :auto,
      run: fn args, _ctx -> read(by_name, args) end
    }
  end

  defp description(skills) do
    """
    Read a skill: instructions published for a kind of work, with the files they refer
    to. Call it when a task matches a skill's description, before starting the work.
    The files a skill mentions are listed with the path to read them at, which
    `read_file` can.

    Skills:
    #{Enum.map_join(skills, "\n", &("- " <> &1.name <> ": " <> &1.description))}
    """
    |> String.trim()
  end

  # A skill the profile does not list is `not_found`, not `denied`: from inside this
  # session it does not exist, the same way another team's volume does not.
  defp read(by_name, args) do
    with {:ok, name} <- Troupe.Tool.fetch_string(args, "name"),
         {:ok, listed} <- Map.fetch(by_name, name) |> or_unknown(name),
         {:ok, skill} <- read_skill(listed) do
      {:ok, render(listed, skill)}
    end
  end

  defp or_unknown({:ok, listed}, _name), do: {:ok, listed}
  defp or_unknown(:error, name), do: {:error, {:unknown_skill, name}}

  defp read_skill(%{name: name, dir: dir}) do
    case Bundle.read_skill_dir(dir, name) do
      {:ok, skill} -> {:ok, skill}
      {:error, :not_found} -> {:error, {:unknown_skill, name}}
    end
  end

  # A bundle's files are under the read-only `skills:/` mount; a person's own are read
  # where they are, which the session's read roots allow.
  defp render(listed, %{name: name, body: body, files: files}) do
    listed_files =
      files
      |> Enum.reject(&(&1 == "SKILL.md"))
      |> Enum.map_join("\n", &("- " <> file_path(listed, name, &1)))

    case listed_files do
      "" -> body
      _ -> body <> "\n\nFiles:\n" <> listed_files
    end
  end

  defp file_path(%{layer: :bundle}, name, file), do: "skills:/" <> name <> "/" <> file
  defp file_path(%{dir: dir}, _name, file), do: Path.join(dir, file)
end
