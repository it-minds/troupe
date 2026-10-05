---
number: 692
title: A `user_input` names the send it was taken from
date: 2026-09-26
status: accepted
issue: 181
paths:
  - PROTOCOL.md
  - apps/troupe_core/test/troupe/agent/input_test.exs
  - apps/troupe_core/test/troupe/log/fold_test.exs
  - apps/troupe_core/test/troupe/session/log_schema_test.exs
  - apps/troupe_core/test/troupe/session/loop_test.exs
  - apps/troupe_core/test/troupe/watch/watch_session_test.exs
gist: A `user_input` names the send it was taken from
---

`input_queued` and
`input_accepted` carried the client's `command_id` and `user_input`, the copy with
the text, did not, so a client that draws a line as it is typed could not tell the
durable copy for the same line, and the TUI drew every typed line twice (issue #181).
The agent now writes the command id on the `user_input` of every input it takes, a
person's, the watcher's, a loop's iteration and a task edit alike: the id its
`input_accepted` has, which the agent generates where the caller had none. A
`harness` note, which nobody sent, has none. It is an added, optional field, which
PROTOCOL.md §11 allows. Neither the agent's replay nor the fold reads it, so a log
written before it replays as it did and no recorded fixture's hash moves. The GUI
keeps its pending send outside the stream and draws `user_input` once, and is
unaffected; the TUI draws a line once by it (clients/tui Decision 117).
- **Proof:** `Troupe.Agent.InputTest`, the loop's ids in `Troupe.Session.LoopTest`,
  the watcher's in `Troupe.Watch.WatchSessionTest`, `Troupe.Session.LogSchemaTest`,
  `Troupe.Log.FoldTest` and `mix troupe.schema.diff`.
