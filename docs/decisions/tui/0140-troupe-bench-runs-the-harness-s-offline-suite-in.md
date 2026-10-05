---
number: 140
title: "`troupe bench` runs the harness's offline suite in this VM, against the harness compiled into this binary, and `Troupe.Bench` is a door the TUI may call"
date: 2026-10-04
status: accepted
issue: 390
paths:
  - clients/tui/lib/troupe/cli/bench.ex
  - clients/tui/test/troupe/bench_cli_test.exs
gist: "`troupe bench` runs the harness's offline suite in this VM, against the harness compiled into this binary, and `Troupe.Bench` is a door the TUI may…"
---

Issue
#390, root Decision 772. It prints the Markdown table, or with `--json` the JSON
report, and exits 1 when a measure is past its budget or a check fails. It never asks
the machine's daemon: what it measures is this build, and a daemon of another version
would answer for itself. So `Troupe.Bench` joins the modules `mix troupe.xref` lets
the TUI reach, as `Troupe.Doctor` did for `troupe doctor`; the TUI calls `run/0`,
`json/1`, `markdown/1` and `passed?/1`, and nothing of the session it runs. `--live`
is parsed and refused with exit 2 until the live runner exists, so the flag is the
one that runner takes. Proof: `test/troupe/bench_cli_test.exs`.
