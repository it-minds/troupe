---
number: 141
title: "`troupe bench --live` asks before it spends, at a terminal only, and `--json` and `--compare` take a value or none"
date: 2026-10-04
status: accepted
paths:
  - clients/tui/lib/troupe/cli.ex
  - clients/tui/lib/troupe/cli/bench.ex
  - docs/developer/bench.md
gist: "`troupe bench --live` asks before it spends, at a terminal only, and `--json` and `--compare` take a value or none"
---

Root Decision 773. The plan and its cap go to
standard error, so `--json` on standard output stays JSON. The question is asked only
where `troupe config` asks one, with standard input and output a terminal, and the
same way: on Windows key by key (`Troupe.CLI.Prompt`), since the binary's VM there
has no reader on standard input (Decision 128), so a cooked read never returned, and
the first installed run hung on it. `y` or `yes` runs it; anything else, or no
terminal to ask in (a script, a pipe), runs nothing and exits 2; `--yes` answers
beforehand. `--repeat N`, `--model M` and `--yes` belong to `--live` and are refused
without it. `--json` stays the switch it was (`troupe bench --json` prints the
report) and takes a file as well, `--json FILE` writing the report there and printing
the table; `--compare` alone compares with the last bench and `--compare REF` with a
version or a model. OptionParser has no switch with an optional value, so for
`troupe bench` only, the word after either, unless it is a flag, is taken as its
value before the parser runs; anywhere else `--json` is the plain switch. `--md FILE`
writes the table to a file, live or offline. The TUI calls only `Troupe.Bench`
(`plan/1`, `describe_plan/1`, `question/1`, `live/2`, `compare/1`), the door
Decision 140 opened. Proof: `test/troupe/bench_cli_test.exs`, the question played
through `Bench.run/2`'s `:ask`, and with none, under `capture_io`, no terminal.
