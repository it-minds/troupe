defmodule Troupe.Agent.Imported do
  @moduledoc """
  The agents other tools already wrote into a workspace, read as Troupe's (Decision 819):
  Claude Code's subagents in `.claude/agents/*.md`, and the `agent` entries of the
  workspace's `opencode.json` or `opencode.jsonc`, with their `permission` settings.

  They are the workspace's layer of `Troupe.Agent.Definitions`: above the built-ins, a
  bundle and the person's own `agents/`, below the workspace's `.troupe/agents/`, whose
  file of a name wins. Of the two, a Claude Code file wins a name opencode's config also
  has: it is a whole agent in a file of its own, where an opencode entry is often a few
  settings on an agent of that name.

  Each is used as its own tool says: a Claude Code subagent as a subagent, an opencode
  agent by its `mode` (`all`, its default, is both). What Troupe cannot honour is mapped
  or left out, never silently: a definition carries `notes`, one `%{key, reason}` per key
  it changed or left out, and a file or an entry not read at all is in `skipped` with
  why, both in words a person reads in `agents.list` and the palette.

  A file is read only where it really is inside the workspace, links followed, as the
  instruction files are (Decision 798): one that is a link out is skipped, a
  `.claude/agents` that is a link out is not looked into, and an opencode prompt's
  `{file:...}` reads only from inside the workspace, so a repository cannot put a file
  from elsewhere on the machine into a prompt that goes to a provider.
  """

  alias Troupe.Agent.Definition
  alias Troupe.Config.OpenCode
  alias Troupe.LLM.Catalog.Store
  alias Troupe.Paths
  alias Troupe.Protocol.AgentDefinition
  alias Troupe.Workspace

  @typedoc "What was not read as an agent, and why, in words."
  @type skip :: %{name: String.t() | nil, file: String.t(), reason: String.t()}

  @type result :: %{definitions: [Definition.t()], skipped: [skip()]}

  @outside "not read: outside the workspace"

  # Claude Code's tool names, as Troupe's. `MultiEdit` and `LS` are older Claude Code's;
  # `Task` is what `Agent` was called.
  @claude_tools %{
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

  @claude_missing %{
    "WebSearch" => "Troupe has no web search tool",
    "NotebookEdit" => "Troupe has no notebook tool",
    "NotebookRead" => "Troupe has no notebook tool",
    "LSP" => "Troupe has no language-server tool",
    "Skill" => "a session's skills are offered to its agents as they are, not by a tool name"
  }

  @claude_read ~w(name description tools disallowedTools model maxTurns)

  @claude_keys %{
    "permissionMode" =>
      "not read: a mode for all of an agent's approvals has no counterpart here, where the session's approvals apply tool by tool",
    "skills" => "not read: a session's skills are offered to every agent as they are",
    "mcpServers" =>
      "not read: an agent's own MCP servers are not started; the session's are offered",
    "hooks" => "not read: Troupe runs no hooks",
    "memory" => "not read: Troupe keeps no memory per agent; the project brief is the session's",
    "background" => "not read: a subagent reports to the agent that started it, which waits",
    "effort" => "not read: how hard a model thinks is set per model, in models",
    "isolation" => "not read: a subagent works in its session's workspace",
    "color" => "not read: Troupe shows no colour per agent",
    "initialPrompt" => "not read: Claude Code sends it only when the agent is its main one",
    "omitClaudeMd" => "not read: every agent reads the instruction files"
  }

  # Claude Code's names for a model it picks itself.
  @claude_aliases ~r/\A(default|sonnet|opus|haiku|fable|opusplan)(\[1m\])?\z/

  # opencode's names, as Troupe's: its permission keys, each over the tools it gates, and
  # the tool names its `tools` switches use.
  @opencode_tools %{
    "read" => ["read_file"],
    "edit" => ["edit_file", "write_file"],
    "write" => ["write_file"],
    "patch" => ["edit_file"],
    "apply_patch" => ["edit_file"],
    "multiedit" => ["edit_file"],
    "glob" => ["glob"],
    "grep" => ["grep"],
    "list" => ["list_files"],
    "bash" => ["shell"],
    "task" => ["delegate"],
    "todowrite" => ["todo_write", "todo_read"],
    "todoread" => ["todo_read"],
    "webfetch" => ["web_fetch"],
    "question" => ["ask_user"]
  }

  @opencode_missing %{
    "websearch" => "Troupe has no web search tool",
    "codesearch" => "Troupe has no code search tool",
    "lsp" => "Troupe has no language-server tool",
    "skill" => "a session's skills are offered to its agents as they are",
    "external_directory" =>
      "Troupe's tools stay inside the session's workspace whatever this says",
    "doom_loop" => "Troupe has no such prompt"
  }

  @opencode_read ~w(description mode model prompt tools permission steps maxSteps disable)

  @opencode_keys %{
    "temperature" => "not read: Troupe sets no temperature per agent",
    "top_p" => "not read: Troupe sets no sampling per agent",
    "hidden" => "not read: Troupe has no menu of subagents to hide it from",
    "color" => "not read: Troupe shows no colour per agent",
    "options" => "not read: provider options are not set per agent",
    "variant" => "not read: a model's variants are not read"
  }

  @strictness %{auto: 0, ask: 1, deny: 2}

  @doc """
  The agents other tools wrote into `root`, given the definitions loaded below the
  workspace's layer (`below`), which an opencode entry without a prompt adjusts.

  `config:` judges a `model`: kept when the provider it goes to is known to serve it
  (`Troupe.LLM.Catalog.Store.served/3`), else the agent runs on the session's model.
  `served?:` stands in for that judgement.
  """
  @spec load(Path.t(), %{optional(String.t()) => Definition.t()}, keyword()) :: result()
  def load(root, below, opts \\ []) do
    served? = served(opts)
    opencode = opencode(root, below, served?)
    claude = claude_code(root, served?)
    claude_files = Map.new(claude.definitions, &{&1.name, &1.file})

    {kept, hidden} =
      Enum.split_with(opencode.definitions, &(not Map.has_key?(claude_files, &1.name)))

    %{
      definitions: kept ++ claude.definitions,
      skipped:
        opencode.skipped ++
          claude.skipped ++
          Enum.map(hidden, &skip(&1.name, &1.file, "skipped: #{claude_files[&1.name]} is used"))
    }
  end

  defp served(opts), do: Keyword.get_lazy(opts, :served?, fn -> served_by(opts[:config]) end)

  # A model the cache cannot place is one nothing is known to serve, never a session
  # that cannot start.
  defp served_by(%Troupe.Config{} = config) do
    fn model ->
      try do
        match?({:served, _source}, Store.served(config, model))
      rescue
        _error -> false
      end
    end
  end

  defp served_by(_none), do: fn _model -> false end

  ## Claude Code

  defp claude_code(root, served?) do
    dir = Path.join([root, ".claude", "agents"])

    cond do
      not File.dir?(dir) ->
        %{definitions: [], skipped: []}

      not inside?(dir, root) ->
        %{definitions: [], skipped: [skip(nil, shown(root, dir), @outside)]}

      true ->
        dir
        |> markdown()
        |> Enum.reduce(%{definitions: [], skipped: []}, fn entry, acc ->
          root |> claude_file(Path.join(dir, entry), served?) |> collect(acc)
        end)
        |> then(&%{&1 | definitions: Enum.reverse(&1.definitions)})
    end
  end

  defp markdown(dir) do
    case File.ls(dir) do
      {:ok, entries} -> entries |> Enum.filter(&String.ends_with?(&1, ".md")) |> Enum.sort()
      {:error, _reason} -> []
    end
  end

  # Two files of one name: the first in name order is the agent, as Claude Code keeps one
  # per name, and the other says so.
  defp collect({:ok, definition}, acc) do
    case Enum.find(acc.definitions, &(&1.name == definition.name)) do
      nil ->
        %{acc | definitions: [definition | acc.definitions]}

      first ->
        hidden =
          skip(definition.name, definition.file, "skipped: #{first.file} has the same name")

        %{acc | skipped: acc.skipped ++ [hidden]}
    end
  end

  defp collect({:skip, skip}, acc), do: %{acc | skipped: acc.skipped ++ [skip]}

  defp claude_file(root, path, served?) do
    file = shown(root, path)

    with :ok <- inside(path, root),
         {:ok, contents} <- read(path),
         {meta, body, read_notes} = frontmatter(contents),
         {:ok, name} <- name(meta["name"], Path.basename(path, ".md")),
         {:ok, tools, tool_notes} <- claude_tools(meta["tools"]) do
      {model, model_notes} = model(meta["model"], served?, :claude_code)
      {max_turns, turn_notes} = max_turns("maxTurns", meta["maxTurns"])

      {:ok,
       %Definition{
         name: name,
         prompt: String.trim(body),
         description: text(meta["description"]),
         mode: :subagent,
         model: model,
         tools: tools,
         permissions: claude_denied(meta["disallowedTools"]),
         max_turns: max_turns,
         source: :claude_code,
         file: file,
         notes:
           read_notes ++
             tool_notes ++
             model_notes ++ turn_notes ++ other_keys(meta, @claude_read, @claude_keys)
       }}
    else
      {:skip, reason} -> {:skip, skip(nil, file, reason)}
      {:skip, name, reason} -> {:skip, skip(name, file, reason)}
    end
  end

  # Absent is every tool, as Claude Code has it; a list keeps what Troupe has. One that
  # names nothing Troupe has is not an agent: Claude Code will not start it either.
  defp claude_tools(nil), do: {:ok, :all, []}

  defp claude_tools(value) do
    case entries(value) do
      [] ->
        {:ok, :all, []}

      entries ->
        {names, notes} = Enum.reduce(entries, {[], []}, &add_tool/2)

        if names == [],
          do:
            {:skip,
             "not read: none of its tools (#{Enum.join(entries, ", ")}) is one Troupe has, " <>
               "and Claude Code does not start such an agent either"},
          else: {:ok, list_for(names), notes}
    end
  end

  defp add_tool(entry, {names, notes}) do
    case claude_tool(entry) do
      {:ok, mapped} -> {names ++ mapped, notes}
      {:left_out, reason} -> {names, notes ++ [note("tools", reason)]}
    end
  end

  defp claude_tool(entry) do
    cond do
      Map.has_key?(@claude_tools, entry) ->
        {:ok, @claude_tools[entry]}

      Map.has_key?(@claude_missing, entry) ->
        {:left_out, "#{entry} is left out: #{@claude_missing[entry]}"}

      String.contains?(entry, "(") ->
        {:left_out,
         "#{entry} is left out: Troupe allows a tool whole or not at all, so a rule for some of its uses is not read"}

      String.starts_with?(entry, "mcp__") ->
        mcp_tool(entry)

      true ->
        {:left_out, "#{entry} is left out: it is not a tool Troupe has"}
    end
  end

  # `mcp__server__tool` is Troupe's `mcp.server.tool`; a whole server's tools by pattern
  # cannot be named in a list that names tools one by one.
  defp mcp_tool(entry) do
    case String.split(entry, "__", parts: 3) do
      ["mcp", server, tool] when server != "" and tool not in ["", "*"] ->
        {:ok, [Troupe.MCP.tool_name(server, tool)]}

      _pattern ->
        {:left_out,
         "#{entry} is left out: Troupe's tool list names an MCP server's tools one by one"}
    end
  end

  # Claude Code removes a disallowed tool whole, a rule for some of its uses included.
  defp claude_denied(value) do
    value
    |> entries()
    |> Enum.flat_map(fn entry ->
      case entry |> String.split("(", parts: 2) |> hd() |> String.trim() |> claude_tool() do
        {:ok, names} -> names
        {:left_out, _reason} -> []
      end
    end)
    |> Map.new(&{&1, :deny})
  end

  # `Read, Grep` or a YAML list; commas inside a rule's parentheses are the rule's.
  defp entries(value) when is_binary(value) do
    value
    |> String.split(~r/,(?![^(]*\))/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp entries(value) when is_list(value),
    do: value |> Enum.map(&(&1 |> to_string() |> String.trim())) |> Enum.reject(&(&1 == ""))

  defp entries(_other), do: []

  # A list of tools, with what Troupe's harness needs to honour it: `finish`, for a
  # subagent to report, and `read_output`, the rest of a cut `shell` or `grep` result.
  defp list_for(names) do
    companions = if Enum.any?(names, &(&1 in ["shell", "grep"])), do: ["read_output"], else: []
    Enum.uniq(names ++ companions ++ ["finish"])
  end

  ## opencode

  defp opencode(root, below, served?) do
    acc =
      root
      |> OpenCode.project()
      |> Enum.reduce(%{definitions: %{}, skipped: []}, fn file, acc ->
        opencode_file(root, file, below, served?, acc)
      end)

    %{
      definitions: acc.definitions |> Map.values() |> Enum.sort_by(& &1.name),
      skipped: acc.skipped
    }
  end

  defp opencode_file(_root, %{config: nil} = file, _below, _served?, acc),
    do: %{acc | skipped: acc.skipped ++ [skip(nil, file.name, file.reason)]}

  defp opencode_file(root, %{config: config} = file, below, served?, acc) do
    shared = %{tools: config["tools"], permission: config["permission"]}

    agents =
      case config["agent"] do
        agents when is_map(agents) -> Enum.sort(agents)
        _none -> []
      end

    Enum.reduce(agents, acc, fn {name, entry}, acc ->
      root
      |> opencode_agent(file, name, entry, shared, below, served?)
      |> add_agent(name, file, acc)
    end)
  end

  # A name both files define is the second's, as opencode merges it over the first.
  defp add_agent({:ok, definition}, name, file, acc) do
    hidden =
      case acc.definitions[name] do
        nil ->
          []

        earlier ->
          [skip(name, earlier.file, "skipped: #{file.name} defines it too, and is read after")]
      end

    %{
      acc
      | definitions: Map.put(acc.definitions, name, definition),
        skipped: acc.skipped ++ hidden
    }
  end

  defp add_agent({:skip, reason}, name, file, acc),
    do: %{acc | skipped: acc.skipped ++ [skip(name, file.name, reason)]}

  defp opencode_agent(root, file, name, entry, shared, below, served?) when is_map(entry) do
    with :ok <- enabled(entry),
         {:ok, name} <- name(name, nil),
         {:ok, prompt} <- opencode_prompt(root, file.path, entry["prompt"]) do
      {mode, mode_notes} = opencode_mode(entry["mode"])
      {model, model_notes} = model(entry["model"], served?, :opencode)
      {max_turns, turn_notes} = max_turns("steps", entry["steps"] || entry["maxSteps"])
      {access, access_notes} = access(shared, entry)

      fields = %{
        name: name,
        description: entry["description"],
        mode: mode,
        model: model,
        max_turns: max_turns,
        file: file.name,
        notes:
          mode_notes ++
            model_notes ++
            turn_notes ++ access_notes ++ other_keys(entry, @opencode_read, @opencode_keys)
      }

      base = if is_nil(prompt), do: below[name]
      {:ok, opencode_definition(base, prompt, fields, access)}
    else
      {:skip, _name, reason} -> {:skip, reason}
      {:skip, reason} -> {:skip, reason}
    end
  end

  defp opencode_agent(_root, _file, _name, _entry, _shared, _below, _served?),
    do: {:skip, "not read: not an object"}

  defp enabled(%{"disable" => true}), do: {:skip, "not read: disable is true"}
  defp enabled(_entry), do: :ok

  # An entry with a prompt is an agent of its own, every tool open but what its
  # permissions close. One without a prompt that names an agent below the workspace's
  # layer is opencode's way of adjusting that agent, as it adjusts its own `build`: it
  # keeps that agent's prompt and tools, and takes what the entry says over them. One
  # without a prompt that names nothing has no prompt but the instruction files.
  defp opencode_definition(nil, prompt, fields, access) do
    mode = fields.mode || :all

    notes =
      if is_nil(prompt),
        do: [
          note(
            "prompt",
            "none given: opencode would use its own, and here the agent has the instruction files alone"
          )
        ],
        else: []

    %Definition{
      name: fields.name,
      prompt: prompt || "",
      description: text(fields.description),
      mode: mode,
      model: fields.model,
      tools: tools_for(:all, access),
      permissions: access.permissions,
      max_turns: fields.max_turns,
      source: :opencode,
      file: fields.file,
      notes: notes ++ fields.notes
    }
  end

  defp opencode_definition(%Definition{} = base, nil, fields, access) do
    kept = note("prompt", "none given: it keeps the prompt of #{owner(base)} #{base.name} agent")

    %{
      base
      | description:
          if(is_binary(fields.description), do: fields.description, else: base.description),
        mode: fields.mode || base.mode,
        model: fields.model || base.model,
        tools: tools_for(base.tools, access),
        permissions: Map.merge(base.permissions, access.permissions),
        max_turns: fields.max_turns || base.max_turns,
        source: :opencode,
        file: fields.file,
        notes: [kept | fields.notes]
    }
  end

  defp owner(%Definition{source: :builtin}), do: "Troupe's built-in"
  defp owner(%Definition{source: :bundle}), do: "the profile's"
  defp owner(%Definition{source: :global}), do: "your own"

  # opencode's `tools` switches and `permission`, the file's under the agent's, as opencode
  # merges them. Each key comes to `allow`, `ask`, `deny`, `:on` (a tool switched on, whose
  # approval stays Troupe's own: only `permission` says allow) or a map of rules for some
  # of its uses. `*` is every tool.
  defp access(shared, entry) do
    actions =
      shared.tools
      |> switches()
      |> Map.merge(rules(shared.permission))
      |> Map.merge(switches(entry["tools"]))
      |> Map.merge(rules(entry["permission"]))

    {wildcard, actions} = Map.pop(actions, "*")
    {wildcard, wildcard_notes} = wildcard(wildcard)

    start = %{
      permissions: wildcard_permissions(wildcard),
      set: MapSet.new(),
      open: [],
      wildcard: wildcard
    }

    {access, notes} =
      actions
      |> Enum.sort()
      |> Enum.reduce({start, []}, fn {key, action}, {access, notes} ->
        case troupe_tools(key) do
          {:ok, names} ->
            {permission, note} = permission(key, action)
            {apply_permission(access, names, permission), notes ++ List.wrap(note)}

          {:left_out, reason} ->
            {access, notes ++ [note("permission", "#{key} is left out: #{reason}")]}
        end
      end)

    {access, wildcard_notes ++ notes}
  end

  # A key's word replaces what `*` said of its tools, and two keys over one tool (`edit`
  # and `write`) give it the stricter of theirs. `nil` says nothing; `:default` puts the
  # tool back to Troupe's own approval, unless another key has spoken for it. A tool a key
  # does not deny is open, which is what a `*: deny` agent's list is made of.
  defp apply_permission(access, names, permission) do
    {permissions, set} =
      Enum.reduce(names, {access.permissions, access.set}, fn name, {permissions, set} ->
        cond do
          is_nil(permission) or (permission == :default and MapSet.member?(set, name)) ->
            {permissions, set}

          permission == :default ->
            {Map.delete(permissions, name), set}

          MapSet.member?(set, name) ->
            {Map.update!(permissions, name, &stricter(&1, permission)), set}

          true ->
            {Map.put(permissions, name, permission), MapSet.put(set, name)}
        end
      end)

    open = if permission == :deny, do: access.open, else: Enum.uniq(access.open ++ names)
    %{access | permissions: permissions, set: set, open: open}
  end

  defp stricter(a, b), do: if(@strictness[a] >= @strictness[b], do: a, else: b)

  defp switches(map) when is_map(map) do
    Map.new(map, fn
      {key, true} -> {key, :on}
      {key, false} -> {key, "deny"}
      {key, other} -> {key, other}
    end)
  end

  defp switches(_other), do: %{}

  defp rules(map) when is_map(map), do: map
  defp rules(action) when is_binary(action), do: %{"*" => action}
  defp rules(_other), do: %{}

  defp troupe_tools(key) do
    cond do
      Map.has_key?(@opencode_tools, key) ->
        {:ok, @opencode_tools[key]}

      Map.has_key?(@opencode_missing, key) ->
        {:left_out, @opencode_missing[key]}

      String.contains?(key, "*") ->
        {:left_out, "Troupe's tools are named one by one, not by a pattern"}

      true ->
        {:left_out, "it is not a tool Troupe has"}
    end
  end

  defp permission(_key, "allow"), do: {:auto, nil}
  defp permission(_key, "ask"), do: {:ask, nil}
  defp permission(_key, "deny"), do: {:deny, nil}
  defp permission(_key, :on), do: {nil, nil}

  # Rules for some uses of a tool (`"git *": "allow"`) are not read: Troupe allows a tool
  # whole. Their `*` is, where it asks or denies; where it allows, the rules beside it
  # are what made it safe, so the tool keeps Troupe's own approval.
  defp permission(key, rules) when is_map(rules) do
    patterns = rules |> Map.keys() |> Enum.reject(&(&1 == "*")) |> Enum.sort()

    left_out =
      "the rules for #{Enum.join(patterns, ", ")} are left out: Troupe allows a tool whole or not at all"

    case {rules["*"], patterns} do
      {action, []} when is_binary(action) ->
        permission(key, action)

      {action, _patterns} when action in ["ask", "deny"] ->
        {elem(permission(key, action), 0), note("permission", "#{key}: #{left_out}")}

      _open ->
        {:default, note("permission", "#{key}: #{left_out}, so it keeps Troupe's own approval")}
    end
  end

  defp permission(key, other),
    do:
      {nil,
       note(
         "permission",
         "#{key}: #{inspect(other)} is not allow, ask or deny, so it is left out"
       )}

  defp wildcard(nil), do: {nil, []}
  defp wildcard(action) when action in ["allow", "ask", "deny"], do: {action, []}
  defp wildcard(:on), do: {nil, []}
  defp wildcard(other), do: {nil, [elem(permission("*", other), 1)] |> Enum.reject(&is_nil/1)}

  # `*: ask` and `*: allow` are every tool's approval where no key says otherwise; `*:
  # deny` closes every tool no key opens.
  defp wildcard_permissions(action) when action in ["allow", "ask"] do
    {permission, nil} = permission("*", action)
    @opencode_tools |> Map.values() |> List.flatten() |> Map.new(&{&1, permission})
  end

  defp wildcard_permissions(_action), do: %{}

  defp tools_for(_tools, %{wildcard: "deny", open: open}), do: list_for(open)
  defp tools_for(:all, _access), do: :all
  defp tools_for(tools, %{open: open}), do: list_for(tools ++ open)

  defp opencode_mode(nil), do: {nil, []}
  defp opencode_mode("primary"), do: {:primary, []}
  defp opencode_mode("subagent"), do: {:subagent, []}
  defp opencode_mode("all"), do: {:all, []}

  defp opencode_mode(other),
    do:
      {nil,
       [
         note(
           "mode",
           "#{inspect(other)} is not primary, subagent or all, so it is all, opencode's default"
         )
       ]}

  # The prompt as written, or with each `{file:path}` replaced by that file, read from the
  # config's directory and only from inside the workspace.
  defp opencode_prompt(_root, _config_path, nil), do: {:ok, nil}

  defp opencode_prompt(root, config_path, prompt) when is_binary(prompt) do
    ~r/\{file:([^}]+)\}/
    |> Regex.scan(prompt)
    |> Enum.reduce_while({:ok, prompt}, fn [reference, path], {:ok, prompt} ->
      full = path |> String.trim() |> Path.expand(Path.dirname(config_path))

      case prompt_file(root, full, reference) do
        {:ok, text} -> {:cont, {:ok, String.replace(prompt, reference, text)}}
        skip -> {:halt, skip}
      end
    end)
    |> then(fn
      {:ok, prompt} -> {:ok, String.trim(prompt)}
      skip -> skip
    end)
  end

  defp opencode_prompt(_root, _config_path, _other),
    do: {:skip, "not read: its prompt is not text"}

  defp prompt_file(root, full, reference) do
    cond do
      not inside?(full, root) ->
        {:skip, "not read: its prompt reads #{reference}, which is outside the workspace"}

      not File.regular?(full) ->
        {:skip, "not read: its prompt reads #{reference}, and #{shown(root, full)} is not there"}

      true ->
        case File.read(full) do
          {:ok, text} ->
            {:ok, String.trim(text)}

          {:error, reason} ->
            {:skip, "not read: its prompt reads #{reference}: #{:file.format_error(reason)}"}
        end
    end
  end

  ## Both

  # Kept when the provider it goes to is known to serve it; otherwise, an alias or a model
  # nothing here serves, the session's. `inherit` is the session's by its own say.
  defp model(nil, _served?, _tool), do: {nil, []}

  defp model(model, served?, tool) when is_binary(model) do
    model = String.trim(model)

    cond do
      model in ["", "inherit"] ->
        {nil, []}

      served?.(model) ->
        {model, []}

      tool == :claude_code and Regex.match?(@claude_aliases, model) ->
        {nil,
         [
           note(
             "model",
             "#{model} is Claude Code's name for a model it picks itself, so the agent runs on the session's model"
           )
         ]}

      true ->
        {nil,
         [
           note(
             "model",
             "#{model} is not a model the session's provider is known to serve, so the agent runs on the session's model"
           )
         ]}
    end
  end

  defp model(other, _served?, _tool),
    do:
      {nil,
       [
         note(
           "model",
           "#{inspect(other)} is not a model's name, so the agent runs on the session's model"
         )
       ]}

  defp max_turns(_key, nil), do: {nil, []}
  defp max_turns(_key, n) when is_integer(n) and n > 0, do: {n, []}

  defp max_turns(key, n) when is_binary(n) do
    case Integer.parse(String.trim(n)) do
      {int, ""} when int > 0 -> {int, []}
      _other -> {nil, [bad_turns(key, n)]}
    end
  end

  defp max_turns(key, other), do: {nil, [bad_turns(key, other)]}

  defp bad_turns(key, value),
    do:
      note(
        key,
        "#{inspect(value)} is not a positive number, so the agent has the session's limit"
      )

  defp name(given, fallback) do
    name =
      case given do
        given when is_binary(given) and given != "" -> String.trim(given)
        _absent -> fallback
      end

    if AgentDefinition.valid_name?(name),
      do: {:ok, name},
      else:
        {:skip, name,
         "not read: #{inspect(name)} is not a name Troupe can give an agent (lower-case letters, digits and dashes, at most 64)"}
  end

  defp other_keys(meta, read, reasons) do
    meta
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 in read))
    |> Enum.sort()
    |> Enum.map(&note(&1, Map.get(reasons, &1, "not read: it is not a key Troupe reads")))
  end

  # YAML, as Claude Code writes it; failing that, a line per key, which is how a
  # description with a colon in it is still read (`description: Use when: ...`).
  defp frontmatter(contents) do
    case AgentDefinition.split_frontmatter(contents) do
      {"", body} ->
        {%{}, body, []}

      {yaml, body} ->
        case YamlElixir.read_from_string(yaml) do
          {:ok, meta} when is_map(meta) ->
            {meta, body, []}

          _not_a_map ->
            {line_keys(yaml), body,
             [note("frontmatter", "not YAML, so each line is read as a key and its value")]}
        end
    end
  end

  defp line_keys(yaml) do
    yaml
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({%{}, nil}, &line_key/2)
    |> elem(0)
  end

  defp line_key(line, {meta, last}) do
    case {Regex.run(~r/\A([A-Za-z][\w-]*):\s*(.*?)\s*\z/, line),
          Regex.run(~r/\A\s+-\s+(.*?)\s*\z/, line)} do
      {[_line, key, value], _item} ->
        {Map.put(meta, key, unquote_value(value)), key}

      {nil, [_line, item]} when is_binary(last) ->
        {Map.update!(meta, last, &append(&1, unquote_value(item))), last}

      _other ->
        {meta, last}
    end
  end

  defp append("", item), do: [item]
  defp append(list, item) when is_list(list), do: list ++ [item]
  defp append(other, _item), do: other

  defp unquote_value(<<q, rest::binary>> = value) when q in [?", ?'] do
    if String.ends_with?(rest, <<q>>), do: String.slice(rest, 0..-2//1), else: value
  end

  defp unquote_value(value), do: value

  defp text(value) when is_binary(value), do: value
  defp text(nil), do: ""
  defp text(value), do: to_string(value)

  defp note(key, reason), do: %{key: key, reason: reason}
  defp skip(name, file, reason), do: %{name: name, file: file, reason: reason}

  defp inside(path, root), do: if(inside?(path, root), do: :ok, else: {:skip, @outside})

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:skip, "not read: #{:file.format_error(reason)}"}
    end
  end

  # Whether a path really is in the workspace, links followed, as the instruction files
  # are judged (Decision 798).
  defp inside?(path, root) do
    with {:ok, real} <- Workspace.real_path(path),
         {:ok, real_root} <- Workspace.real_path(root) do
      String.starts_with?(Workspace.compare_key(real), Workspace.compare_key(real_root) <> "/")
    else
      _error -> false
    end
  end

  defp shown(root, path), do: Paths.display(Path.relative_to(path, Path.expand(root)))
end
