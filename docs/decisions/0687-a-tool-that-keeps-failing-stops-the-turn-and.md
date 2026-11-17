---
number: 687
title: A tool that keeps failing stops the turn and asks, whatever the budget says; `always` lifts only the limit it was asked about; and a delegate's turns are its own
date: 2026-09-25
status: accepted
issue: 117
paths:
  - apps/troupe_core/lib/troupe/agent/budget_question.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/budget.ex
gist: A tool that keeps failing stops the turn and asks, whatever the budget says; `always` lifts only the limit it was asked about
---

- **The failure guard.** `Agent.Server` counts each tool's failures in a row, by the
  tool's name. Not by its error text: the loop's errors differed by id, normalising text
  is guesswork, and a tool that fails ten times running deserves the question whatever it
  said. A success of that tool clears its count. At `tool_failures_note_at` (5) a note
  follows the results, a `user_input` from `harness` as 659's notes are: the model reads
  it, both clients already show it, a replay rebuilds it. At `tool_failures_stop_at` (10)
  the gate before the next model call stops the turn, ahead of the budget and under
  `full_send`, a lifted limit or a contract budget alike, because it is about the loop and
  not the money.
- **Asking.** The root asks as the budget does (660): through `Troupe.Session.Questions`
  under `failures-<n>`, with `tool_failures_ask_started` and `tool_failures_ask_answered`
  beside it, waiting in `:waiting` in the slot the budget question uses. So there is one
  question at a time, and one still owed is folded and asked again under its own id after
  a restart. `stop` is the first option, because a client with nobody to ask answers with
  the first (the headless runner does); `continue` clears the count. `stop` writes a
  harness note saying why and ends the turn with `turn_ended` `reason: tool_failures`. A
  session with `approvals: deny` answers `stop` itself. A subagent does not ask: it ends
  `tool_failures` and hands its parent what it has, labelled partial. The counts are not
  replayed, as 659's guards are not; `0` turns a step off.
- **`always` lifts one limit.** `Troupe.Budget` gains `lifted`, which `check/1` skips. The
  answer names the limit (`budget_ask_answered.lifted`), and the option says which: "lift
  the input-token limit for the rest of the session". A lifted limit still reaches the
  delegates, inside their slice, since 660's reason stands; a lifted dimension's slice is
  a share of the parent's first allowance, because of a limit it has passed the parent has
  nothing left to share.
- **A delegate's turns are its own.** But a child's turns cost its parent none. Only its
  tokens are charged back, and its clock runs on the parent's, so sharing turns had
  nothing behind it and shrank with every turn the parent took. A delegate now gets the
  turns its parent was first given (40 by default), lowered by its definition's
  `max_turns` as a root's are; tokens and time are still a share of what the parent has
  left. The issue's other options were worse. A turn floor for `explore` alone patches one
  profile. Leaving turns out for read-only agents needs a notion of read-only, and removes
  the one bound on a loop of cheap calls. Resetting a root's turns on each input changes
  the root's contract, and belongs with the root turn-cap discussion. With tokens still
  sliced and the failure guard on stuck loops, a full turn allowance is safe.
- **Whitespace is not a reply.** A reply of whitespace alone is empty, nudged once
  and then `empty_reply` (659), and a subagent's prose summary is handed over
  trimmed, as #130 did for a budget stop's.
