---
number: 687
title: A tool that keeps failing stops the turn and asks, whatever the budget says; `always` lifts only the limit it was asked about; and a delegate's turns are its own
date: 2026-09-25
status: accepted
issue: 117
paths:
  - ARCHITECTURE.md
  - PROTOCOL.md
  - apps/troupe_a2a/lib/troupe/a2a/events.ex
  - apps/troupe_a2a/test/troupe/a2a/stream_test.exs
  - apps/troupe_core/lib/troupe/agent/budget_question.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/budget.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/session/loop.ex
  - apps/troupe_core/lib/troupe/sessions/index.ex
  - apps/troupe_core/test/troupe/agent/budget_question_test.exs
  - apps/troupe_core/test/troupe/agent/tool_failures_test.exs
  - apps/troupe_core/test/troupe/budget_test.exs
  - apps/troupe_core/test/troupe/session/loop_test.exs
  - apps/troupe_core/test/troupe/session/sleep_test.exs
  - apps/troupe_plane/lib/troupe/plane/triggers.ex
  - apps/troupe_plane/test/troupe/plane/triggers_test.exs
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_worker/lib/troupe/worker/session/manager.ex
  - apps/troupe_worker/test/troupe/worker/approval_status_test.exs
  - apps/troupe_worker/test/troupe/worker/stopped_turn_test.exs
  - clients/gui/apps/desktop/src/views/Question.tsx
  - clients/gui/packages/client/src/transcript.ts
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/test/troupe/cli_test.exs
  - clients/tui/test/troupe/remote_translate_test.exs
  - scripts/live-check
gist: A tool that keeps failing stops the turn and asks, whatever the budget says; `always` lifts only the limit it was asked about
---

Issues #117 and #118, from one session: a `qwen3-235b` root agent called
`read_branch` with ids `"1"` to `"352"`, one per model call, and failed the same way
each time for half an hour and over $4, after the person had answered `always` to an
input-token question — which lifted the turn, output and time limits as well.
- **The failure guard.** `Agent.Server` counts each tool's failures in a row, by the
  tool's name. Not by its error text: the loop's errors differed by id, normalising
  text is guesswork, and a tool that fails ten times running deserves the question
  whatever it said. A success of that tool clears its count. Counts are taken when a
  turn's results are folded, in call order; the calls a cancel or a restart closes
  are not counted. At `tool_failures_note_at` (5) a note follows the results, a
  `user_input` from `harness` as 659's notes are: the model reads it, both clients
  already show it, a replay rebuilds it. At `tool_failures_stop_at` (10) the gate
  before the next model call stops the turn, ahead of the budget and under
  `full_send`, a lifted limit or a contract budget alike, because it is about the
  loop and not the money.
- **Asking.** The root asks as the budget does (660): through
  `Troupe.Session.Questions` under `failures-<n>`, with `tool_failures_ask_started`
  and `tool_failures_ask_answered` beside it, waiting in `:waiting` in the slot the
  budget question uses. So there is one question at a time, and one still owed is
  folded and asked again under its own id after a restart. `stop` is the first
  option, because a client with nobody to ask answers with the first (the headless
  runner does); `continue` clears the count. `stop` writes a harness note saying why
  and ends the turn with `turn_ended` `reason: tool_failures`. The headless runner
  exits 1 on it, `/loop` counts it a failed iteration, and a restart does not take
  the turn up again (it reads as a cancel). A session with `approvals: deny` answers
  `stop` itself. A subagent does not ask: it ends `tool_failures` and hands its
  parent what it has, labelled partial. The counts are not replayed, as 659's guards
  are not; `0` turns a step off.
- **`always` lifts one limit.** `Troupe.Budget` gains `lifted`, which `check/1`
  skips. The answer names the limit (`budget_ask_answered.lifted`), and the option
  says which: "lift the input-token limit for the rest of the session". The GUI's
  and TUI's own words for it changed to match. A lifted limit still reaches the
  delegates, inside their slice, since 660's reason stands; a lifted dimension's
  slice is a share of the parent's first allowance, because of a limit it has passed
  the parent has nothing left to share. An `always` in a log written before this has
  no `lifted`, and folds to the limit its `budget_ask_started` named. That is what
  the question asked about; the limits it used to lift as well ask again when
  reached, which costs a question and never any work. 660 said `always` lifted the
  whole budget, and now points here.
- **A delegate's turns are its own.** `Budget.slice/2` gave a child `budget_share`
  of its parent's *remaining* turns: 0.4 × (40 − used), about 14 for an `explore`
  started late in a root's turn, and six of seven asked to read an app ran out
  before reporting (#115). But a child's turns cost its parent none. Only its tokens
  are charged back, and its clock runs on the parent's, so sharing turns had nothing
  behind it and shrank with every turn the parent took. A delegate now gets the turns
  its parent was first given (40 by default), lowered by its definition's
  `max_turns` as a root's are; tokens and time are still a share of what the parent
  has left. The issue's other options were worse. A turn floor for `explore` alone
  patches one profile. Leaving turns out for read-only agents needs a notion of
  read-only, and removes the one bound on a loop of cheap calls. Resetting a root's
  turns on each input changes the root's contract, and belongs with the root
  turn-cap discussion. With tokens still sliced and the failure guard on stuck
  loops, a full turn allowance is safe.
- **Whitespace is not a reply.** A reply of whitespace alone is empty, nudged once
  and then `empty_reply` (659), and a subagent's prose summary is handed over
  trimmed, as #130 did for a budget stop's.
- **Proof:**
  - `Troupe.Agent.ToolFailuresTest`: the note at 5 and the question at 10, `stop`,
    `continue`, a success clearing the count, `full_send`, `always` on the budget
    question, an unattended session, the config's thresholds, a subagent, a
    question re-asked after a restart, a stopped turn a restart leaves alone, and
    no approval left open in the summary after a stop.
  - `Troupe.Session.SleepTest`: a session asleep on the guard's question is listed
    as waiting and asks it again on wake (#119's sleep); once stopped, it wakes
    with nothing to take up.
  - `Troupe.Agent.BudgetQuestionTest`: `always` on input tokens leaves turns asking;
    on turns, input tokens and time; an old `always` folds to its question's limit.
  - `Troupe.BudgetTest`: each limit lifted leaves the other three.
  - `Troupe.Agent.DelegationTest`: an `explore` delegated after six turns finishes
    twenty reads, and a subagent's whitespace or padded reply.
  - `Troupe.Session.LoopTest`: guard-stopped iterations stop a loop.
  - The TUI's CLI test: a headless run exits 1 on a guard stop.
  - The installed daemon, driven with a fake-provider script.
- **Not tested:** a real gateway. The nightly real-gateway job is to rely on the
  guard's `turn_ended` reason.
