---
number: 819
title: A workspace's Claude Code subagents and opencode agents are read as Troupe's agents at the workspace's layer, below its own .troupe/agents, each used as its tool says, and what Troupe cannot honour is mapped or left out with the reason in words
date: 2026-10-09
status: accepted
issue: 123
paths:
  - apps/troupe_core/lib/troupe/agent/imported.ex
  - apps/troupe_core/lib/troupe/agent/definitions.ex
  - apps/troupe_core/lib/troupe/agent/definition.ex
  - apps/troupe_core/lib/troupe/config/open_code.ex
  - apps/troupe_core/lib/troupe/commands.ex
  - apps/troupe_core/lib/troupe/tools/delegate.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_core/test/troupe/agent/imported_test.exs
  - apps/troupe_gateway/test/troupe/gateway/daemon_test.exs
  - apps/troupe_gateway/test/troupe/gateway/commands_list_test.exs
symbols:
  - Troupe.Agent.Imported.load/3
  - Troupe.Config.OpenCode.project/1
  - Troupe.Agent.Definitions.load/2
gist: ".claude/agents and opencode.json agents sit below .troupe/agents; inside the workspace only; unknown tools, aliases and keys left out with a reason"
---

Issue #123, its parity items 7 and 8 for agents and permissions. A repository that
already carries Claude Code subagents (`.claude/agents/*.md`) or opencode agents (the
`agent` block of its `opencode.json`) has told agents how to divide the work in it, and
Troupe read none of it: `agents.list` and the palette offered the built-ins and
`.troupe/agents/` alone, and `Troupe.Config.OpenCode` said in its moduledoc that it skips
`agent` and `permission`. `Troupe.Agent.Imported` now reads both.

- **The workspace's layer.** Lowest to highest: built-ins, a bundle, `<config>/agents/`,
  the agents other tools wrote into the workspace, `.troupe/agents/`. Troupe's own file of
  a name wins, as the issue asks, and the file it hid is listed in `skipped` with
  `skipped: .troupe/agents/reviewer.md is used`, so nobody edits a file that is never read.
  Between the two tools, a Claude Code file wins a name opencode's config also has: it is a
  whole agent in a file of its own, where an opencode entry is often a few settings on an
  agent of that name. Read in the workspace's root, as `.troupe/agents/` is: not the
  person's home `~/.claude/agents` nor opencode's global config (see below).
- **Used as each tool says.** A Claude Code subagent is a subagent: the model delegates to
  it, and no session is started on it. An opencode agent has its `mode`: `primary`,
  `subagent`, or `all` (its default, when `mode` is absent), which is both; a definition may
  now be `mode: :all`, which `Definitions.primaries/1` and `subagents/1` both list and
  `delegate` accepts. Troupe's own files do not gain `all` in this slice. A team's grant
  that does not name an `all` agent leaves it a subagent rather than dropping it.
- **Tools.** Claude Code's `tools` (a comma list or a YAML list) map to Troupe's: `Read`
  `read_file`, `Write` `write_file`, `Edit` and `MultiEdit` `edit_file`, `Bash` and
  `PowerShell` `shell`, `Grep` `grep`, `Glob` `glob`, `LS` `list_files`, `WebFetch`
  `web_fetch`, `TodoWrite` `todo_write` and `todo_read`, `Agent` and `Task` `delegate`,
  `AskUserQuestion` `ask_user`, `mcp__server__tool` `mcp.server.tool`. A list keeps
  `finish` (how a subagent reports) and, beside `shell` or `grep`, `read_output` (the rest
  of a cut result, Decision 650): what Troupe's harness needs to honour the same list.
  Absent is every tool, as Claude Code has it. Left out, each with its reason: a tool
  Troupe does not have (`WebSearch`, `NotebookEdit`, `LSP`, `Skill`, anything unknown), a
  rule for some uses of a tool (`Bash(git log:*)`), which Troupe cannot express because
  it allows a tool whole or not at all, so the tool is not granted at all rather than
  granted whole, and a whole MCP server by pattern (`mcp__wiki`). A file whose list names
  nothing Troupe has is not read, as Claude Code will not start such an agent either.
  `disallowedTools` denies the tools it names, a rule for some uses removing the whole
  tool, as Claude Code does.
- **Permissions.** opencode's `permission` values are Troupe's: `allow` `auto`, `ask`
  `ask`, `deny` `deny`; keys over Troupe's tools (`read`, `edit` over `edit_file` and
  `write_file`, `glob`, `grep`, `list`, `bash`, `task`, `todowrite`, `webfetch`,
  `question`). The file's own `permission` and `tools` apply under each agent's, as
  opencode merges them. `*` is every tool: `*: deny` makes the agent's tools a list of
  what its keys open. A tool's rules for some of its uses (`bash: {"git *": "allow"}`) are
  left out, the `*` among them kept where it asks or denies; where it allows, the rules
  beside it were what made the allow safe, so the tool keeps Troupe's own approval. The
  deprecated `tools` switches: `false` denies, `true` offers the tool at Troupe's own
  approval, since only `permission` says allow. Two keys over one tool give it the
  stricter. Keys Troupe has no tool for (`websearch`, `lsp`, `skill`,
  `external_directory`, `doom_loop`) are left out with their reason. Claude Code's
  `permissionMode` is not read: it is a mode for all of an agent's approvals, which has no
  counterpart here, where approvals are per tool. A repository's `allow` is read without
  the workspace being trusted, as `.troupe/agents/`'s `permissions: auto` already is;
  whether either should wait for the workspace to be trusted (Decision 686), as a
  workspace's MCP servers do and its commands ask (Decision 814), is open.
- **Models.** `inherit`, an absent `model`, and a model the session's provider is not known
  to serve are the session's model. A name is kept only when the provider it goes to is
  known to serve it, by the model cache (`Troupe.LLM.Catalog.Store.served/3`, Decision 799),
  so `claude-opus-5-5` on a session talking to Anthropic is kept, `sonnet` (Claude Code's
  name for a model it picks itself) or `anthropic/claude-sonnet-4-5` on a session whose
  provider has not listed it is not, and each says so. Not chosen: mapping `haiku` to the
  session's `cheap` model and `opus` to `expensive`, which guesses at what the author
  meant and names a model the person may not have set.
- **The rest of a file.** Claude Code: `name` (else the file's), `description`, the body as
  the prompt, `maxTurns` as `max_turns`; frontmatter YAML cannot read (a description with
  `: ` in it) is read a line per key and says so. opencode: `description`, `prompt` (with
  `{file:path}` read from the config's directory), `steps` (and `maxSteps`) as `max_turns`,
  `disable: true` not read. An opencode entry without a `prompt` that names an agent below
  the workspace's layer adjusts that agent, as opencode adjusts its own `build`: it keeps
  that agent's prompt and tools and takes the entry's settings over them, saying so; one
  that names nothing has the instruction files alone for a prompt. Every other key is
  left out with its reason (`temperature`, `hidden`, `color`, `skills`, `hooks`,
  `mcpServers`, `memory`, `effort`, `isolation`, anything unknown), and a name Troupe
  cannot give an agent (lower-case letters, digits and dashes) is not read.
- **Said in words, where a person looks.** Each definition carries `file` and `notes`
  (`%{key, reason}`); `agents.list` answers them on each agent, adds `mode`, the
  `subagents` an agent may delegate to beside the primaries, and `skipped`, every file or
  entry not read as an agent with its reason. Additive: `agents` keeps its meaning, the
  primaries a session may be created with, and `source` gains `claude_code` and `opencode`.
  The palette's row for an agent (`commands.list`) says in its detail which file it came
  from (`From opencode.json, an opencode agent.`), for `.troupe/agents/` and `<config>/agents/`
  too, and each note on a line of its own. No parameter changed, so the committed schema
  does not; the TUI prints a row's detail as it is.
- **The workspace's edge.** A file is read only where it really is inside the workspace,
  links followed (Decision 798): a `.claude/agents` that is a link out is listed once as
  `not read: outside the workspace` and not looked into, a file or an `opencode.json` that
  is a link out is listed the same way, and a prompt's `{file:...}` that resolves outside
  the workspace (`../`, `~/`) keeps the agent out, so a repository cannot put a file from
  elsewhere on the machine into a prompt that goes to a provider. `OpenCode.project/1` reads
  the workspace's `opencode.jsonc` and `opencode.json` with that edge, for any block a
  caller wants (its `mcp`, for #60).
- **Not in this slice.** The person's own layer: `~/.claude/agents/` and the `agent` block of
  opencode's global config should be read as the user's layer, below `<config>/agents/`,
  by the same reader; opencode's markdown agents (`.opencode/agents/*.md`); an
  `opencode.json` in a directory between the workspace and the repository root, which
  opencode reads too; Claude Code's `.claude/settings.json` permission rules; and a
  client view of `subagents` and `skipped` (the TUI's `/agents` prints names only).
- **Proof:** `Troupe.Agent.ImportedTest` (a `.claude/agents/reviewer.md` is a subagent of
  the workspace with its tools mapped, which failed on the chunk's tip with the built-in
  `reviewer` in its place; tools, a rule, MCP, `disallowedTools`, an alias, keys left out,
  each with its reason; a served model kept; names; a file whose tools Troupe has none of;
  frontmatter a line per key; an opencode primary with its permissions; `all`, and
  delegation to it; an entry adjusting `build` and `plan`; `{file:}` inside, outside and
  missing; switches and rules; Troupe's own file winning and Claude Code's over opencode's,
  each saying so; a grant leaving an `all` agent a subagent; links out not read; a session
  running an opencode primary with its prompt and only its tools; the root delegating to a
  Claude Code subagent that has only its tools; the palette's row),
  `Troupe.Gateway.DaemonTest` (`agents.list` over a socket: the opencode primary with its
  note, the Claude Code subagent under `subagents` with its note, a file left out with its
  reason) and `Troupe.Gateway.CommandsListTest` (an opencode agent's palette row), and the
  installed build on a scratch repository, on the pull request.
