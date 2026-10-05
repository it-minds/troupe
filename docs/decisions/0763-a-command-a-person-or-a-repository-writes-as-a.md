---
number: 763
title: "A command a person or a repository writes as a markdown file is a row of the command table, in a section of its own, and the harness runs it: the file's prompt, with what follows the name for `$ARGUMENTS`, goes to the session as input"
date: 2026-10-03
status: accepted
issue: 124
paths:
  - apps/troupe_core/lib/troupe/commands.ex
  - apps/troupe_core/lib/troupe/commands/local.ex
  - apps/troupe_core/test/troupe/commands_test.exs
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/test/troupe/gateway/commands_list_test.exs
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/gui/apps/desktop/src/views/CommandPalette.tsx
  - clients/gui/apps/desktop/test/command-palette.test.tsx
  - clients/gui/packages/client/test/support/daemon.ts
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/test/troupe/command_palette_test.exs
gist: "A command a person or a repository writes as a markdown file is a row of the command table, in a section of its own, and the harness runs it: the…"
---

Issue
#124, its third done-when item, left by 698. A prompt somebody types every day had
nowhere to live, and a team had no way to hand its repository's prompts to whoever
opens it.
- **Files.** `<config>/commands/<name>.md` (the user's) and
  `<workspace>/.troupe/commands/<name>.md` (the repository's), the shape other tools'
  command files have: optional frontmatter, then the body. The file name is the
  command; a name is what an agent's may be, lower-case letters, digits and dashes.
  `description` is the summary (the body's first line without one) and
  `argument-hint` what the usage line says follows the name; other keys are left
  alone. The workspace's file wins over the user's of the same name, as the skills'
  layers resolve (700). `Troupe.Commands.Local` reads them; a file that cannot be
  read, whose frontmatter is not YAML or whose body is empty is skipped with a
  warning.
- **In the table.** The `custom` section, between `agents` and `quit`, with `source`
  `user` or `project` and a `detail` that names the file, so a person knows where to
  change it. The files are read whenever `commands.list` is asked, so one written a
  moment ago is listed. A pod reads its own config directory and workspace, as it
  reads `.troupe/agents/` there.
- **A built-in's name stays the built-in's**, and so do an alias's and an agent's:
  such a file is skipped, with a warning in the daemon's log. A built-in is code in
  each client that a person's fingers know, and a repository's file arrives with a
  clone; letting `merge.md` turn `/merge` into a prompt would change what a known
  command does without anyone being told. A name is one row, so a client finds a
  command by name and nothing has to choose between two.
- **The harness runs it** (`commands.run`, `control`): it finds the name among the
  session's defined commands, replaces every `$ARGUMENTS` with what was typed after
  it, trimmed — or adds that as a paragraph of its own where the body has no
  placeholder, so nothing typed is dropped — and sends the result as `input.send`
  would, under the same `command_id` and actor. A client keeps no copy of the
  expansion, so the terminal and the desktop app cannot disagree on what a command
  sends, and `$1` or `@file` later are one change. Anything else is `not_found` with
  `kind: "command"`.
- **No trust needed.** A command is a prompt sent only when somebody types it, and
  does nothing the same words typed by hand would not: the turn goes through the
  session's approvals as any other. So a workspace's commands are read whether or not
  the workspace is trusted (686), as its `.troupe/agents/` and `AGENTS.md` are.
  Frontmatter that changed what may run without asking — a tool list, a model on
  another endpoint, an approval setting — would be a trusted key and is not read.
- **Not in this slice:** `agent` and `model` in the frontmatter (a command on another
  agent is a branch, which only the terminal client has), `$1` and `@file`, a
  bundle's commands for every session of a team, and the terminal client reading the
  table again while a session is open (it reads it when the session opens). Also
  still owed to #124: `troupe --help` and the docs' command reference generated from
  the table.
- **Proof:** `Troupe.CommandsTest` (a workspace's `review.md` listed with its fields
  in its section, which failed on the tip; a file without frontmatter; the
  workspace's over the user's; built-in, alias and agent names and bad names
  skipped; the expansion), `Troupe.Gateway.CommandsListTest` over a socket (listed,
  `commands.run` sending the prompt as a `user_input` with the `command_id`, and
  refusing a built-in, an agent, an unknown name and non-text arguments),
  `Troupe.Worker.AuthTest` (a session's token may run its commands), the TUI's
  `Troupe.CommandPaletteTest` (listed under Custom with its description, run from
  the line with an argument) and the desktop app's `command-palette.test.tsx` (the
  row in its section, Enter calling `commands.run` and the prompt in the
  transcript).
