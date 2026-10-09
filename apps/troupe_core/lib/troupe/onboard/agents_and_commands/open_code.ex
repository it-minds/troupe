defmodule Troupe.Onboard.AgentsAndCommands.OpenCode do
  @moduledoc """
  opencode's agents and commands, as Troupe's (Decision 824): the `agent` entries of the
  workspace's `opencode.json` and `opencode.jsonc`, the markdown agents of
  `.opencode/agents/` and `.opencode/agent/` (opencode's own documentation uses both), and
  the markdown commands of `.opencode/commands/` and `.opencode/command/`.

  The files' own `permission` and `tools` apply under each agent's, as opencode merges
  them. `allow`, `ask` and `deny` are `auto`, `ask` and `deny`, keys over Troupe's tools,
  `*` over every tool; two keys over one tool give it the stricter. A tool's rules for
  some of its uses (`bash: {"git *": "allow"}`) cannot be carried, since Troupe allows a
  tool whole or not at all: what they come to is `Shared.resolve/1`'s, so nothing opencode
  would have asked about or refused runs without asking.

  opencode's `mode: all`, its default, is both a primary and a subagent; a Troupe agent is
  one or the other, and is `primary` here, the one a person can pick, which the note says.
  An entry without a prompt that names one of Troupe's built-in agents adjusts it, as
  opencode adjusts its own `build`: the proposal is that agent with the entry's settings
  over it.
  """

  alias Troupe.Agent.Definition
  alias Troupe.Config.JSONC
  alias Troupe.Onboard.AgentsAndCommands.Shared

  # opencode's permission keys, each over the tools it gates, and the tool names its
  # `tools` switches use.
  @tools %{
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

  @missing %{
    "websearch" => "Troupe has no web search tool",
    "codesearch" => "Troupe has no code search tool",
    "lsp" => "Troupe has no language-server tool",
    "skill" => "a session's skills are offered to its agents as they are",
    "external_directory" =>
      "Troupe's tools stay inside the session's workspace whatever this says",
    "doom_loop" => "Troupe has no such prompt"
  }

  @read ~w(description mode model prompt tools permission steps maxSteps disable)

  @keys %{
    "temperature" => "Troupe sets no temperature per agent",
    "top_p" => "Troupe sets no sampling per agent",
    "hidden" => "Troupe has no menu of subagents to hide it from",
    "color" => "Troupe shows no colour per agent",
    "options" => "provider options are not set per agent",
    "variant" => "a model's variants are not read"
  }

  @command_keys %{
    "agent" => "a Troupe command runs on the session's agent (Decision 763)",
    "model" => "a Troupe command runs on the session's agent and its model (Decision 763)",
    "subtask" => "a Troupe command's prompt goes into the session's own conversation"
  }

  # Below Claude Code's files (rank 0), in the order a name is won: a markdown agent over
  # an entry, `agents/` over `agent/` and `opencode.json` over `opencode.jsonc`, as
  # opencode reads the second of each over the first.
  @agent_dirs [{".opencode/agents", 1}, {".opencode/agent", 2}]
  @config_files [{"opencode.jsonc", 4}, {"opencode.json", 3}]
  @command_dirs [{".opencode/commands", 1}, {".opencode/command", 2}]

  @doc """
  opencode's agents in `root`, as Troupe's, with what was not proposed. `below` holds the
  agents an entry without a prompt may adjust: Troupe's built-ins.
  """
  @spec agents(Path.t(), %{optional(String.t()) => Definition.t()}) ::
          {[Shared.agent()], [Shared.skip()]}
  def agents(root, below) do
    files = Enum.map(@config_files, &config_file(root, &1))

    # Each file's own `tools` and `permission`, under every agent's, and the file they
    # come from, which a proposal they shaped also comes from.
    shared =
      for %{config: config} = file when is_map(config) <- files,
          do: %{
            tools: config["tools"],
            permission: config["permission"],
            from: %{source: file.name, source_hash: Shared.hash(file.bytes)}
          }

    entries =
      for %{config: %{"agent" => agents}} = file when is_map(agents) <- files,
          {name, entry} <- Enum.sort(agents),
          do: entry(root, file, name, entry, shared, below)

    {markdown, markdown_skipped} =
      @agent_dirs
      |> Enum.map(fn {dir, rank} ->
        Shared.each_markdown(root, dir, &markdown_agent(root, &1, rank, shared, below))
      end)
      |> Enum.unzip()

    file_skips = for %{skip: skip} when is_map(skip) <- files, do: skip

    {List.flatten(markdown) ++ for({:ok, agent} <- entries, do: agent),
     file_skips ++ List.flatten(markdown_skipped) ++ for({:skip, skip} <- entries, do: skip)}
  end

  @doc "opencode's markdown commands in `root`, as Troupe's, with what was not proposed."
  @spec commands(Path.t()) :: {[Shared.command()], [Shared.skip()]}
  def commands(root) do
    {commands, skipped} =
      @command_dirs
      |> Enum.map(fn {dir, rank} ->
        Shared.each_markdown(
          root,
          dir,
          &Shared.command(root, &1, rank, @command_keys, "it is not a key a Troupe command reads")
        )
      end)
      |> Enum.unzip()

    {List.flatten(commands), List.flatten(skipped)}
  end

  defp config_file(root, {name, rank}) do
    path = Path.join(root, name)
    file = %{name: name, path: path, rank: rank, config: nil, bytes: nil, skip: nil}

    with true <- File.regular?(path),
         {:ok, bytes} <- Shared.read(root, path),
         {:ok, config} when is_map(config) <- JSONC.decode(bytes) do
      %{file | config: config, bytes: bytes}
    else
      false -> file
      {:skip, reason} -> %{file | skip: Shared.skip(name, nil, reason)}
      _not_an_object -> %{file | skip: Shared.skip(name, nil, "not read: not a JSON object")}
    end
  end

  defp entry(root, file, name, entry, shared, below) when is_map(entry) do
    source = %{
      source: file.name,
      source_hash: Shared.hash(file.bytes),
      label: "#{file.name}'s agent #{name}",
      rank: file.rank,
      dir: Path.dirname(file.path)
    }

    agent(root, source, name, entry, entry["prompt"], shared, below)
  end

  defp entry(_root, file, name, _entry, _shared, _below),
    do: {:skip, Shared.skip(file.name, name, "not proposed: its entry is not an object")}

  defp markdown_agent(root, path, rank, shared, below) do
    source = Shared.relative(root, path)

    case Shared.read(root, path) do
      {:ok, bytes} ->
        {meta, body, read_notes} = Shared.frontmatter(bytes)
        prompt = if String.trim(body) == "", do: meta["prompt"], else: body

        origin = %{
          source: source,
          source_hash: Shared.hash(bytes),
          label: source,
          rank: rank,
          dir: Path.dirname(path)
        }

        case agent(root, origin, Path.basename(path, ".md"), meta, prompt, shared, below) do
          {:ok, agent} -> {:ok, %{agent | notes: read_notes ++ agent.notes}}
          skip -> skip
        end

      {:skip, reason} ->
        {:skip, Shared.skip(source, nil, reason)}
    end
  end

  defp agent(root, origin, name, entry, prompt, shared, below) do
    with :ok <- enabled(entry),
         {:ok, name, name_notes} <- Shared.name(name, nil),
         {:ok, prompt, prompt_notes, prompt_files} <- prompt(root, origin.dir, prompt) do
      {mode, mode_notes} = mode(entry["mode"])
      {model, model_notes} = Shared.model(entry["model"], :opencode)
      {max_turns, turn_notes} = Shared.max_turns("steps", entry["steps"] || entry["maxSteps"])
      {access, access_notes} = access(shared, entry)

      fields = %{
        name: name,
        description: Shared.text(entry["description"]),
        mode: mode,
        mode_given?: Map.has_key?(entry, "mode"),
        model: model,
        max_turns: max_turns
      }

      {definition, base_notes} = definition(below[name], prompt, fields, access)
      layers = for %{from: from} = layer <- shared, layer.tools || layer.permission, do: from

      {:ok,
       Map.merge(Map.delete(origin, :dir), %{
         definition: definition,
         also_from: layers ++ prompt_files,
         notes:
           name_notes ++
             base_notes ++
             prompt_notes ++
             mode_notes ++
             model_notes ++
             turn_notes ++
             access_notes ++
             Shared.other_keys(entry, @read, @keys, "it is not a key a Troupe agent reads")
       })}
    else
      {:skip, reason} -> {:skip, Shared.skip(origin.source, name, reason)}
      {:skip, name, reason} -> {:skip, Shared.skip(origin.source, name, reason)}
    end
  end

  defp enabled(%{"disable" => true}), do: {:skip, "not proposed: disable is true"}
  defp enabled(_entry), do: :ok

  # An entry with a prompt is an agent of its own, every tool open but what its
  # permissions close. One without a prompt that names a built-in adjusts it: that
  # agent, with the entry's settings over it. One that names nothing has no prompt but
  # the instruction files.
  defp definition(nil, prompt, fields, access) do
    notes =
      if is_nil(prompt),
        do: [
          "The prompt is not given: opencode would use its own, and here the agent has the instruction files alone."
        ],
        else: []

    mode_notes =
      if is_nil(fields.mode) and not fields.mode_given?,
        do: [
          "The mode is not given, which opencode reads as all, both a primary and a subagent; a Troupe agent " <>
            "is one or the other, so it is primary, the one a person can pick: write subagent for other agents to delegate to it."
        ],
        else: []

    {%Definition{
       name: fields.name,
       prompt: prompt || "",
       description: fields.description || "",
       mode: fields.mode || :primary,
       model: fields.model,
       tools: tools_for(:all, access),
       permissions: access.permissions,
       max_turns: fields.max_turns,
       source: :project
     }, notes ++ mode_notes}
  end

  defp definition(%Definition{} = base, nil, fields, access) do
    kept =
      "The prompt is not given, so it is that of Troupe's built-in #{base.name} agent as it is now: " <>
        "a later change to the built-in does not reach this file."

    {%{
       base
       | description: fields.description || base.description,
         mode: fields.mode || base.mode,
         model: fields.model || base.model,
         tools: tools_for(base.tools, access),
         permissions: Map.merge(base.permissions, access.permissions),
         max_turns: fields.max_turns || base.max_turns,
         source: :project
     }, [kept]}
  end

  defp definition(%Definition{}, prompt, fields, access),
    do: definition(nil, prompt, fields, access)

  # The files' `tools` switches and `permission`, then the agent's, as opencode merges
  # them. Each key comes to `allow`, `ask`, `deny`, `:on` (a tool switched on, whose
  # approval stays Troupe's own: only `permission` says allow) or a map of rules for some
  # of its uses. `*` is every tool.
  defp access(shared, entry) do
    actions =
      (shared ++ [%{tools: entry["tools"], permission: entry["permission"]}])
      |> Enum.reduce(%{}, fn layer, acc ->
        acc |> Map.merge(switches(layer.tools)) |> Map.merge(rules(layer.permission))
      end)

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
            {access, notes ++ ["#{key} in permission is left out: #{reason}."]}
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
            {Map.update!(permissions, name, &Shared.stricter(&1, permission)), set}

          true ->
            {Map.put(permissions, name, permission), MapSet.put(set, name)}
        end
      end)

    open = if permission == :deny, do: access.open, else: Enum.uniq(access.open ++ names)
    %{access | permissions: permissions, set: set, open: open}
  end

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
      Map.has_key?(@tools, key) ->
        {:ok, @tools[key]}

      Map.has_key?(@missing, key) ->
        {:left_out, @missing[key]}

      String.contains?(key, "*") ->
        {:left_out, "Troupe's tools are named one by one, not by a pattern"}

      true ->
        {:left_out, "it is not a tool Troupe has"}
    end
  end

  defp action("allow"), do: :auto
  defp action("ask"), do: :ask
  defp action("deny"), do: :deny
  defp action(_other), do: nil

  defp permission(_key, :on), do: {nil, nil}
  defp permission(_key, nil), do: {nil, nil}
  defp permission(_key, action) when action in ["allow", "ask", "deny"], do: {action(action), nil}

  # Rules for some uses of a tool (`"git *": "allow"`) come to what `Shared.resolve/1`
  # says of the whole tool. Rules that allow only some uses say nothing, and the tool goes
  # back to Troupe's own approval.
  defp permission(key, rules) when is_map(rules) do
    patterns = rules |> Map.keys() |> Enum.reject(&(&1 == "*")) |> Enum.sort()

    if patterns == [] do
      permission(key, rules["*"])
    else
      resolved =
        Shared.resolve(
          for {pattern, value} <- rules, action = action(value), do: {action, pattern == "*"}
        )

      {resolved || :default,
       "#{key} in permission: the rules for #{Enum.join(patterns, ", ")} cannot be carried as written, " <>
         "as Troupe allows a tool whole or not at all, so #{consequence(resolved)}."}
    end
  end

  defp permission(key, other),
    do: {nil, "#{key} in permission is left out: #{inspect(other)} is not allow, ask or deny."}

  defp consequence(:deny), do: "it is denied whole, as its * says"
  defp consequence(:ask), do: "it asks every time"
  defp consequence(:auto), do: "it runs without asking, which every rule allowed"
  defp consequence(nil), do: "it keeps Troupe's own approval"

  defp wildcard(nil), do: {nil, []}
  defp wildcard(action) when action in ["allow", "ask", "deny"], do: {action, []}
  defp wildcard(:on), do: {nil, []}
  defp wildcard(other), do: {nil, [elem(permission("*", other), 1)] |> Enum.reject(&is_nil/1)}

  # `*: ask` and `*: allow` are every tool's approval where no key says otherwise; `*:
  # deny` closes every tool no key opens.
  defp wildcard_permissions(action) when action in ["allow", "ask"],
    do: @tools |> Map.values() |> List.flatten() |> Map.new(&{&1, action(action)})

  defp wildcard_permissions(_action), do: %{}

  defp tools_for(_tools, %{wildcard: "deny", open: open}), do: Shared.list_for(open)
  defp tools_for(:all, _access), do: :all
  defp tools_for(tools, %{open: open}), do: Shared.list_for(tools ++ open)

  defp mode(nil), do: {nil, []}
  defp mode("primary"), do: {:primary, []}
  defp mode("subagent"), do: {:subagent, []}

  defp mode("all"),
    do:
      {:primary,
       [
         "The mode all, both a primary and a subagent in opencode, is primary here: a Troupe agent is one " <>
           "or the other, and a primary is the one a person can pick; write subagent for other agents to delegate to it."
       ]}

  defp mode(other),
    do:
      {:primary,
       [
         "The mode #{inspect(other)} is not primary, subagent or all, so it is all, opencode's default, " <>
           "which is primary here: a Troupe agent is one or the other."
       ]}

  # The prompt as written, or with each `{file:path}` replaced by that file's text, read
  # from the config's directory and only from inside the workspace; each such file is one
  # the proposal also comes from.
  defp prompt(_root, _dir, nil), do: {:ok, nil, [], []}

  defp prompt(root, dir, prompt) when is_binary(prompt) do
    references = Regex.scan(~r/\{file:([^}]+)\}/, prompt)

    references
    |> Enum.reduce_while({:ok, prompt, []}, fn [reference, path], {:ok, prompt, files} ->
      full = path |> String.trim() |> Path.expand(dir)

      case prompt_file(root, full, reference) do
        {:ok, text, file} ->
          {:cont, {:ok, String.replace(prompt, reference, text), files ++ [file]}}

        skip ->
          {:halt, skip}
      end
    end)
    |> then(fn
      {:ok, text, files} ->
        notes =
          Enum.map(
            references,
            fn [reference, _path] ->
              "The prompt's #{reference} is that file's text as it is now: a Troupe agent's prompt is its file's body."
            end
          )

        {:ok, nilify(String.trim(text)), notes, files}

      skip ->
        skip
    end)
  end

  defp prompt(_root, _dir, _other), do: {:skip, "not proposed: its prompt is not text"}

  defp nilify(""), do: nil
  defp nilify(text), do: text

  defp prompt_file(root, full, reference) do
    cond do
      not Shared.inside?(full, root) ->
        {:skip, "not proposed: its prompt reads #{reference}, which is outside the workspace"}

      not File.regular?(full) ->
        {:skip,
         "not proposed: its prompt reads #{reference}, and #{Shared.relative(root, full)} is not there"}

      true ->
        case File.read(full) do
          {:ok, bytes} ->
            {:ok, String.trim(bytes),
             %{source: Shared.relative(root, full), source_hash: Shared.hash(bytes)}}

          {:error, reason} ->
            {:skip, "not proposed: its prompt reads #{reference}: #{:file.format_error(reason)}"}
        end
    end
  end
end
