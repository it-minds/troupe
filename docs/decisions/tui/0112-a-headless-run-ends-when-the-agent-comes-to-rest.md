---
number: 112
title: A headless run ends when the agent comes to rest, not only when it calls `finish`, and its exit code says how
date: 2026-09-25
status: accepted
issue: 127
paths:
  - clients/tui/fixtures/fake_scripts/no_finish.json
gist: A headless run ends when the agent comes to rest, not only when it calls `finish`, and its exit code says how
---

A real model usually ends its turn with prose, which
leaves the agent `idle`, and the printer waited for the `done` that only `finish`
writes: `troupe run --headless` did its work, printed its answer and sat there until
something killed it (issue #127). The daemon now writes the end of a turn to the log
(`turn_ended`, root Decision 685), and the printer rests on it, on `cancelled` and on
`agent_done`, all read from the log rather than the live `agent_state`, which can be
dropped and says `idle` once before the task is taken. The code is `0` for a turn that
ended or an agent that finished, `1` for one that stopped short, a failed model request
or a cancel, and `3` when an approval was refused for want of anyone to give it —
Decision 20 still refuses it, and the `3` is what lets a script tell that the task may
not have been done. A model error is printed, with `troupe config` as the next step
where the provider has no key. The printer's replay key gains the event's type, since
one durable event can become several local ones with the same `seq`. Proof: the CLI
tests with a turn that ends in prose, with and without the printer listening, a
refused approval, a model error, a provider with no key, a refusal and a librarian
branch that rests first, all of which failed before this; and the native smoke runs
`fixtures/fake_scripts/no_finish.json` through the shipped binary.
