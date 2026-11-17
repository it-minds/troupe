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
symbols:
  - Troupe.Onboard.AgentsAndCommands.proposals/2
  - Troupe.Onboard.AgentsAndCommands.survey/2
  - Troupe.Agent.Definition.render/1
gist: "Other tools' agents/commands become .troupe/ proposals, not runtime reads; per-use rules never widen; aliases left out; every loss is a note"
---

`Troupe.Onboard.AgentsAndCommands` reads the other tools' files and answers proposals in
the shape `Troupe.Onboard.Source` fixes for `troupe onboard` (Decision 823): `%{target:
:repo, path:, content:, source:, source_hash:, also_from:, notes:}`, and `skipped/2`
answers what gave no proposal. It writes nothing.

- **What is read.** A file is read only where it really is inside the workspace, links
  followed (Decision 798).
- **What is proposed.** An agent becomes `agents/<name>.md`, the text
  `Troupe.Agent.Definition.render/1` writes: the frontmatter keys whose values say
  something, in the built-ins' order, bare where YAML reads the value back as itself, then
  the prompt. A command becomes `commands/<name>.md` with `description` and
  `argument-hint`, the only keys `Troupe.Commands.Local` reads (Decision 763), then the
  body.
- **Tools.** A list keeps `finish` and, beside `shell` or `grep`, `read_output`, what the
  harness needs to honour it (Decision 650).
- **Permissions.** `allow` is `auto`, `ask` `ask`, `deny` `deny`, the stricter of two over
  one tool winning.
- **A rule for some uses is never widened.** Troupe allows a tool whole or not at all
  (#516's out-of-scope list), so `Bash(git log:*)` or `bash: {"git *": "allow"}` cannot be
  carried. What a tool's rules come to (`Shared.resolve/1`): a rule for all of it that
  denies or asks stands; a rule that denies or asks some of its uses makes the whole tool
  ask; an allow for all of it stands after those; an allow for only some uses says
  nothing, and the tool keeps Troupe's own approval. So nothing the other tool asked about
  or refused runs without asking, and nothing it allowed is refused. Not chosen: #510's
  answers for the same rules, which dropped a tool that `tools` granted for some uses,
  denied the whole of a tool `disallowedTools` named for some uses (Claude Code keeps the
  tool there), and put a tool whose `*` allowed and whose patterns denied back to Troupe's
  own approval, which is `auto` for `read_file`.
- **Models.** An import cannot ask a live session's model catalog which model an alias is.
  So a model is written as it is unless it is one of Claude Code's aliases, `sonnet`,
  `opus`, `haiku`, `inherit`, `default`, `fable`, `opusplan` (with `[1m]` or not), which
  is left out with a note, and the agent runs on the session's model. Not chosen: mapping
  `haiku` to the `cheap` model and `opus` to `expensive`, which guesses at what the author
  meant.
- **Modes.** opencode's `all`, its default when `mode` is absent, is both a primary and a
  subagent; a Troupe agent is one or the other (#510's `mode: :all` never reached `main`),
  and it is `primary`, the one a person picks, rather than one any agent may delegate to
  without anyone choosing it.
- **Commands.** `allowed-tools` is refused (#516's table: it grants tools without asking,
  #511's hazard); `model`, `agent`, `context`, `subtask` and the rest are left out, a
  Troupe command being a prompt sent into the session on its agent (Decision 763).
