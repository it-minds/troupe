defmodule Troupe.Agent.Validate do
  @moduledoc """
  An agent definition checked as it is saved (#503, Decision 841): everything a file can
  get wrong that the loader forgives or drops, as errors and warnings, each naming the
  field it is about with a sentence. `agents.put` writes nothing while there is an error;
  `agents.validate` answers the same list and writes nothing either way.

  The loader is lenient on purpose, since one broken agent should not stop a person
  working: a misspelt key is ignored, a `max_turns` of `"ten"` is no cap, a missing `mode`
  is `subagent`, and a file whose `mode` it does not know is left out with a line in a log.
  The moment somebody writes the file is the one to be loud.

  - **Errors:** the frontmatter is not YAML; a key no agent has; `mode` missing or not
    `primary` or `subagent`; `tools` or `skills` not `all` or a list of names; a tool that
    does not exist; a permission that is not `auto`, `ask` or `deny`; a permission that
    grants (`auto` or `ask`) a tool `tools` does not list, which could never apply (a
    `deny` of one says what leaving it out says, and the built-ins do it to make the denial
    plain); a model the provider does not serve, by the list the daemon already has
    (Decision 778); a `max_turns` that is not a positive whole number; a `budget_share`
    that is not a number above 0; an `override` that is not true or false; a name an agent
    may not have.
  - **Warnings:** what cannot be checked here (an MCP server's tool or a client's, which
    exist only once they run; a model when the provider has never listed its models on
    this machine), a `budget_share` above 1 (read as 1), an empty description, and an empty
    instruction.

  Onboarding's provenance keys (`imported_from` and the rest, Decision 823) are keys an
  agent's file may have.
  """

  alias Troupe.Config
  alias Troupe.LLM.Catalog.Store
  alias Troupe.Protocol.AgentDefinition

  @keys ~w(description mode model tools permissions max_turns budget_share skills override)
  @provenance ~w(imported_from imported_hash imported_at imported_also imported_version)

  # Tools the harness offers outside the pod-wide list: the skill tool, when the session's
  # bundle or files have skills the profile names, and a loop's verdict.
  @scoped_tools ~w(skill goal_complete)

  @type finding :: %{field: String.t(), message: String.t()}
  @type result :: %{ok: boolean(), errors: [finding()], warnings: [finding()]}

  @doc """
  Check a definition's text. `name:` is the name it would be saved under (checked when
  given); `config:` the `Troupe.Config` its model is checked against (unchecked, with a
  warning, without one).
  """
  @spec check(String.t(), keyword()) :: result()
  def check(source, opts \\ []) when is_binary(source) do
    {frontmatter, body} = AgentDefinition.split_frontmatter(source)

    findings =
      case decode(frontmatter) do
        {:ok, meta} ->
          name(opts[:name]) ++ fields(meta, body, opts[:config])

        {:error, message} ->
          name(opts[:name]) ++ [error("frontmatter", message)]
      end

    errors = for {:error, finding} <- findings, do: finding
    warnings = for {:warning, finding} <- findings, do: finding
    %{ok: errors == [], errors: errors, warnings: warnings}
  end

  @doc """
  What the shared parser's error says, in words: the reason a file that does not load is
  listed with (`Troupe.Agent.Definitions`), and a file that cannot be read.
  """
  @spec describe(term()) :: String.t()
  def describe({:bad_frontmatter, reason}),
    do: "its frontmatter is not YAML (#{yaml_error(reason)})"

  def describe({:bad_mode, mode}), do: "mode must be primary or subagent, not #{inspect(mode)}"

  def describe({:bad_tools, tools}),
    do: "tools must be all or a list of names, not #{inspect(tools)}"

  def describe({:bad_skills, skills}),
    do: "skills must be all or a list of names, not #{inspect(skills)}"

  def describe({:bad_permission, tool, value}),
    do: "the permission for #{tool} must be auto, ask or deny, not #{inspect(value)}"

  def describe({:bad_permissions, value}),
    do: "permissions must be a map of tool names to auto, ask or deny, not #{inspect(value)}"

  def describe(reason) when is_atom(reason),
    do: "it cannot be read (#{:file.format_error(reason)})"

  def describe(reason), do: inspect(reason)

  ## Checks

  defp decode(""), do: {:ok, %{}}

  defp decode(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, nil} -> {:ok, %{}}
      {:ok, _other} -> {:error, "the frontmatter must be keys and values"}
      {:error, reason} -> {:error, "the frontmatter is not YAML (#{yaml_error(reason)})"}
    end
  end

  defp yaml_error(%{message: message}) when is_binary(message), do: message
  defp yaml_error(reason), do: inspect(reason)

  defp name(nil), do: []

  defp name(name) do
    if AgentDefinition.valid_name?(name),
      do: [],
      else: [
        error(
          "name",
          "#{inspect(name)} is not a name an agent may have: lowercase letters, digits and " <>
            "dashes, starting with a letter or digit, at most 64"
        )
      ]
  end

  defp fields(meta, body, config) do
    tools = Map.get(meta, "tools")

    unknown_keys(meta) ++
      mode(Map.fetch(meta, "mode")) ++
      tools(tools) ++
      permissions(Map.get(meta, "permissions", %{}), tools) ++
      skills(Map.get(meta, "skills")) ++
      model(Map.get(meta, "model"), config) ++
      max_turns(Map.fetch(meta, "max_turns")) ++
      budget_share(Map.fetch(meta, "budget_share")) ++
      override(Map.fetch(meta, "override")) ++
      description(Map.get(meta, "description")) ++
      instruction(String.trim(body))
  end

  defp unknown_keys(meta) do
    for key <- meta |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
        key not in @keys and key not in @provenance do
      error(
        key,
        "#{key} is not a key an agent has: the keys are description, mode, model, tools, " <>
          "permissions, max_turns, budget_share, skills and override"
      )
    end
  end

  defp mode(:error),
    do: [
      error(
        "mode",
        "mode is missing: primary for an agent a session or branch runs, subagent for one " <>
          "an agent delegates to"
      )
    ]

  defp mode({:ok, mode}) when mode in ["primary", "subagent"], do: []
  defp mode({:ok, other}), do: [error("mode", describe({:bad_mode, other}))]

  defp tools(nil), do: []
  defp tools("all"), do: []

  defp tools(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1),
      do: Enum.flat_map(list, &tool("tools", &1)),
      else: [error("tools", describe({:bad_tools, list}))]
  end

  defp tools(other), do: [error("tools", describe({:bad_tools, other}))]

  # A tool by name: one the harness has, or one only a running server or client has.
  defp tool(field, name) do
    cond do
      known_tool?(name) ->
        []

      String.starts_with?(name, "mcp.") or String.starts_with?(name, "client.") ->
        [
          warning(
            field,
            "#{name} is an MCP server's or a client's tool, which is known only once it runs: " <>
              "not checked here"
          )
        ]

      true ->
        [error(field, "#{name} is not a tool: #{nearest_tools(name)}")]
    end
  end

  defp known_tool?(name),
    do: name in @scoped_tools or match?({:ok, _tool}, Troupe.Tools.fetch(name))

  defp nearest_tools(name) do
    names = Enum.map(Troupe.Tools.all(), &Troupe.Tool.name/1) ++ @scoped_tools

    case names |> Enum.sort_by(&(-String.jaro_distance(&1, name))) |> Enum.take(3) do
      [] -> "the harness has none of that name"
      near -> "the nearest are " <> Enum.join(near, ", ")
    end
  end

  defp permissions(map, tools) when is_map(map) do
    map
    |> Enum.sort()
    |> Enum.flat_map(fn {tool, value} -> permission(to_string(tool), value, tools) end)
  end

  defp permissions(other, _tools), do: [error("permissions", describe({:bad_permissions, other}))]

  defp permission(tool, value, tools) when value in ["auto", "ask", "deny"] do
    field = "permissions." <> tool

    case tool(field, tool) do
      [{:error, _unknown} | _] = unknown ->
        unknown

      checked ->
        if value != "deny" and is_list(tools) and tool not in tools,
          do: [
            error(
              field,
              "#{tool}: #{value} never applies: tools does not list #{tool}, so the agent " <>
                "cannot call it; add it to tools, or leave the permission out"
            )
          ],
          else: checked
    end
  end

  defp permission(tool, value, _tools),
    do: [error("permissions." <> tool, describe({:bad_permission, tool, value}))]

  defp skills(nil), do: []
  defp skills("all"), do: []

  defp skills(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1),
      do: [],
      else: [error("skills", describe({:bad_skills, list}))]
  end

  defp skills(other), do: [error("skills", describe({:bad_skills, other}))]

  # By the list of what each provider serves that the daemon already keeps (Decision 778):
  # nothing is asked of a provider here, so a save never waits on one.
  defp model(nil, _config), do: []

  defp model(model, _config) when not is_binary(model),
    do: [error("model", "model must be a model's name, not #{inspect(model)}")]

  defp model(_model, nil),
    do: [warning("model", "not checked: there is no configuration here to check it against")]

  defp model(model, %Config{} = config) do
    case Config.resolve_model(config, model) do
      resolved when is_binary(resolved) and resolved != "" -> served(model, resolved, config)
      _none -> [error("model", "#{model} names a model the configuration does not set")]
    end
  end

  defp served(model, resolved, config) do
    case Store.served(config, resolved) do
      {:served, _source} ->
        []

      {:not_served, _source, nearest} ->
        [
          error(
            "model",
            "#{named(model, resolved)} is not a model the provider serves#{near(nearest)}"
          )
        ]

      :unknown ->
        [
          warning(
            "model",
            "not checked: the provider has not listed its models on this machine " <>
              "(troupe models --refresh asks it)"
          )
        ]
    end
  end

  defp named(model, model), do: model
  defp named(model, resolved), do: "#{model} (#{resolved})"

  defp near([]), do: ""
  defp near(nearest), do: ": the nearest it serves are " <> Enum.join(nearest, ", ")

  defp max_turns(:error), do: []
  defp max_turns({:ok, n}) when is_integer(n) and n > 0, do: []

  defp max_turns({:ok, other}),
    do: [error("max_turns", "max_turns must be a whole number above 0, not #{inspect(other)}")]

  defp budget_share(:error), do: []

  defp budget_share({:ok, n}) when is_number(n) and n > 1,
    do: [
      warning(
        "budget_share",
        "budget_share is a share of the budget, at most 1: #{n} is read as 1"
      )
    ]

  defp budget_share({:ok, n}) when is_number(n) and n > 0, do: []

  defp budget_share({:ok, other}),
    do: [
      error(
        "budget_share",
        "budget_share must be a number above 0, at most 1, not #{inspect(other)}"
      )
    ]

  defp override(:error), do: []
  defp override({:ok, value}) when is_boolean(value), do: []

  defp override({:ok, other}),
    do: [error("override", "override must be true or false, not #{inspect(other)}")]

  defp description(text) when is_binary(text) and text != "", do: []

  defp description(_none),
    do: [warning("description", "there is no description: a picker shows it beside the name")]

  defp instruction(""),
    do: [warning("prompt", "the instruction is empty: the agent runs with Troupe's prompt alone")]

  defp instruction(_text), do: []

  defp error(field, message), do: {:error, %{field: field, message: message}}
  defp warning(field, message), do: {:warning, %{field: field, message: message}}
end
