defmodule Troupe.Agent.Definition do
  @moduledoc """
  One agent profile: a markdown file whose YAML frontmatter is the configuration and
  whose body is the system prompt. The filename is the name.

  Definitions are loaded once at session start into an immutable snapshot
  (`Troupe.Agent.Definitions`) that is passed down in child specs. There is no
  process holding them: a definition never changes while a session runs, so making it
  data rather than state removes a whole class of races.

  Precedence is project `.troupe/agents/` over the global config dir's `agents/` over
  the built-ins below.
  """

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
    source: :builtin
  ]

  @type mode :: :primary | :subagent
  @type permission :: :auto | :ask | :deny
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
          source: :builtin | :global | :project
        }

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
  default. A tool outside the allowlist is `:deny` regardless of what either says.
  """
  @spec permission(t(), String.t(), permission()) :: permission()
  def permission(%__MODULE__{} = definition, name, tool_default) do
    if allows_tool?(definition, name) do
      Map.get(definition.permissions, name, tool_default)
    else
      :deny
    end
  end

  @doc """
  Parse a definition from markdown with YAML frontmatter.

  A file without frontmatter is still valid — the whole file is then the prompt,
  which makes the simplest possible custom agent a single paragraph in a file.
  """
  @spec parse(String.t(), String.t(), :builtin | :global | :project) ::
          {:ok, t()} | {:error, term()}
  def parse(name, contents, source) do
    {frontmatter, body} = split_frontmatter(contents)

    with {:ok, meta} <- decode_yaml(frontmatter) do
      build(name, meta, String.trim(body), source)
    end
  end

  defp split_frontmatter("---\n" <> rest), do: do_split(rest)
  defp split_frontmatter("---\r\n" <> rest), do: do_split(rest)
  defp split_frontmatter(contents), do: {"", contents}

  defp do_split(rest) do
    case Regex.split(~r/^---\s*$/m, rest, parts: 2) do
      [yaml, body] -> {yaml, body}
      [only] -> {"", only}
    end
  end

  defp decode_yaml(""), do: {:ok, %{}}

  defp decode_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:ok, %{}}
      {:error, reason} -> {:error, {:bad_frontmatter, reason}}
    end
  end

  defp build(name, meta, prompt, source) do
    with {:ok, mode} <- parse_mode(Map.get(meta, "mode", "subagent")),
         {:ok, tools} <- parse_tools(Map.get(meta, "tools", nil)),
         {:ok, permissions} <- parse_permissions(Map.get(meta, "permissions", %{})) do
      {:ok,
       %__MODULE__{
         name: name,
         prompt: prompt,
         description: Map.get(meta, "description", ""),
         mode: mode,
         model: Map.get(meta, "model"),
         tools: tools,
         permissions: permissions,
         max_turns: parse_pos_int(Map.get(meta, "max_turns")),
         budget_share: parse_share(Map.get(meta, "budget_share")),
         source: source
       }}
    end
  end

  defp parse_mode("primary"), do: {:ok, :primary}
  defp parse_mode("subagent"), do: {:ok, :subagent}
  defp parse_mode(other), do: {:error, {:bad_mode, other}}

  defp parse_tools(nil), do: {:ok, :all}
  defp parse_tools("all"), do: {:ok, :all}

  defp parse_tools(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: {:error, {:bad_tools, list}}
  end

  defp parse_tools(other), do: {:error, {:bad_tools, other}}

  defp parse_permissions(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {tool, value}, {:ok, acc} ->
      case value do
        "auto" -> {:cont, {:ok, Map.put(acc, tool, :auto)}}
        "ask" -> {:cont, {:ok, Map.put(acc, tool, :ask)}}
        "deny" -> {:cont, {:ok, Map.put(acc, tool, :deny)}}
        other -> {:halt, {:error, {:bad_permission, tool, other}}}
      end
    end)
  end

  defp parse_permissions(other), do: {:error, {:bad_permissions, other}}

  defp parse_pos_int(n) when is_integer(n) and n > 0, do: n
  defp parse_pos_int(_), do: nil

  defp parse_share(n) when is_float(n) and n > 0, do: min(n, 1.0)
  defp parse_share(n) when is_integer(n) and n > 0, do: min(n / 1, 1.0)
  defp parse_share(_), do: 0.25
end
