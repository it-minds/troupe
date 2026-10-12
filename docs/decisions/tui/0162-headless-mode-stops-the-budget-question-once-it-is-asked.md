---
number: 162
title: Headless mode sends its stop to the budget question once the question is asked, not when the harness says the budget ran out; the line is still said at the first of the two
date: 2026-10-12
status: accepted
paths:
  - clients/tui/lib/troupe/ui/headless/printer.ex
  - clients/tui/test/troupe/cli_test.exs
gist: Headless mode answers the budget question when it arrives with its options, never on `budget_ask_started` alone, which comes before the question exists
---

A release run failed on `Troupe.CLITest` "headless printer stops at the budget question
and exits 1": the run never came to rest. The harness logs `budget_ask_started` and only
then starts the task that asks the question on `Troupe.Session.Questions`, which writes
`question_asked` as it takes it. The printer answered "stop" on the first of the two
(Decision 120 folds both into a `:budget_ask_started` item, the first without options), so
on a busy machine its answer could reach the session before the question did. The
questions server keeps an early answer only for a question its log says was asked before
it started; any other it drops as a second answer. The question was then asked, nobody
answered it, and a headless run, which has nobody to answer, waited for good.

`Troupe.UI.Headless.Printer` now says the budget line once, at whichever item comes first,
and sends "stop" once, with the item that carries the question's options: by then the
question is in the session's log, so the questions server holds it. What a person sees in
a window is unchanged; a person answers from the options, which only that item has.

Proof: `test/troupe/cli_test.exs` "headless printer stops the budget question once it is
asked, not when the budget runs out" holds the agent's tasks while it says the budget ran
out, so the question waits until the printer has had its say. On the chunk's tip it fails
deterministically (no rest in 15 s, the question asked and unanswered in the mailbox); now
it passes.
