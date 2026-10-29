defmodule Troupe.Protocol.AgentDefinition do
  @moduledoc """
  The text of an agent definition, parsed: YAML frontmatter as configuration, the body
  as the system prompt.

  Two places need to read one. `troupe_core` turns it into the `Troupe.Agent.Definition`
  a session runs under; the plane checks one at publish, so an admin hears about a bad
  `mode` when they press the button rather than when the first session on the new
  bundle fails to start. The plane does not depend on core, so the parsing lives here,
  where both can see it, and core builds its struct from what this returns.

  A file without frontmatter is still a definition: the whole file is then the prompt.

  `delegation: ask` says a `delegate` to this agent asks the person first (#554, Decision
  850); `auto`, the default, runs it at once.

  `mode` is one of three: `primary`, an agent a person picks for a session or a branch;
  `subagent`, one an agent delegates to; and `function`, one the harness itself starts
  for one job (an `AI?` comment's question, the project brief's survey) and that never
  carries a session of a person's choosing. Every list of agents a person picks from
  leaves a function agent out, and no agent can delegate to one; the harness fetches it
  by name.
  """

  @type mode :: :primary | :subagent | :function
  @type permission :: :auto | :ask | :deny
  @type delegation :: :auto | :ask

  @type t :: %{
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
          override: boolean(),
          delegation: delegation()
        }

  @name ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/

  # What the harness runs each of Troupe's own function agents for, in the words a refusal
  # uses; any other function agent's job is its description's.
  @jobs %{
    "answer" => "an `AI?` comment's question",
    "quick" => "an `AI!` comment's change and `/quick`",
    "ask" => "`/ask`, a question across a session's branches",
    "librarian" => "the project brief's survey"
  }

  @doc """
  The sentence a request is refused with when it names a function agent as a session's
  agent: what the harness runs it for, and that it carries no session. `description` is
  the agent's own, said where Troupe's own words for its job are not.
  """
  @spec function_refusal(String.t(), String.t() | nil) :: String.t()
  def function_refusal(name, description \\ nil) do
    job =
      Map.get_lazy(@jobs, name, fn ->
        case description && String.trim(description) do
          blank when blank in [nil, ""] -> "a job of its own"
          text -> "its own job (#{text |> String.split("\n", parts: 2) |> hd()})"
        end
      end)

    "#{name} is a function agent the harness runs for #{job}; it does not carry a session"
  end

  @doc "Whether a name is one an agent or a skill may have."
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name), do: Regex.match?(@name, name)
  def valid_name?(_), do: false

  @doc """
  Parse markdown with optional YAML frontmatter into a plain map.

  The name is the caller's — a filename on disk, an entry's name in a bundle — because
  the text does not carry it.
  """
  @spec parse(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def parse(name, contents) when is_binary(name) and is_binary(contents) do
    {frontmatter, body} = split_frontmatter(contents)

    with {:ok, meta} <- decode_yaml(frontmatter) do
      build(name, meta, String.trim(body))
    end
  end

  @doc "Split a definition into its frontmatter text and its body."
  @spec split_frontmatter(String.t()) :: {String.t(), String.t()}
  def split_frontmatter("---\n" <> rest), do: do_split(rest)
  def split_frontmatter("---\r\n" <> rest), do: do_split(rest)
  def split_frontmatter(contents), do: {"", contents}

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

  defp build(name, meta, prompt) do
    with {:ok, mode} <- parse_mode(Map.get(meta, "mode", "subagent")),
         {:ok, tools} <- parse_list(:tools, Map.get(meta, "tools", nil)),
         {:ok, skills} <- parse_list(:skills, Map.get(meta, "skills", [])),
         {:ok, permissions} <- parse_permissions(Map.get(meta, "permissions", %{})),
         {:ok, delegation} <- parse_delegation(Map.get(meta, "delegation")) do
      {:ok,
       %{
         name: name,
         prompt: prompt,
         description: to_string(Map.get(meta, "description", "")),
         mode: mode,
         model: Map.get(meta, "model"),
         tools: tools,
         permissions: permissions,
         max_turns: parse_pos_int(Map.get(meta, "max_turns")),
         budget_share: parse_share(Map.get(meta, "budget_share")),
         skills: skills,
         override: Map.get(meta, "override", false) == true,
         delegation: delegation
       }}
    end
  end

  defp parse_delegation(nil), do: {:ok, :auto}
  defp parse_delegation("auto"), do: {:ok, :auto}
  defp parse_delegation("ask"), do: {:ok, :ask}
  defp parse_delegation(other), do: {:error, {:bad_delegation, other}}

  defp parse_mode("primary"), do: {:ok, :primary}
  defp parse_mode("subagent"), do: {:ok, :subagent}
  defp parse_mode("function"), do: {:ok, :function}
  defp parse_mode(other), do: {:error, {:bad_mode, other}}

  # `tools` absent means every tool; `skills` absent means none. Both accept the word
  # `all` and a list of names, so the two keys read the same way in a file.
  defp parse_list(:tools, nil), do: {:ok, :all}
  defp parse_list(_key, "all"), do: {:ok, :all}

  defp parse_list(key, list) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: {:error, {:"bad_#{key}", list}}
  end

  defp parse_list(key, other), do: {:error, {:"bad_#{key}", other}}

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
