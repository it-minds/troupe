defmodule Troupe.Protocol.AgentCheck do
  @moduledoc """
  An agent definition checked as it is written (#503, #594): everything a file can get
  wrong that the loader forgives or drops, as errors and warnings, each naming the field
  it is about with a sentence.

  Three writers write the same definition: a person (their own agents), a repository
  (`.troupe/agents/`) and an organisation (a config bundle's agents, through the console).
  The daemon checks the first two with `agents.validate` and `agents.put`; the plane checks
  the third when a bundle is validated, previewed or published, and the console's agent
  builder asks it field by field. The plane does not depend on the harness, so the rules
  live here, where both can see them, and a definition the daemon refuses is refused by the
  plane in the same words.

  What only the harness knows comes in as options: `known_tool?` (a tool a session there
  has), `tools` (the names the nearest are taken from) and `model` (the model checked
  against the provider's list). Without them a tool is checked against the harness's
  built-ins, listed here (`harness_tools/0`, which core's test holds to its own list), and a
  model is not checked, with a warning.

  - **Errors:** the frontmatter is not YAML; a key no agent has; `mode` missing or not
    `primary`, `subagent` or `function`; `tools` or `skills` not `all` or a list of names; a tool that
    does not exist; a permission that is not `auto`, `ask` or `deny`; a permission that
    grants (`auto` or `ask`) a tool `tools` does not list, which could never apply (a
    `deny` of one says what leaving it out says, and the built-ins do it to make the denial
    plain); a `max_turns` that is not a positive whole number; a `budget_share` that is not
    a number above 0; an `override` that is not true or false; a `delegation` that is not
    `ask` or `auto`; a name an agent may not have; and whatever `model` finds.
  - **Warnings:** what cannot be checked here (an MCP server's tool or a client's, which
    exist only once they run), a `budget_share` above 1 (read as 1), an empty description,
    and an empty instruction.

  Onboarding's provenance keys (`imported_from` and the rest) are keys an agent's file may
  have.
  """

  alias Troupe.Protocol.AgentDefinition

  @keys ~w(description mode model tools permissions max_turns budget_share skills override delegation)
  @provenance ~w(imported_from imported_hash imported_at imported_also imported_version)

  # The harness's own tools, by name: what `Troupe.Tools` holds in every session.
  @harness_tools ~w(read_file write_file edit_file list_files grep shell publish import
                    todo_write todo_read delegate stop_child finish read_branch remember recall
                    read_output ask_user web_fetch git_read glob onboard_write show patch)

  # Tools the harness offers outside its own list: the skill tool, when the session's
  # bundle or files have skills the profile names, and a loop's verdict. And a worker's
  # GitHub tools, which a pod offers to a session created with a repository and nowhere
  # else: an agent made for that work names them wherever it is written.
  @scoped_tools ~w(skill goal_complete git_push pr_open pr_comment pr_checks)

  @type finding :: %{field: String.t(), message: String.t()}
  @type result :: %{ok: boolean(), errors: [finding()], warnings: [finding()]}
  @type tagged :: {:error, finding()} | {:warning, finding()}

  @doc "The harness's own tools by name, as every session has them."
  @spec harness_tools() :: [String.t()]
  def harness_tools, do: @harness_tools

  @doc "The tools a session may have beyond the harness's own list, by name."
  @spec scoped_tools() :: [String.t()]
  def scoped_tools, do: @scoped_tools

  @doc """
  Check a definition's text. `name:` is the name it would be saved under (checked when
  given). `known_tool?:` says whether a tool exists, `tools:` are the names the nearest are
  taken from, and `model:` checks a model's name, answering findings (`error/2`,
  `warning/2`); without it a model is not checked, and a warning says so.
  """
  @spec check(String.t(), keyword()) :: result()
  def check(source, opts \\ []) when is_binary(source) do
    {frontmatter, body} = AgentDefinition.split_frontmatter(source)

    findings =
      case decode(frontmatter) do
        {:ok, meta} ->
          name(opts[:name]) ++ fields(meta, body, opts)

        {:error, message} ->
          name(opts[:name]) ++ [error("frontmatter", message)]
      end

    errors = for {:error, finding} <- findings, do: finding
    warnings = for {:warning, finding} <- findings, do: finding
    %{ok: errors == [], errors: errors, warnings: warnings}
  end

  @doc "What a model is checked against where there is nothing to check it against."
  @spec model_unchecked() :: [tagged()]
  def model_unchecked,
    do: [warning("model", "not checked: there is no configuration here to check it against")]

  @doc """
  What the shared parser's error says, in words: the reason a file that does not load is
  listed with, and a file that cannot be read.
  """
  @spec describe(term()) :: String.t()
  def describe({:bad_frontmatter, reason}),
    do: "its frontmatter is not YAML (#{yaml_error(reason)})"

  def describe({:bad_mode, mode}),
    do: "mode must be primary, subagent or function, not #{inspect(mode)}"

  def describe({:bad_tools, tools}),
    do: "tools must be all or a list of names, not #{inspect(tools)}"

  def describe({:bad_skills, skills}),
    do: "skills must be all or a list of names, not #{inspect(skills)}"

  def describe({:bad_permission, tool, value}),
    do: "the permission for #{tool} must be auto, ask or deny, not #{inspect(value)}"

  def describe({:bad_permissions, value}),
    do: "permissions must be a map of tool names to auto, ask or deny, not #{inspect(value)}"

  def describe({:bad_delegation, value}),
    do: "delegation must be ask or auto, not #{inspect(value)}"

  def describe(reason) when is_atom(reason),
    do: "it cannot be read (#{:file.format_error(reason)})"

  def describe(reason), do: inspect(reason)

  @doc "An error about a field, as `check/2` finds one."
  @spec error(String.t(), String.t()) :: tagged()
  def error(field, message), do: {:error, %{field: field, message: message}}

  @doc "A warning about a field, as `check/2` finds one."
  @spec warning(String.t(), String.t()) :: tagged()
  def warning(field, message), do: {:warning, %{field: field, message: message}}

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

  defp fields(meta, body, opts) do
    tools = Map.get(meta, "tools")
    tool = tool_check(opts)

    unknown_keys(meta) ++
      mode(Map.fetch(meta, "mode")) ++
      tools(tools, tool) ++
      permissions(Map.get(meta, "permissions", %{}), tools, tool) ++
      skills(Map.get(meta, "skills")) ++
      model(Map.get(meta, "model"), opts[:model]) ++
      max_turns(Map.fetch(meta, "max_turns")) ++
      budget_share(Map.fetch(meta, "budget_share")) ++
      override(Map.fetch(meta, "override")) ++
      delegation(Map.fetch(meta, "delegation")) ++
      description(Map.get(meta, "description")) ++
      instruction(String.trim(body))
  end

  defp unknown_keys(meta) do
    for key <- meta |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
        key not in @keys and key not in @provenance do
      error(
        key,
        "#{key} is not a key an agent has: the keys are description, mode, model, tools, " <>
          "permissions, max_turns, budget_share, skills, override and delegation"
      )
    end
  end

  defp mode(:error),
    do: [
      error(
        "mode",
        "mode is missing: primary for an agent a session or branch runs, subagent for one " <>
          "an agent delegates to, function for one the harness starts for a job of its own"
      )
    ]

  defp mode({:ok, mode}) when mode in ["primary", "subagent", "function"], do: []
  defp mode({:ok, other}), do: [error("mode", describe({:bad_mode, other}))]

  defp tools(nil, _tool), do: []
  defp tools("all", _tool), do: []

  defp tools(list, tool) when is_list(list) do
    if Enum.all?(list, &is_binary/1),
      do: Enum.flat_map(list, &tool.("tools", &1)),
      else: [error("tools", describe({:bad_tools, list}))]
  end

  defp tools(other, _tool), do: [error("tools", describe({:bad_tools, other}))]

  # A tool by name: one the harness has, or one only a running server or client has.
  defp tool_check(opts) do
    known? = Keyword.get(opts, :known_tool?, &(&1 in @harness_tools or &1 in @scoped_tools))
    names = Keyword.get(opts, :tools, @harness_tools ++ @scoped_tools)

    fn field, name ->
      cond do
        known?.(name) ->
          []

        String.starts_with?(name, "mcp.") or String.starts_with?(name, "client.") ->
          [
            warning(
              field,
              "#{name} is an MCP server's or a client's tool, which is known only once it " <>
                "runs: not checked here"
            )
          ]

        true ->
          [error(field, "#{name} is not a tool: #{nearest_tools(name, names)}")]
      end
    end
  end

  defp nearest_tools(name, names) do
    case names |> Enum.sort_by(&(-String.jaro_distance(&1, name))) |> Enum.take(3) do
      [] -> "the harness has none of that name"
      near -> "the nearest are " <> Enum.join(near, ", ")
    end
  end

  defp permissions(map, tools, tool) when is_map(map) do
    map
    |> Enum.sort()
    |> Enum.flat_map(fn {name, value} -> permission(to_string(name), value, tools, tool) end)
  end

  defp permissions(other, _tools, _tool),
    do: [error("permissions", describe({:bad_permissions, other}))]

  defp permission(name, value, tools, tool) when value in ["auto", "ask", "deny"] do
    field = "permissions." <> name

    case tool.(field, name) do
      [{:error, _unknown} | _] = unknown ->
        unknown

      checked ->
        if value != "deny" and is_list(tools) and name not in tools,
          do: [
            error(
              field,
              "#{name}: #{value} never applies: tools does not list #{name}, so the agent " <>
                "cannot call it; add it to tools, or leave the permission out"
            )
          ],
          else: checked
    end
  end

  defp permission(name, value, _tools, _tool),
    do: [error("permissions." <> name, describe({:bad_permission, name, value}))]

  defp skills(nil), do: []
  defp skills("all"), do: []

  defp skills(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1),
      do: [],
      else: [error("skills", describe({:bad_skills, list}))]
  end

  defp skills(other), do: [error("skills", describe({:bad_skills, other}))]

  defp model(nil, _check), do: []

  defp model(model, _check) when not is_binary(model),
    do: [error("model", "model must be a model's name, not #{inspect(model)}")]

  defp model(_model, nil), do: model_unchecked()
  defp model(model, check) when is_function(check, 1), do: check.(model)

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

  defp delegation(:error), do: []
  defp delegation({:ok, value}) when value in ["ask", "auto"], do: []
  defp delegation({:ok, other}), do: [error("delegation", describe({:bad_delegation, other}))]

  defp description(text) when is_binary(text) and text != "", do: []

  defp description(_none),
    do: [warning("description", "there is no description: a picker shows it beside the name")]

  defp instruction(""),
    do: [warning("prompt", "the instruction is empty: the agent runs with Troupe's prompt alone")]

  defp instruction(_text), do: []
end
