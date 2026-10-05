---
number: 40
title: "`scripts/dev` runs the CLI/TUI from source via `TROUPE_CLI=1 mix run -- ...`"
date: 2026-09-11
status: accepted
paths:
  - clients/tui/lib/troupe/cli/runner.ex
  - clients/tui/scripts/dev
gist: "`scripts/dev` runs the CLI/TUI from source via `TROUPE_CLI=1 mix run -- ...`"
---

Iterating through a Burrito build is minutes per change; the same `Troupe.CLI.Runner` path runs under mix, so behaviour is identical except for the payload extraction.
