---
number: 120
title: The budget question is drawn as the question it rides on — the harness's words, its options numbered and picked with a digit, or an amount typed — and y, n and a no longer answer it
date: 2026-09-26
status: accepted
issue: 183
paths:
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/lib/troupe/ui/headless/printer.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/test/troupe/budget_answer_test.exs
  - clients/tui/test/troupe/cli_test.exs
  - clients/tui/test/troupe/remote_translate_test.exs
gist: The budget question is drawn as the question it rides on — the harness's words, its options numbered and picked with a digit, or an amount typed
---

Issue #183, troupe-remote Decision 699. The window drew its
own line for a `:budget` item, the limit and "continue anyway? (y one more slice / n
stop / a lift this limit)", and dropped the `question_asked` the harness writes
beside it. So the sizes and scopes the daemon now offers, and its account of what
the limit is for and what the session has spent, never reached the screen, and a
typed amount — the answer the issue is about — could not be given at all.
`Troupe.Remote.Translate` now folds the question's words and options into the
`:budget_ask_started` event, whichever of the two events comes first, and the
window keeps one item per id; `pending_blocks` draws it as `BUDGET: <the harness's
words>`, the numbered options and a hint naming the typed forms, and the digit and
Enter keys treat a `:budget` item as a `:question`. The y/n/a shortcuts answer
approvals alone: with typing on, an answer in a person's own words — `no limit this
session` — would have stopped the session on its first key. A daemon from before
this sends the question without an account and the old three options, which draw
as they are; headless mode still stops at the budget, and once, though the item is
now drawn twice. Proof: `Troupe.RemoteTranslateTest` (the item filled in by its
question), `Troupe.BudgetAnswerTest` (the words and options on screen, a digit
answers, a typed answer beginning with `n` stays a letter and is sent with Enter),
and the recorded questions, which draw as before.
