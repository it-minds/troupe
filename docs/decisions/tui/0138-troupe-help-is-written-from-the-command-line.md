---
number: 138
title: "`troupe --help` is written from the command-line table beside the parser and the harness's command table, and `Troupe.Commands` is a door the TUI may call"
date: 2026-10-04
status: accepted
issue: 124
paths:
  - apps/troupe_core/lib/troupe/commands.ex
  - apps/troupe_core/lib/troupe/config/schema.ex
  - apps/troupe_core/lib/troupe/doctor.ex
  - clients/tui/lib/troupe/cli.ex
  - clients/tui/test/troupe/cli_reference_test.exs
gist: "`troupe --help` is written from the command-line table beside the parser and the harness's command table, and `Troupe.Commands` is a door the TUI…"
---

Issue
#124, root Decision 767. `Troupe.CLI.help/0` prints the command lines
(`commands/0`), then the built-in slash commands by section from
`Troupe.Commands.builtins/0`, then a sentence for the agents and written commands a
session adds. `usage/0`, the answer to a command line that does not parse, is the
command lines alone, so a typo is not answered with two screens. The help is read
from the table compiled into this binary rather than asked of a daemon: `--help` has
to work where none runs, and it is the table the daemon serves. So `Troupe.Commands`
joins the modules `mix troupe.xref` lets the TUI reach, as `Troupe.Doctor` and
`Troupe.Config.Schema` did; the TUI calls only `builtins/0`, which is data, and the
palette still reads `commands.list`. Proof: `test/troupe/cli_reference_test.exs`.
