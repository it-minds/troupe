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
  only from the pinned bundle's directory, and its call and result land in the log as
  any tool's do, so a transcript shows which skill was consulted and when. Nothing
  else is logged: the tool call *is* the record.
  """

  alias Troupe.Agent.Definition
  alias Troupe.Protocol.Bundle

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
  What a session knows about its bundle: `%{version, hash, channel, dir, entitlements}`.

  `entitlements` is the set the plane resolved for this session's team, by name, or
  `nil` for no restriction — which is what a local session, a laptop and every grant
  nobody has narrowed all send.
  """
  @type bundle :: %{
          optional(:version) => term(),
          optional(:hash) => String.t() | nil,
          optional(:channel) => String.t() | nil,
          optional(:entitlements) => map() | nil,
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
  The skills a profile may consult, from the bundle it is pinned to.

  The definition's `skills` decides: `all` is every skill in the bundle, a list is
  those names, and the default — no skills — is an empty list however many the bundle
  carries. A name the definition lists and the bundle lacks is simply absent; the
  plane refused such a definition at publish, so here it can only mean a bundle that
  was materialised by hand.
  """
  @type listed :: %{name: String.t(), description: String.t()}

  @spec available(bundle() | nil, Definition.t()) :: [listed()]
  def available(bundle, %Definition{} = definition) do
    case {definition.skills, bundle} do
      {[], _} ->
        []

      {_, %{dir: dir}} when is_binary(dir) ->
        dir
        |> Bundle.list_skills()
        |> allowed(definition)
        |> entitled(bundle)

      _ ->
        []
    end
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
  and a profile that lists at least one of them. A model that sees the tool can call
  it; one that does not has nothing it could ask for.
  """
  @spec tools(bundle() | nil, Definition.t()) :: [Tool.t()]
  def tools(bundle, %Definition{} = definition) do
    case available(bundle, definition) do
      [] -> []
      skills -> [tool(bundle.dir, skills)]
    end
  end

  @doc """
  The lines a system prompt carries: one per skill the profile lists, or nothing.

  Names and descriptions only. The instructions themselves are behind the tool, so a
  profile with thirty skills costs thirty lines of prompt rather than thirty
  documents, and the log says which of them the model actually read.
  """
  @spec prompt_section(bundle() | nil, Definition.t()) :: String.t()
  def prompt_section(bundle, %Definition{} = definition) do
    case available(bundle, definition) do
      [] ->
        ""

      skills ->
        lines = Enum.map_join(skills, "\n", &("- " <> &1.name <> ": " <> &1.description))
        "Skills available — call the skill tool with a name to read one:\n" <> lines
    end
  end

  defp tool(dir, skills) do
    names = Enum.map(skills, & &1.name)

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
      run: fn args, _ctx -> read(dir, names, args) end
    }
  end

  defp description(skills) do
    """
    Read a skill: instructions your team published for a kind of work, with the files
    they refer to. Call it when a task matches a skill's description, before starting
    the work. The files a skill mentions are under `skills:/<name>/` and can be read
    with `read_file`.

    Skills:
    #{Enum.map_join(skills, "\n", &("- " <> &1.name <> ": " <> &1.description))}
    """
    |> String.trim()
  end

  # A skill the profile does not list is `not_found`, not `denied`: from inside this
  # session it does not exist, the same way another team's volume does not.
  defp read(dir, names, args) do
    with {:ok, name} <- Troupe.Tool.fetch_string(args, "name"),
         true <- name in names || {:error, {:unknown_skill, name}},
         {:ok, skill} <- read_skill(dir, name) do
      {:ok, render(skill)}
    end
  end

  defp read_skill(dir, name) do
    case Bundle.read_skill(dir, name) do
      {:ok, skill} -> {:ok, skill}
      {:error, :not_found} -> {:error, {:unknown_skill, name}}
    end
  end

  defp render(%{name: name, body: body, files: files}) do
    listed =
      files
      |> Enum.reject(&(&1 == "SKILL.md"))
      |> Enum.map_join("\n", &("- skills:/" <> name <> "/" <> &1))

    case listed do
      "" -> body
      _ -> body <> "\n\nFiles:\n" <> listed
    end
  end
end
