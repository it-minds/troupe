defmodule Troupe.Agents.Definition do
  @moduledoc """
  An agent definition: YAML frontmatter plus a markdown body (the system prompt).

  `reasoning_effort` is the most specific of the three places an effort can come
  from — a definition beats the provider's `models:` declaration, which beats the
  global `reasoning_effort` config key. Cheap, short-lived profiles set it low so
  a one-line question does not buy a full thinking budget on every turn.
  """

  alias Troupe.Frontmatter

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          mode: :primary | :subagent,
          model: String.t(),
          reasoning_effort: String.t() | nil,
          isolation: :shared | :worktree,
          tools: :all | [String.t()],
          permissions: %{optional(String.t()) => :auto | :ask | :deny},
          max_turns: pos_integer(),
          max_input_tokens: pos_integer(),
          max_output_tokens: pos_integer(),
          max_wall_clock_ms: pos_integer(),
          budget_share: float(),
          prompt: String.t(),
          source: :builtin | :global | :project
        }

  defstruct name: "",
            description: "",
            mode: :primary,
            model: "default",
            reasoning_effort: nil,
            isolation: :shared,
            tools: :all,
            permissions: %{},
            max_turns: 150,
            max_input_tokens: 6_000_000,
            max_output_tokens: 600_000,
            max_wall_clock_ms: 10_800_000,
            budget_share: 0.5,
            prompt: "",
            source: :builtin

  @doc "Parses a definition file's content. The name comes from the filename."
  @spec parse(String.t(), String.t(), :builtin | :global | :project) ::
          {:ok, t()} | {:error, term()}
  def parse(name, content, source) do
    with {:ok, meta, body} <- Frontmatter.split(content) do
      {:ok,
       %__MODULE__{
         name: name,
         description: Map.get(meta, "description", ""),
         mode: parse_mode(Map.get(meta, "mode", "primary")),
         model: Map.get(meta, "model", "default"),
         reasoning_effort: Troupe.Config.effort(Map.get(meta, "reasoning_effort")),
         isolation: parse_isolation(Map.get(meta, "isolation", "shared")),
         tools: parse_tools(Map.get(meta, "tools", "all")),
         permissions: parse_permissions(Map.get(meta, "permissions", %{})),
         max_turns: Map.get(meta, "max_turns", 150),
         max_input_tokens: Map.get(meta, "max_input_tokens", 6_000_000),
         max_output_tokens: Map.get(meta, "max_output_tokens", 600_000),
         max_wall_clock_ms: Map.get(meta, "max_wall_clock_ms", 10_800_000),
         budget_share: Map.get(meta, "budget_share", 0.5) / 1,
         prompt: String.trim(body),
         source: source
       }}
    end
  end

  defp parse_mode("subagent"), do: :subagent
  defp parse_mode(_), do: :primary

  defp parse_isolation("worktree"), do: :worktree
  defp parse_isolation(_), do: :shared

  defp parse_tools("all"), do: :all
  defp parse_tools(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp parse_tools(_), do: :all

  defp parse_permissions(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), parse_permission(v)} end)
  end

  defp parse_permissions(_), do: %{}

  defp parse_permission("auto"), do: :auto
  defp parse_permission("ask"), do: :ask
  defp parse_permission("deny"), do: :deny
  defp parse_permission(_), do: :ask
end
