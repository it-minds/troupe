---
number: 855
title: A session's files are under its own state directory everywhere, and the index reads every state directory it knows and keeps a dormant session's row until its log changes; a stop runs in its stopper's process; a command for a session being stopped waits up to five seconds and wakes it afresh, or is told it is stopping; an agent slow to answer the sweep is unknown, not gone
date: 2026-10-11
status: accepted
supersedes: [848]
paths:
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_core/lib/troupe/session.ex
  - apps/troupe_core/lib/troupe/session/blobs.ex
  - apps/troupe_core/lib/troupe/session/log.ex
  - apps/troupe_core/lib/troupe/sessions/index.ex
  - apps/troupe_core/lib/troupe/sessions/unseen.ex
  - apps/troupe_core/lib/troupe/tools/output.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
symbols:
  - Troupe.stop_session/1
  - Troupe.activate/2
  - Troupe.erase_session/1
  - Troupe.Sessions.stop_session/1
  - Troupe.Sessions.stopping?/1
  - Troupe.Sessions.Index.roots/0
  - Troupe.Session.Blobs
gist: Blobs and erasure use the session's state_dir; index reads all known ones, rows kept by log stamp; stops run in the caller; activate waits 5 s, then :stopping
---

What Decision 848 left as it was, and what D117's fix found on the way. 848 stays: nothing
in the index's process waits on a session or reads a log. This replaces its list of what
was left for a later look.

- **A session's files are under its own state directory.** An erasure deletes the
  session's directory under its own state directory, and every directory named for its id
  under every state directory the daemon knows, so a session found anywhere goes from
  everywhere. That last is a glob on the id, so only for an id of the shape the harness
  gives (`Troupe.Session.valid_id?/1`): `..` names nothing.
- **The index reads every state directory it knows.** It now reads its own (the
  platform's, or the one a test gives it), the one the person's `config.yaml` names, read
  once as the index starts, and every one a session it was told of was started with
  (`register/3` carries `state_dir`), kept until a read finds the directory gone and no
  running session is under it. Not chosen: reading every workspace's own
  `.troupe/config.yaml` for a `state_dir`.
- **A stop runs in its stopper's process.** `Troupe.Sessions.stop_session/1` was
  `DynamicSupervisor.terminate_child/2`, which runs the whole shutdown inside
  `Troupe.Sessions`: a tree that took its thirty seconds held every other session's start
  and stop for as long. It is now `Supervisor.stop(pid, :shutdown, 30_000)` from the
  caller, and the tree killed if that runs out, which is what `terminate_child` did, and
  answers once the tree is gone. `Troupe.stop_session/1` claims the stop first,
  `{:stopping, id}` in `Troupe.Registry` under the stopper
  (`Troupe.Sessions.stopping?/1`), then writes `session_dormant`, then stops the tree, and
  lets the claim go.
- **A command for a session being stopped waits, then is refused.** `Troupe.activate/2`
  handed out the registered tree, so a command that came in while a stop was under way
  went to a tree on its way down and was lost with it. Now, for a session being stopped,
  it waits for the tree to be gone and wakes the session afresh, as the command would have
  a moment later, for up to five seconds; past that it answers `{:error, :stopping}`, and
  the gateway says `session <id> is stopping; try again` (`unavailable`).
- **An agent slow to answer the sweep is unknown, not gone.** An agent that did not answer
  its snapshot in five seconds, or was not registered at the moment (between two restarts
  of its Node), counted as gone, and the sweep dropped its entry while its tree ran on:
  listed dormant, and never swept again. It is now unknown: nothing decided, its clocks as
  they were, asked again at the next sweep.
- **A listing keeps a dormant session's row until its log changes.** `list` and
  `recent_workspaces` read every log on disk, in full, every time. A dormant session's row
  is now kept, in an ETS table the index owns and its read tasks write, against its log's
  size and modification time and the value of its `seen` mark: a log that has not changed
  is not read again.
