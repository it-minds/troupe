---
number: 117
title: A line is drawn once, however many copies of it come back, and the window, not the connection, knows which it has drawn
date: 2026-09-26
status: accepted
issue: 181
paths:
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
gist: A line is drawn once, however many copies of it come back, and the window, not the connection, knows which it has drawn
---

A line typed into the TUI was on screen twice
(issue #181): once as it was sent and once when the daemon wrote it back. The worker
withheld the durable copy of an input it had sent itself, by command id, and the copy
with the text, `user_input`, carried none; `input_queued`, which did, was withheld,
and a window rebuilt from the journal or another client's drew it beside the
`user_input` of the same line. The daemon now writes the command id on `user_input`
(root Decision 692), and the model draws a line once per command id: the first copy
draws it, whichever that is (the optimistic render, `input_queued`, which the
translation marks `queued`, or the `user_input`), and the `user_input`, always the
last, forgets the id, so the window remembers only inputs still in flight. The
worker's `own_commands` is gone and it publishes every durable event: what this
connection sent is not what the window shows, since a worker restarted between the
send and the echo has forgotten it, and a window rebuilt in between never drew the
line the worker then withheld. A copy that says something else is drawn as well,
because a task edit is queued as the edit and taken as the agent's note of it, and a
log written before 692 draws every copy it has, as it did. Proof:
`test/troupe/typed_input_test.exs`, which types into the TUI on a session in the
embedded daemon at an idle agent, mid-turn, and across a restarted worker, and
rebuilds each window from the journal, all of which drew the line twice before this;
and the translation test, which folds the wire's copies in every order they come.
