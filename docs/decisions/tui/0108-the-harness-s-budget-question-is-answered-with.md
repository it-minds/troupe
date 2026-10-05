---
number: 108
title: The harness's budget question is answered with the keys the TUI already had, and what the harness writes about a cut or empty reply is shown as the harness's words
date: 2026-09-20
status: accepted
paths:
  - clients/tui
gist: The harness's budget question is answered with the keys the TUI already had, and what the harness writes about a cut or empty reply is shown as the…
---

troupe-remote #29 (its Decision 660) made a spent budget a question: it rides on the
`ask_user` path as a `question_asked` with id `budget-<n>` and options `allow` /
`always` / `deny`, with a `budget_ask_started` / `budget_ask_answered` pair beside
it. The window has known a `:budget` pending item and answered it with `y` / `n` /
`a` since Decision 62, so the translator hands it that item from the harness's own
event and drops the `question_asked` that carries the same id rather than drawing the
question twice; the keys send the words the harness listens for through
`question.answer`, not an approval. `a` lifts this agent and its subagents, not every
branch — a branch is a session now. troupe-remote #28 (Decision 659) writes the note
it gives a model whose reply the output cap cut, or that said nothing, as a
`user_input` from source `harness`, and a `truncated` event beside it: both are shown
as notes, because neither is something the person typed. The pin moves to
troupe-remote `main` at `84edcb9`, the merge of #29.
