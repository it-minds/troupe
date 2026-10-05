---
number: 767
title: "`troupe --help` and the command reference are written from two tables, the command lines beside `troupe`'s parser and the harness's slash commands, and the TUI's suite fails when either drifts"
date: 2026-10-04
status: accepted
issue: 124
paths:
  - .github/workflows/ci.yml
  - apps/troupe_core/lib/troupe/commands.ex
  - clients/tui/lib/mix/tasks/troupe.cli.reference.ex
  - clients/tui/lib/troupe/cli.ex
  - clients/tui/test/troupe/cli_reference_test.exs
  - docs/developer/build.md
gist: "`troupe --help` and the command reference are written from two tables, the command lines beside `troupe`'s parser and the harness's slash commands…"
---

Issue #124, its last done-when item, left by 698 and 763.
The help was the parser module's hand-written moduledoc and listed no slash command
at all; the TUI's README carried a second hand-written list of both, which had lost
`/memory` and `/context` and still offered `/code` for the agent called `build`; and
no page said what every command does.
- **What "one table" covers.** The slash commands are `Troupe.Commands`, the table
  `commands.list` serves both clients (698): the help prints its built-ins by section
  with each one's usage, summary and aliases, and the page adds the detail, an
  example and what each needs. The command lines are a table of their own,
  `Troupe.CLI.commands/0`, beside the parser in the TUI rather than in the harness:
  they are this client's command line, which neither the daemon nor the desktop app
  has, and nothing in the umbrella may depend on a client (666). A row is how the
  line is typed, what it does, and command lines that are it.
- **Held to the parser, not only to the page.** A table nothing checks against the
  parser is the hand-written text with more punctuation. The suite parses every
  row's command lines, holds the modes they reach equal to `Troupe.CLI.mode()`, and
  every switch the parser takes to one the help names; a subcommand added without a
  row, or a row the parser no longer takes, fails it.
- **The page.** `docs/user/cli-reference.md`, in the users' track and the site's nav:
  two parts between markers, written by `mix troupe.cli.reference` in `clients/tui`,
  the one project that sees both tables, and the rest by hand, as `configuration.md`
  holds the key reference. `--check` runs in the TUI's `mix check` and in
  `dev-check`'s TUI job, and both workflows run that job when the page alone changes.
  The TUI's README points at it and keeps what no table holds: the agents a session
  has and the commands people write, which are a session's own (its config, bundle
  and workspace), so the help and the page name them in a sentence and the palette
  lists them.
- **`troupe --help` needs no daemon.** It reads the table compiled into the binary,
  the one the daemon serves, so `Troupe.Commands` joins the harness modules the TUI
  may call (`mix troupe.xref`), as `Troupe.Config.Schema` did (761); TUI Decision
  138. A command line that does not parse is still answered with the command lines
  alone.
- **Not here:** `/todo`, which a branch window's input box takes and the table does
  not list, and `troupe-daemon`'s own command line.
- **Proof:** the TUI's `cli_reference_test.exs` (the help lists every built-in with
  its summary, and the committed page is what the tables render, both failing on the
  chunk's tip; every row parses and the rows reach every mode; every switch is
  named), and the installed `troupe --help`, on the pull request.
