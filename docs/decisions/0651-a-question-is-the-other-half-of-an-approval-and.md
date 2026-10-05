---
number: 651
title: A question is the other half of an approval, and it travels the same way
date: 2026-09-20
status: accepted
paths:
  - apps/troupe_core/lib/troupe/registry.ex
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe/tools/ask_user.ex
  - apps/troupe_core/test/troupe/session/sleep_test.exs
  - apps/troupe_core/test/troupe/sessions/unseen_test.exs
  - apps/troupe_core/test/troupe/tools/ask_user_test.exs
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/tui/lib/troupe/remote/translate.ex
gist: A question is the other half of an approval, and it travels the same way
---

`ask_user` hands a decision to a person and its tool call waits for the answer,
with optional numbered options the client draws as a menu; an approval is a yes or
no about a call the agent has already decided on. `Troupe.Session.Questions` is
`Approvals` with text instead of a decision: the tool task blocks in a call that
never times out on its own (the agent's tool timeout is the one that matters, as
for an approval), `question_asked` and `question_answered` are durable so a
question outlives dormancy and a re-run tool finds its answer rather than asking
twice, and the unattended mode (`approvals: :deny`) answers at once that nobody is
there, so the model decides or finishes instead of waiting for a person who is not
coming. On the wire it is one method, `question.answer {session_id, call_id, text}`
(`control`, activating like `approval.respond`); a client with options sends the
chosen labels joined by `", "`, and free text is always an answer.
