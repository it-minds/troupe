---
number: 106
title: A question is answered as a question, not typed as input
date: 2026-09-20
status: accepted
paths:
  - clients/tui/test/troupe/question_client_test.exs
gist: A question is answered as a question, not typed as input
---

`Client.answer/3` used to send the person's answer to `ask_user` as ordinary input, because the wire had no other way; the daemon now has `question.answer` (troupe-remote Decision 651), so the worker sends that, with the call id the question carried. `Troupe.Remote.Translate` turns `question_asked` into the `:question_asked` the model already drew as a menu and `question_answered` into what clears it, and a branch's worker registers a question's call id beside an approval's so the parent's screen routes the answer to the right session. Nothing in the UI changed: it asked for exactly this shape before the harness left.
