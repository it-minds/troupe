---
number: 142
title: "`troupe bench --live` takes `--suite`, `--scenario` and `--keep`, and refuses them, as it refuses `--repeat`, without `--live`"
date: 2026-10-04
status: accepted
paths:
  - clients/tui/lib/troupe/cli/bench.ex
gist: "`troupe bench --live` takes `--suite`, `--scenario` and `--keep`, and refuses them, as it refuses `--repeat`, without `--live`"
---

Root Decision 775. `--suite NAME` is a
live suite (`smoke`, the default, or `standard`), `--scenario a,b` names scenarios
whatever their suite, in one comma-separated value, since OptionParser keeps only
the last of a repeated switch; `--keep DIR` leaves each run's directories there. An
unknown suite or scenario is the plan's error, said before the cap and with nothing
run, exit 2. The plan's words name the suite and its scenarios on standard error,
where the cap is; the table on standard output ends with the summary of every run
before the verdict. The TUI still calls only `Troupe.Bench`'s door (140, 141): the
new options are `plan/1`'s. Proof: `test/troupe/bench_cli_test.exs` (the flags
parsed, refused without `--live`, the `standard` suite with `--keep` and `--json`, a
scenario by name and one that is not there).
