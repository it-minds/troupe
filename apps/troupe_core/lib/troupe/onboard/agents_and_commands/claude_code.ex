defmodule Troupe.Onboard.AgentsAndCommands.ClaudeCode do
  @moduledoc """
  Claude Code's subagents (`.claude/agents/*.md`), the permission rules of its shared
  `.claude/settings.json` that go with them, and its commands (`.claude/commands/*.md`),
  as Troupe's (Decision 824).

  A subagent is a Troupe subagent. Its tools map to Troupe's, its `disallowedTools` deny,
  and the settings' `allow`, `ask` and `deny` are `auto`, `ask` and `deny` for the tools
  it has, the stricter of two winning, as Claude Code's deny beats its ask and its allow.
  A rule for some uses of a tool (`Bash(git log:*)`) cannot be carried, since Troupe
  allows a tool whole or not at all: one that allows is left out, one that asks or denies
  makes the whole tool ask, so nothing Claude Code would have asked about or refused runs
  without asking. Everything else that cannot be carried is in the notes.
  """

  alias Troupe.Agent.Definition
  alias Troupe.Config.JSONC
  alias Troupe.Onboard.AgentsAndCommands.Shared

  # Claude Code's tool names, as Troupe's. `MultiEdit` and `LS` are older Claude Code's;
  # `Task` is what `Agent` was called.
  @tools %{
    "Read" => ["read_file"],
    "Write" => ["write_file"],
    "Edit" => ["edit_file"],
    "MultiEdit" => ["edit_file"],
    "Bash" => ["shell"],
    "PowerShell" => ["shell"],
    "Grep" => ["grep"],
    "Glob" => ["glob"],
    "LS" => ["list_files"],
    "WebFetch" => ["web_fetch"],
    "TodoWrite" => ["todo_write", "todo_read"],
    "Agent" => ["delegate"],
    "Task" => ["delegate"],
    "AskUserQuestion" => ["ask_user"]
  }

  # In a permission rule `Edit` is every tool that writes a file, `Write` among them.
  @rule_tools Map.put(@tools, "Edit", ["edit_file", "write_file"])

  @missing %{
    "WebSearch" => "Troupe has no web search tool",
    "NotebookEdit" => "Troupe has no notebook tool",
    "NotebookRead" => "Troupe has no notebook tool",
    "LSP" => "Troupe has no language-server tool",
    "Skill" => "a session's skills are offered to its agents as they are, not by a tool name"
  }

  @read ~w(name description tools disallowedTools model maxTurns)

  @keys %{
    "permissionMode" =>
      "a mode for all of an agent's approvals has no counterpart here, where approvals are per tool",
    "skills" => "a session's skills are offered to every agent as they are",
    "mcpServers" => "an agent's own MCP servers are not started; the session's are offered",
    "hooks" => "Troupe runs no hooks",
    "memory" => "Troupe keeps no memory per agent; the project brief is the session's",
    "background" => "a subagent reports to the agent that started it, which waits",
    "effort" => "how hard a model thinks is set per model, in models",
    "isolation" => "a subagent works in its session's workspace",
    "color" => "Troupe shows no colour per agent",
    "initialPrompt" => "Claude Code sends it only when the agent is its main one",
    "omitClaudeMd" => "every agent reads the instruction files"
  }

  @command_keys %{
    "allowed-tools" =>
      "it lets the command's turn use those tools without asking, and a Troupe command is a prompt " <>
        "that goes through the session's approvals like any other (Decision 763)",
    "disallowed-tools" => "a command's turn has the tools of the session's agent",
    "model" => "a Troupe command runs on the session's agent and its model (Decision 763)",
    "agent" => "a Troupe command runs on the session's agent (Decision 763)",
    "context" => "a Troupe command's prompt goes into the session's own conversation",
    "arguments" => "Troupe fills $ARGUMENTS alone, so named placeholders stay as written",
    "disable-model-invocation" => "Troupe's model never runs a command; a person typing it does",
    "user-invocable" => "every Troupe command is one a person types",
    "when_to_use" => "Troupe's model does not choose commands",
    "effort" => "how hard a model thinks is set per model, in models",
    "hooks" => "Troupe runs no hooks",
    "shell" => "Troupe does not run a command's shell lines"
  }

  @settings_keys %{
    "defaultMode" =>
      "a mode for all of a session's approvals has no counterpart here, where approvals are per tool",
    "additionalDirectories" =>
      "a Troupe agent's tools reach its session's workspace and read roots",
    "disableBypassPermissionsMode" => "Troupe has no mode that skips approvals"
  }

  @settings ".claude/settings.json"

  @doc "Claude Code's subagents in `root`, as Troupe's, with what was not proposed."
  @spec agents(Path.t()) :: {[Shared.agent()], [Shared.skip()]}
  def agents(root) do
    settings = settings(root)
    {agents, skipped} = Shared.each_markdown(root, ".claude/agents", &agent(root, &1, settings))
    {agents, settings.skipped ++ skipped}
  end

  @doc "Claude Code's commands in `root`, as Troupe's, with what was not proposed."
  @spec commands(Path.t()) :: {[Shared.command()], [Shared.skip()]}
  def commands(root) do
    Shared.each_markdown(
      root,
      ".claude/commands",
      &Shared.command(root, &1, 0, @command_keys, "it is not a key a Troupe command reads")
    )
  end

  defp agent(root, path, settings) do
    source = Shared.relative(root, path)

    with {:ok, bytes} <- Shared.read(root, path),
         {meta, body, read_notes} = Shared.frontmatter(bytes),
         {:ok, name, name_notes} <- Shared.name(meta["name"], Path.basename(path, ".md")),
         {:ok, tools, asks, tool_notes} <- tools(meta["tools"]) do
      {model, model_notes} = Shared.model(meta["model"], :claude_code)
      {max_turns, turn_notes} = Shared.max_turns("maxTurns", meta["maxTurns"])
      {denied, deny_notes} = disallowed(meta["disallowedTools"])
      has? = fn tool -> tools == :all or tool in tools end

      permissions =
        settings.permissions
        |> Map.filter(fn {tool, _permission} -> has?.(tool) end)
        |> Shared.merge_stricter(asks)
        |> Shared.merge_stricter(denied)

      {:ok,
       %{
         definition: %Definition{
           name: name,
           prompt: String.trim(body),
           description: Shared.text(meta["description"]) || "",
           mode: :subagent,
           model: model,
           tools: tools,
           permissions: permissions,
           max_turns: max_turns,
           source: :project
         },
         notes:
           read_notes ++
             name_notes ++
             tool_notes ++
             deny_notes ++
             model_notes ++
             turn_notes ++
             settings.notes ++
             Shared.other_keys(meta, @read, @keys, "it is not a key a Troupe agent reads"),
         source: source,
         source_hash: Shared.hash(bytes),
         label: source,
         rank: 0
       }}
    else
      {:skip, reason} -> {:skip, Shared.skip(source, nil, reason)}
      {:skip, name, reason} -> {:skip, Shared.skip(source, name, reason)}
    end
  end

  # Absent is every tool, as Claude Code has it; a list keeps what Troupe has. A rule for
  # some uses offers the whole tool, asking every time. One that names nothing Troupe has
  # is not an agent: Claude Code will not start it either.
  defp tools(nil), do: {:ok, :all, %{}, []}

  defp tools(value) do
    case Shared.entries(value) do
      [] ->
        {:ok, :all, %{}, []}

      entries ->
        {whole, some, notes} = Enum.reduce(entries, {[], [], []}, &grant/2)

        if whole ++ some == [] do
          {:skip,
           "not proposed: none of its tools (#{Enum.join(entries, ", ")}) is one Troupe has, " <>
             "and Claude Code does not start such an agent either"}
        else
          asks = some |> Enum.reject(&(&1 in whole)) |> Map.new(&{&1, :ask})
          {:ok, Shared.list_for(whole ++ some), asks, notes}
        end
    end
  end

  defp grant(entry, {whole, some, notes}) do
    case tool(entry, @tools) do
      {:whole, names} ->
        {whole ++ names, some, notes}

      {:some, names} ->
        {whole, some ++ names,
         notes ++
           [
             "#{entry} in tools cannot be carried as written: Troupe allows a tool whole or not at all, " <>
               "so #{Enum.join(names, ", ")} is offered and asks every time."
           ]}

      {:left_out, why} ->
        {whole, some, notes ++ ["#{entry} in tools is left out: #{why}."]}
    end
  end

  # A disallowed tool is denied; a rule for some of its uses makes the whole tool ask.
  defp disallowed(value) do
    value
    |> Shared.entries()
    |> Enum.reduce({%{}, []}, fn entry, {permissions, notes} ->
      case tool(entry, @tools) do
        {:whole, names} ->
          {Shared.merge_stricter(permissions, Map.new(names, &{&1, :deny})), notes}

        {:some, names} ->
          {Shared.merge_stricter(permissions, Map.new(names, &{&1, :ask})),
           notes ++
             [
               "#{entry} in disallowedTools cannot be carried as written: Troupe allows a tool whole " <>
                 "or not at all, so #{Enum.join(names, ", ")} asks every time instead."
             ]}

        {:left_out, why} ->
          {permissions, notes ++ ["#{entry} in disallowedTools is left out: #{why}."]}
      end
    end)
  end

  # `{:whole, names}` for a tool, `{:some, names}` for a rule naming some of its uses
  # (`Bash(git log:*)`; `Bash(*)` is all of them), `{:left_out, why}` for what Troupe has
  # no tool for.
  defp tool(entry, table) do
    case Regex.run(~r/\A([^()]+)\((.*)\)\z/s, entry) do
      [_entry, base, spec] -> base |> String.trim() |> named(table) |> for_uses(spec)
      nil -> named(entry, table)
    end
  end

  defp named(name, table) do
    cond do
      Map.has_key?(table, name) -> {:whole, table[name]}
      Map.has_key?(@missing, name) -> {:left_out, @missing[name]}
      String.starts_with?(name, "mcp__") -> mcp_tool(name)
      true -> {:left_out, "it is not a tool Troupe has"}
    end
  end

  defp for_uses({:whole, names}, spec),
    do: if(String.trim(spec) in ["", "*"], do: {:whole, names}, else: {:some, names})

  defp for_uses(left_out, _spec), do: left_out

  # `mcp__server__tool` is Troupe's `mcp.server.tool`; a whole server's tools by pattern
  # cannot be named in a list that names tools one by one.
  defp mcp_tool(entry) do
    case String.split(entry, "__", parts: 3) do
      ["mcp", server, tool] when server != "" and tool != "" ->
        if String.contains?(server <> tool, "*"),
          do: {:left_out, "Troupe names an MCP server's tools one by one, not by a pattern"},
          else: {:whole, [Troupe.MCP.tool_name(server, tool)]}

      _server ->
        {:left_out, "Troupe names an MCP server's tools one by one, not a whole server"}
    end
  end

  ## .claude/settings.json

  # The shared settings' permission rules, as the approvals they give each tool. The
  # person's own `.claude/settings.local.json` is theirs, and not a repository's to carry.
  defp settings(root) do
    path = Path.join(root, @settings)
    none = %{permissions: %{}, notes: [], skipped: []}

    with true <- File.regular?(path),
         {:ok, bytes} <- Shared.read(root, path),
         {:ok, settings} when is_map(settings) <- JSONC.decode(bytes) do
      case settings["permissions"] do
        permissions when is_map(permissions) -> settings_permissions(permissions)
        _none -> none
      end
    else
      false ->
        none

      {:skip, reason} ->
        %{none | skipped: [Shared.skip(@settings, nil, reason)]}

      _not_an_object ->
        %{none | skipped: [Shared.skip(@settings, nil, "not read: not a JSON object")]}
    end
  end

  defp settings_permissions(permissions) do
    rules =
      for {key, action} <- [{"allow", :auto}, {"ask", :ask}, {"deny", :deny}],
          entry <- Shared.entries(permissions[key]),
          do: {key, action, entry, tool(entry, @rule_tools)}

    by_tool =
      for {_key, action, _entry, {kind, names}} when kind in [:whole, :some] <- rules,
          name <- names,
          reduce: %{} do
        acc -> Map.update(acc, name, [{action, kind == :whole}], &[{action, kind == :whole} | &1])
      end

    approvals =
      for {tool, pairs} <- by_tool,
          permission = Shared.resolve(pairs),
          permission != nil,
          into: %{},
          do: {tool, permission}

    others =
      permissions
      |> Map.drop(["allow", "ask", "deny"])
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(
        &"permissions.#{&1} in #{@settings} is left out: #{Map.get(@settings_keys, &1, "it is not a permission Troupe has")}."
      )

    %{permissions: approvals, notes: Enum.flat_map(rules, &rule_note/1) ++ others, skipped: []}
  end

  defp rule_note({key, :auto, entry, {:some, _names}}),
    do: [
      "#{entry} in #{@settings}'s permissions.#{key} is left out: Troupe allows a tool whole or not at all, " <>
        "so a rule allowing some of its uses is not carried."
    ]

  defp rule_note({key, _ask_or_deny, entry, {:some, names}}),
    do: [
      "#{entry} in #{@settings}'s permissions.#{key} cannot be carried as written: Troupe allows a tool " <>
        "whole or not at all, so #{Enum.join(names, ", ")} asks every time instead."
    ]

  defp rule_note({key, _action, entry, {:left_out, why}}),
    do: ["#{entry} in #{@settings}'s permissions.#{key} is left out: #{why}."]

  defp rule_note(_whole), do: []
end
