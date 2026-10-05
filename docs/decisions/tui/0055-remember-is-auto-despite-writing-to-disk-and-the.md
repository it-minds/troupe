---
number: 55
title: "`remember` is `:auto` despite writing to disk, and the `librarian` that rebuilds the brief is dispatched once per session as a `source: :memory` window that dismisses itself"
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: "`remember` is `:auto` despite writing to disk, and the `librarian` that rebuilds the brief is dispatched once per session as a `source: :memory`…"
---

The only file `remember` can reach is the brief and the model cannot name a path, so the approval prompt would buy nothing and guarantee the brief never got written; `remember` is in the read-only set for the same reason, which is what lets `explore` and `plan` — the agents that learn the most and change the least — record what they found. The librarian is a normal primary profile (so `/librarian` works by hand) on the cheap model with read-only tools, guarded by `counters["librarian"]`, which is folded from the log and therefore idempotent across a Dispatcher restart and a resume. `source` already existed on `branch_spawned` and is already in the Codec's enum keys, so a harness-raised window needed no new event type; it clears itself away because it reports to nobody. Tests default `memory.auto_refresh` off, since every temp workspace lacks a brief and would otherwise dispatch a librarian into the Fake's script.
