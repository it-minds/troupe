defmodule Troupe.Onboard.AgentsAndCommands do
  @moduledoc """
  The agents and commands other tools wrote into a repository, as proposals for Troupe's
  own files (Decision 824; issue #516, slice 4): Claude Code's `.claude/agents/*.md`, with
  the permission rules of its `.claude/settings.json`, and `.claude/commands/*.md`;
  opencode's `agent` entries in `opencode.json` and `opencode.jsonc`, its
  `.opencode/agents/` and `.opencode/commands/` (and the singular `agent/` and
  `command/`). Each becomes a proposal for `.troupe/agents/<name>.md` or
  `.troupe/commands/<name>.md`, read once by `troupe onboard` rather than by every
  session (#516).

  A source for onboarding in the shape `Troupe.Onboard.Source` fixes: `proposals/2`
  answers plain maps, `%{target: :repo, path:, content:, source:, source_hash:, notes:}`,
  `path` under `.troupe/`, `source` the other tool's file relative to the workspace,
  `source_hash` the sha256 of its bytes, and `notes` one sentence per key left out or
  changed, with why. Nothing here writes. The same files give the same proposals, byte
  for byte: nothing in one depends on the clock or on what `.troupe/` already holds.

  How each tool's keys map is in `ClaudeCode` and `OpenCode`. Two files that give one
  name: Claude Code's wins over opencode's, a markdown agent over an `opencode.json`
  entry; the proposal says which it hid, and `survey/2` lists the hidden one with what
  else was not proposed and why. A command is not proposed under a name a built-in
  command, an alias or a primary agent has, since Troupe skips such a file (Decision 763).
  """

  alias Troupe.Agent.{Definition, Definitions}
  alias Troupe.Config.Yaml
  alias Troupe.Onboard.AgentsAndCommands.{ClaudeCode, OpenCode, Shared}

  @typedoc "One file onboarding may write, and what it came from."
  @type proposal :: %{
          target: :repo | :user,
          path: String.t(),
          content: binary(),
          source: String.t(),
          source_hash: String.t(),
          notes: [String.t()]
        }

  @typedoc "The proposals, and every file or entry that gave none, with why."
  @type survey :: %{proposals: [proposal()], skipped: [Shared.skip()]}

  @doc """
  The proposals for the agents and commands Claude Code and opencode wrote into
  `workspace`, sorted by path. `below:` replaces Troupe's built-in agents, which an
  opencode entry without a prompt adjusts and a proposal of the same name replaces.
  """
  @spec proposals(Path.t(), keyword()) :: [proposal()]
  def proposals(workspace, opts \\ []), do: survey(workspace, opts).proposals

  @doc "`proposals/2`, with every file or entry that gave none and why, in words."
  @spec survey(Path.t(), keyword()) :: survey()
  def survey(workspace, opts \\ []) do
    root = Path.expand(workspace)
    below = Keyword.get_lazy(opts, :below, &builtins/0)

    {claude_agents, claude_agent_skips} = ClaudeCode.agents(root)
    {opencode_agents, opencode_agent_skips} = OpenCode.agents(root, below)
    {claude_commands, claude_command_skips} = ClaudeCode.commands(root)
    {opencode_commands, opencode_command_skips} = OpenCode.commands(root)

    {agents, hidden_agents} =
      winners(claude_agents ++ opencode_agents, & &1.definition.name, "agent")

    {commands, hidden_commands} =
      winners(claude_commands ++ opencode_commands, & &1.name, "command")

    taken = taken(below, agents)
    {commands, shadowed} = Enum.split_with(commands, &(not Map.has_key?(taken, &1.name)))

    shadowed =
      Enum.map(
        shadowed,
        &Shared.skip(
          &1.source,
          &1.name,
          "not proposed: /#{&1.name} is #{taken[&1.name]}, and a command does not take the name of a " <>
            "built-in, an alias or a primary agent (Decision 763)"
        )
      )

    proposals =
      Enum.map(agents, &agent_proposal(&1, below)) ++ Enum.map(commands, &command_proposal/1)

    skipped =
      claude_agent_skips ++
        opencode_agent_skips ++
        claude_command_skips ++
        opencode_command_skips ++ hidden_agents ++ hidden_commands ++ shadowed

    %{
      proposals: Enum.sort_by(proposals, & &1.path),
      skipped: Enum.sort_by(skipped, &{&1.source, &1.name || "", &1.reason})
    }
  end

  # Of the files that give one name, the first by rank (Claude Code's, then opencode's
  # markdown, then its config) and then by where it is; its proposal names the others.
  defp winners(items, name_of, kind) do
    items
    |> Enum.group_by(name_of)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_reduce([], fn {name, group}, hidden ->
      [winner | losers] = Enum.sort_by(group, &{&1.rank, &1.label})

      notes =
        Enum.map(
          losers,
          &"#{&1.label} also gives the #{kind} #{name} and is not proposed: #{winner.label} comes first (Decision 824)."
        )

      skips =
        Enum.map(
          losers,
          &Shared.skip(
            &1.source,
            name,
            "not proposed: #{winner.label} gives the #{kind} #{name} too, and comes first"
          )
        )

      {%{winner | notes: winner.notes ++ notes}, hidden ++ skips}
    end)
  end

  # The names a command file cannot have, with whose they are: a built-in command's or
  # alias's, and a primary agent's once these proposals are taken.
  defp taken(below, agents) do
    commands =
      for entry <- Troupe.Commands.builtins(),
          name <- [entry["name"] | entry["aliases"]],
          into: %{},
          do: {name, "Troupe's own /#{entry["name"]} command"}

    effective = Map.merge(below, Map.new(agents, &{&1.definition.name, &1}))

    primaries =
      for {name, holder} <- effective, primary?(holder), into: %{}, do: {name, whose(holder)}

    Map.merge(commands, primaries)
  end

  defp primary?(%Definition{mode: mode}), do: mode == :primary
  defp primary?(%{definition: %Definition{mode: mode}}), do: mode == :primary

  defp whose(%Definition{name: name}), do: "Troupe's built-in #{name} agent"

  defp whose(%{definition: %Definition{name: name}, source: source}),
    do: "the #{name} agent proposed from #{source}"

  defp agent_proposal(agent, below) do
    name = agent.definition.name

    replaces =
      if Map.has_key?(below, name),
        do: [
          "The name #{name} is that of Troupe's built-in #{name} agent, which this file replaces in this workspace."
        ],
        else: []

    %{
      target: :repo,
      path: "agents/#{name}.md",
      content: Definition.render(agent.definition),
      source: agent.source,
      source_hash: agent.source_hash,
      notes: replaces ++ agent.notes
    }
  end

  defp command_proposal(command) do
    %{
      target: :repo,
      path: "commands/#{command.name}.md",
      content: command_file(command),
      source: command.source,
      source_hash: command.source_hash,
      notes: command.notes
    }
  end

  # What `Troupe.Commands.Local` reads: `description` and `argument-hint`, when there are
  # any, then the body.
  defp command_file(command) do
    meta =
      for {key, value} <- [{"description", command.description}, {"argument-hint", command.hint}],
          value != nil,
          do: Yaml.encode(%{key => value})

    front = if meta == [], do: "", else: IO.iodata_to_binary(["---\n", meta, "---\n\n"])
    front <> command.body <> "\n"
  end

  # Troupe's built-in agents alone: what a repository's files replace, and never the
  # person's own `<config>/agents/`, which onboarding does not copy into a repository.
  defp builtins do
    dir = Definitions.builtin_dir()

    case File.ls(dir) do
      {:ok, entries} ->
        for entry <- entries,
            String.ends_with?(entry, ".md"),
            name = Path.basename(entry, ".md"),
            {:ok, definition} <- [
              Definition.parse(name, File.read!(Path.join(dir, entry)), :builtin)
            ],
            into: %{},
            do: {name, definition}

      {:error, _reason} ->
        %{}
    end
  end
end
