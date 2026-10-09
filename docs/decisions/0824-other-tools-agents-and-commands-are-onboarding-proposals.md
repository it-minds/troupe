---
number: 824
title: "Claude Code's and opencode's agents and commands are read once, as proposals for `.troupe/agents/` and `.troupe/commands/` files that Troupe's own loaders read back, with every key left out or changed said in the proposal's notes, rules for some uses never widened, and a model written only when it is not an alias"
date: 2026-10-09
status: accepted
issue: 516
paths:
  - apps/troupe_core/lib/troupe/onboard/agents_and_commands.ex
  - apps/troupe_core/lib/troupe/onboard/agents_and_commands/*.ex
  - apps/troupe_core/lib/troupe/agent/definition.ex
  - apps/troupe_core/test/troupe/onboard/agents_and_commands_test.exs
  - apps/troupe_core/test/troupe/agent/definition_test.exs
symbols:
  - Troupe.Onboard.AgentsAndCommands.proposals/2
  - Troupe.Onboard.AgentsAndCommands.survey/2
  - Troupe.Agent.Definition.render/1
gist: "Other tools' agents/commands become .troupe/ proposals, not runtime reads; per-use rules never widen; aliases left out; every loss is a note"
---

Issue #516's slice 4. #516 decided that other tools' configuration stops being read at
runtime and is onboarded once into Troupe's own files. The closed pull request #510 read
Claude Code's subagents and opencode's agents at every session start (its Decision 819,
which never reached `main`); this re-books its mapping as an importer.
`Troupe.Onboard.AgentsAndCommands` reads the other tools' files and answers proposals in the
shape `Troupe.Onboard.Source` fixes for `troupe onboard` (Decision 823):
`%{target: :repo, path:, content:, source:, source_hash:, notes:}`. It writes nothing.

- **What is read.** Claude Code: `.claude/agents/*.md`, the `permissions` of the shared
  `.claude/settings.json` (not `.claude/settings.local.json`, which is the person's), and
  `.claude/commands/*.md`. opencode: the `agent` entries of `opencode.json` and
  `opencode.jsonc`, with each file's `permission` and `tools` under every agent's as
  opencode merges them; markdown agents in `.opencode/agents/` and `.opencode/agent/`, and
  markdown commands in `.opencode/commands/` and `.opencode/command/`, since opencode's own
  documentation uses both spellings. Only the files directly in a directory: a subdirectory
  is listed as skipped, Troupe's agents and commands being the files of one directory. A file
  is read only where it really is inside the workspace, links followed (Decision 798).
- **What is proposed.** An agent becomes `agents/<name>.md`, the text
  `Troupe.Agent.Definition.render/1` writes: the frontmatter keys whose values say
  something, in the built-ins' order, bare where YAML reads the value back as itself, then
  the prompt. `Definition.parse/3` reads it back to the same definition; a test holds that
  for every built-in and for awkward values (a colon in a description, a tool named `on`, a
  `---` line in the prompt). A command becomes `commands/<name>.md` with `description` and
  `argument-hint`, the only keys `Troupe.Commands.Local` reads (Decision 763), then the body.
  `source` is the other tool's file relative to the workspace, forward slashes, and
  `source_hash` the sha256 of its bytes; an `opencode.json` entry's is the whole file's.
- **Tools.** #516's table, with #510's names: `Read` `read_file`, `Write` `write_file`,
  `Edit` and `MultiEdit` `edit_file`, `Bash` and `PowerShell` `shell`, `Grep`, `Glob`, `LS`
  `list_files`, `WebFetch`, `TodoWrite` `todo_write` and `todo_read`, `Agent` and `Task`
  `delegate`, `AskUserQuestion` `ask_user`, `mcp__s__t` `mcp.s.t`; opencode's `read`, `edit`
  (over `edit_file` and `write_file`), `write`, `glob`, `grep`, `list`, `bash`, `task`,
  `todowrite`, `webfetch`, `question`. A list keeps `finish` and, beside `shell` or `grep`,
  `read_output`, what the harness needs to honour it (Decision 650). Left out with the
  reason: `WebSearch`, `NotebookEdit`, `LSP`, `Skill`, opencode's `websearch`, `codesearch`,
  `lsp`, `skill`, `external_directory`, `doom_loop`, a whole MCP server or a pattern, and
  anything unknown. A Claude Code subagent whose list names nothing Troupe has is not
  proposed, as Claude Code would not start it.
- **Permissions.** `allow` is `auto`, `ask` `ask`, `deny` `deny`, the stricter of two over
  one tool winning. Whether an `auto` written into `.troupe/agents/` applies in an untrusted
  workspace is Decision 825's runtime rule (#511), not the importer's. `.claude/settings.json`
  has no workspace-wide counterpart in Troupe, whose approvals are per agent, so its rules go
  with each Claude Code subagent, for the tools that agent has; with no subagent they go
  nowhere. In a rule `Edit` covers `write_file` too, as Claude Code's `Edit(path)` governs
  every tool that writes. `defaultMode`, `additionalDirectories` and `permissionMode` are left
  out: a mode for all approvals has no counterpart here.
- **A rule for some uses is never widened.** Troupe allows a tool whole or not at all
  (#516's out-of-scope list), so `Bash(git log:*)` or `bash: {"git *": "allow"}` cannot be
  carried. What a tool's rules come to (`Shared.resolve/1`): a rule for all of it that
  denies or asks stands; a rule that denies or asks some of its uses makes the whole tool
  ask; an allow for all of it stands after those; an allow for only some uses says nothing,
  and the tool keeps Troupe's own approval. So nothing the other tool asked about or refused
  runs without asking, and nothing it allowed is refused. In a Claude Code subagent's
  `tools` a rule for some uses offers the whole tool, asking every time. Not chosen: #510's
  answers for the same rules, which dropped a tool that `tools` granted for some uses, denied
  the whole of a tool `disallowedTools` named for some uses (Claude Code keeps the tool
  there), and put a tool whose `*` allowed and whose patterns denied back to Troupe's own
  approval, which is `auto` for `read_file`. Every such rule is a note.
- **Models.** An import cannot ask a live session's model catalog which model an alias is
  (#510 kept a model only when `Troupe.LLM.Catalog.Store.served/3` said the session's
  provider served it). So a model is written as it is unless it is one of Claude Code's
  aliases, `sonnet`, `opus`, `haiku`, `inherit`, `default`, `fable`, `opusplan` (with `[1m]`
  or not), which is left out with a note, and the agent runs on the session's model.
  opencode's `provider/model` is written as it is; it reaches the provider of that name when
  `config.yaml` has one (`Troupe.Config.split_model/2`), else the session's provider is sent
  the whole string, which a person reading the proposal can change. Not chosen: mapping
  `haiku` to the `cheap` model and `opus` to `expensive`, which guesses at what the author
  meant.
- **Modes.** A Claude Code subagent is a subagent. opencode's `all`, its default when `mode`
  is absent, is both a primary and a subagent; a Troupe agent is one or the other (#510's
  `mode: :all` never reached `main`), and it is `primary`, the one a person picks, rather
  than one any agent may delegate to without anyone choosing it. The note says so and how to
  change it.
- **Prompts.** Claude Code's body. opencode's `prompt`, a `{file:path}` in it replaced by that
  file's text as it is now (inside the workspace only; one outside or missing keeps the agent
  out), which the note says, since a Troupe agent's prompt is its file's body. An opencode
  entry without a prompt that names one of Troupe's built-in agents adjusts it, as opencode
  adjusts its own `build`: the proposal is the built-in with the entry's settings over it,
  and the note says a later change to the built-in does not reach the file. The person's own
  `<config>/agents/` are never copied into a repository.
- **Commands.** `description` and `argument-hint` carry (`argument-hint: [message]`, a YAML
  list, is the text `[message]`). `allowed-tools` is refused (#516's table: it grants tools
  without asking, #511's hazard); `model`, `agent`, `context`, `subtask` and the rest are left
  out, a Troupe command being a prompt sent into the session on its agent (Decision 763). The
  body is kept as written: `$ARGUMENTS` already means the same; `$1`, `$ARGUMENTS[0]` and the
  like stay as written because Troupe fills `$ARGUMENTS` alone, and `` !`cmd` `` shell lines
  are not run, each said in a note. A command is not proposed under a name a built-in
  command, an alias or a primary agent has (Troupe would skip that file, Decision 763), nor
  with an empty body.
- **Names.** A name Troupe can give is kept; one that is not (`Code Reviewer`, `fix_issue`)
  is lower-cased with each run of other characters a dash, and the note says so; one that
  comes to nothing is not proposed. Two files that give one name: Claude Code's first, then
  `.opencode/agents/` (or `commands/`), `.opencode/agent/` (`command/`), `opencode.json`,
  `opencode.jsonc`, and by path within one place. The winner's proposal names each file it
  hid, and `survey/2` lists the hidden one. A proposal whose name is a built-in agent's says
  that it replaces the built-in in this workspace.
- **Notes and skips.** One sentence per key left out or changed, with why, in a fixed order,
  so the same files give the same proposals byte for byte: nothing depends on the clock or on
  what `.troupe/` holds, and a test writes the proposals into `.troupe/` and runs again. What
  gave no proposal at all (a file outside the workspace, `disable: true`, an unusable name, a
  shadowed command) cannot be a proposal's note; `survey/2` answers it beside the proposals,
  with the reason.
- **Proof:** `Troupe.Onboard.AgentsAndCommandsTest`: the fixture of #516's slice (three
  Claude Code subagents with `.claude/settings.json`, two opencode agents, one in
  `opencode.json` and one in `.opencode/agents/`, three Claude Code commands) gives five
  agent and three command proposals whose tools, permissions and models are the table's,
  every note asserted; again on the same files, before and after the proposals are written,
  the same; `Definitions.load/2` and `Commands.Local.list/2` read the written files back as
  proposed. Then rules for some uses in `tools`, `disallowedTools`, the settings and
  opencode's `permission`; names; a list of nothing Troupe has; frontmatter a line per key;
  `mode` absent and `all`; an entry adjusting `build` and `plan`; `{file:}` inside, outside
  and missing; markdown agents in both directories; collisions for agents and commands;
  commands under taken names, empty, in a subdirectory; links out of the workspace. On the
  chunk's tip the reproduction (a `.claude/agents/reviewer.md` to a proposal) failed: no
  importer existed. `Troupe.Agent.DefinitionTest`: `render/1` reads back for every built-in
  and for awkward values.
