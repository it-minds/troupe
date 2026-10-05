---
number: 145
title: "`troupe models --json` is the same run as `troupe models`, printed as the harness's object"
date: 2026-10-05
status: accepted
paths:
  - apps/troupe_core/lib/troupe/config.ex
  - clients/tui/test/troupe/models_cli_test.exs
gist: "`troupe models --json` is the same run as `troupe models`, printed as the harness's object"
---

Root Decision 783. The runner refreshes as 143 says, then hands `asked` to
`Troupe.Config.models_json/2` instead of `describe/2` and prints the object with
`Jason`, so `mix troupe.xref` has no new door: the object is built in `Troupe.Config`,
which it already allowed. `--workspace` and `--refresh` mean what they mean without
`--json`, and a config that does not load is the reason on standard error and exit 1,
with nothing on standard output for a program to mistake for an answer. Its own line
in the command table, so `troupe --help` and the reference list it. Proof:
`test/troupe/models_cli_test.exs`, against a stand-in gateway.
