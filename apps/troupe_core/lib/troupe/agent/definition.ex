defmodule Troupe.Agent.Definition do
  @moduledoc """
  One agent profile: a markdown file whose YAML frontmatter is the configuration and
  whose body is the system prompt. The filename is the name.

  Definitions are loaded once at session start into an immutable snapshot
  (`Troupe.Agent.Definitions`) that is passed down in child specs. There is no
  process holding them: a definition never changes while a session runs, so making it
  data rather than state removes a whole class of races.

  Precedence is project `.troupe/agents/` over the global config dir's `agents/` over
  a bundle's `agents/` over the built-ins below.

  The parsing itself lives in `Troupe.Protocol.AgentDefinition`, because the plane
  checks a definition at publish and does not depend on this app. This struct is what
  the harness runs under; the parser's map is what both sides agree a file means.

  A workspace's own definition (`.troupe/agents/`, source `:project`) arrives with a
  clone, so a `permissions:` entry of `auto` in it applies only once the workspace is
  trusted (Decision 825), as a workspace's `config.yaml` sets `auto_approve` only then
  (Decision 686): `trust/3` says whether it is, and `permission/3` holds the `auto` back
  until it does.
  """

  alias Troupe.Config.{Trust, Yaml}
  alias Troupe.Protocol.AgentDefinition

  @enforce_keys [:name, :mode, :prompt]
  defstruct [
    :name,
    :prompt,
    description: "",
    mode: :subagent,
    model: nil,
    tools: :all,
    permissions: %{},
    max_turns: nil,
    budget_share: 0.25,
    skills: [],
    source: :builtin,
    # Whether the workspace a `:project` definition came from is trusted, so its `auto`
    # applies (Decision 825). Set by whoever loads it for a session (`trust/3`); one
    # nobody vouched for asks.
    trusted?: false,
    # What a person should know about how it is read, each `%{key, reason}` with the
    # reason in words: an `auto` held back until the workspace is trusted.
    notes: [],
    # Set only for a bundle's `acp_agents` entry: the command, its arguments and the hash
    # of what it should be. An agent definition carries a prompt for a model to run; this
    # one carries a program to run instead, and is otherwise an ordinary subagent — which
    # is the point. Delegation, depth limits, budget slices and the log do not learn there
    # is a second kind.
    acp: nil
  ]

  @type mode :: :primary | :subagent
  @type permission :: :auto | :ask | :deny
  @type source :: :builtin | :bundle | :global | :project
  @type note :: %{key: String.t(), reason: String.t()}
  @type t :: %__MODULE__{
          name: String.t(),
          prompt: String.t(),
          description: String.t(),
          mode: mode(),
          model: String.t() | nil,
          tools: :all | [String.t()],
          permissions: %{optional(String.t()) => permission()},
          max_turns: pos_integer() | nil,
          budget_share: float(),
          skills: :all | [String.t()],
          source: source(),
          trusted?: boolean(),
          notes: [note()],
          acp: map() | nil
        }

  @doc "Whether this delegate is a subprocess somebody else wrote rather than a prompt."
  @spec acp?(t()) :: boolean()
  def acp?(%__MODULE__{acp: acp}), do: not is_nil(acp)

  @doc """
  Whether this profile may call a tool at all.

  The allowlist is enforced here, in the harness, never by trusting the model to
  respect the tool list it was given.
  """
  @spec allows_tool?(t(), String.t()) :: boolean()
  def allows_tool?(%__MODULE__{tools: :all}, _name), do: true
  def allows_tool?(%__MODULE__{tools: list}, name), do: name in list

  @doc """
  The effective permission for a tool: the profile's override, else the tool's own
  default. A tool outside the allowlist is `:deny` regardless of what either says, and
  a workspace's `auto` not yet trusted is the tool's own default (Decision 825).
  """
  @spec permission(t(), String.t(), permission()) :: permission()
  def permission(%__MODULE__{} = definition, name, tool_default) do
    cond do
      not allows_tool?(definition, name) -> :deny
      held?(definition, name) -> tool_default
      true -> Map.get(definition.permissions, name, tool_default)
    end
  end

  # A workspace's `auto` nobody has vouched for. Its `ask` and `deny` narrow what runs,
  # which a file may do whoever wrote it.
  defp held?(%__MODULE__{source: :project, trusted?: false, permissions: permissions}, name),
    do: Map.get(permissions, name) == :auto

  defp held?(_definition, _name), do: false

  @doc """
  Say whether the workspace a definition was read from is trusted (Decision 825).

  A workspace's own definition in one that is not keeps its `auto` entries out of
  `permission/3` and carries a note naming what is held back and the command that trusts
  the workspace; one in a trusted workspace runs as it says. Anything else is the
  person's own, a bundle's or a built-in, and is returned as it is.
  """
  @spec trust(t(), boolean(), Path.t()) :: t()
  def trust(%__MODULE__{source: :project} = definition, trusted?, workspace) do
    notes = Enum.reject(definition.notes, &(&1.key == "permissions"))

    held =
      if trusted?,
        do: [],
        else: for({name, :auto} <- Enum.sort(definition.permissions), asks?(name), do: name)

    held_note =
      if held == [],
        do: [],
        else: [%{key: "permissions", reason: held_reason(held, workspace)}]

    %{definition | trusted?: trusted?, notes: notes ++ held_note}
  end

  def trust(%__MODULE__{} = definition, _trusted?, _workspace), do: definition

  # Whether the tool asks when nothing says otherwise, so holding an `auto` back changes
  # something. One the harness does not know of here, a server's or a client's, asks
  # unless its server says otherwise.
  defp asks?(name) do
    case Troupe.Tools.fetch(name) do
      {:ok, tool} -> Troupe.Tool.default_permission(tool) != :auto
      {:error, _unknown} -> true
    end
  end

  defp held_reason(held, workspace) do
    {apply, ask} = if match?([_], held), do: {"applies", "asks"}, else: {"apply", "ask"}

    "#{Enum.map_join(held, ", ", &"#{&1}: auto")} #{apply} once this workspace is trusted " <>
      "(#{Trust.command(workspace)}); until then #{Enum.join(held, ", ")} #{ask}"
  end

  @doc """
  Whether this profile may consult a skill.

  `skills: all` opens every skill the bundle carries; a list names the ones it may
  read; the default, an empty list, is no skills at all — a profile that did not ask
  for any should not have its prompt grow because an admin published one.
  """
  @spec allows_skill?(t(), String.t()) :: boolean()
  def allows_skill?(%__MODULE__{skills: :all}, _name), do: true
  def allows_skill?(%__MODULE__{skills: list}, name), do: name in list

  @doc """
  Parse a definition from markdown with YAML frontmatter.

  A file without frontmatter is still valid — the whole file is then the prompt,
  which makes the simplest possible custom agent a single paragraph in a file.
  """
  @spec parse(String.t(), String.t(), source()) :: {:ok, t()} | {:error, term()}
  def parse(name, contents, source) do
    with {:ok, parsed} <- AgentDefinition.parse(name, contents) do
      {:ok, from_parsed(parsed, source)}
    end
  end

  @doc """
  The file `parse/3` reads back to this definition, the name aside, which is the file's:
  the frontmatter keys whose values differ from a file without them, in the order the
  built-ins write them, then the prompt. What onboarding proposes for `.troupe/agents/`
  (Decision 824). An ACP entry is a bundle's, with no file of its own, and has none.
  """
  @spec render(t()) :: String.t()
  def render(%__MODULE__{acp: nil} = definition) do
    frontmatter =
      [
        {"description", definition.description, ""},
        {"mode", Atom.to_string(definition.mode), nil},
        {"model", definition.model, nil},
        {"tools", definition.tools, :all},
        {"skills", if(definition.skills == :all, do: "all", else: definition.skills), []},
        {"permissions",
         Map.new(definition.permissions, fn {tool, permission} ->
           {tool, Atom.to_string(permission)}
         end), %{}},
        {"max_turns", definition.max_turns, nil},
        {"budget_share", definition.budget_share, 0.25}
      ]
      |> Enum.reject(fn {_key, value, absent} -> value == absent end)
      |> Enum.reduce("", fn {key, value, _absent}, text -> put(text, key, value) end)

    prompt = if definition.prompt == "", do: "", else: "\n" <> definition.prompt <> "\n"
    "---\n" <> frontmatter <> "---\n" <> prompt
  end

  # One key after the others, bare where YAML reads it back as itself, which
  # `Troupe.Config.Yaml.put/3` checks.
  defp put(text, key, value) do
    case Yaml.put(text, [key], value) do
      {:ok, text} -> if String.ends_with?(text, "\n"), do: text, else: text <> "\n"
      :error -> text <> Yaml.encode(%{key => value})
    end
  end

  @doc "Build the struct from what the shared parser returned."
  @spec from_parsed(AgentDefinition.t(), source()) :: t()
  def from_parsed(parsed, source) do
    %__MODULE__{
      name: parsed.name,
      prompt: parsed.prompt,
      description: parsed.description,
      mode: parsed.mode,
      model: parsed.model,
      tools: parsed.tools,
      permissions: parsed.permissions,
      max_turns: parsed.max_turns,
      budget_share: parsed.budget_share,
      skills: parsed.skills,
      source: source
    }
  end
end
