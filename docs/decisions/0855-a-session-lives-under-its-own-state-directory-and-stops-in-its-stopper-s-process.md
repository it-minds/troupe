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
  - apps/troupe_core/test/troupe/sessions/lifecycle_test.exs
  - apps/troupe_core/test/troupe/sessions/index_test.exs
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/test/troupe/gateway/stopping_session_test.exs
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

- **A session's files are under its own state directory.** A session's config may name
  `state_dir`, and its log was written there, but `Troupe.Session.Blobs` and
  `Troupe.erase_session/1` built the session's directory without it, under the platform's
  state directory. So a large tool result or a kept output landed beside nobody's log, and
  erasing such a session deleted those blobs and left its log where it was, with
  everything the session said in it. Every call into `Blobs` now takes the session's state
  directory (`state.config.state_dir` in the agent, the tool context's config in
  `Output.keep/2` and `read_output`, the index's entry for `blob.get`). An erasure deletes
  the session's directory under its own state directory, and every directory named for its
  id under every state directory the daemon knows, so a session found anywhere goes from
  everywhere. That last is a glob on the id, so only for an id of the shape the harness
  gives (`Troupe.Session.valid_id?/1`): `..` names nothing. The test suite, which passes
  every session a scratch `state_dir`, had filled the developer's own state directory with
  blob directories the same way (2,219 of them on this machine); it writes none there now.
- **The index reads every state directory it knows.** It read only the platform's, so a
  session in a configured `state_dir` vanished from every listing the moment it went
  dormant, and `get` could not find it to wake or erase. It now reads its own (the
  platform's, or the one a test gives it), the one the person's `config.yaml` names, read
  once as the index starts, and every one a session it was told of was started with
  (`register/3` carries `state_dir`), kept until a read finds the directory gone and no
  running session is under it. `Troupe.Sessions.Index.roots/0` hands that list out, and a
  dormant session read by id (`Troupe.events/1`, `head_seq/1`, `replay_from/2`, the
  `seen` mark on attach and detach) is looked for in it, through `Log.locate/2`, which takes
  a list. Not chosen: reading every workspace's own `.troupe/config.yaml` for a
  `state_dir`. A trusted workspace that names its own is found while the daemon runs, from
  its sessions' registration; after a restart, not until one of its sessions starts again.
- **A stop runs in its stopper's process.** `Troupe.Sessions.stop_session/1` was
  `DynamicSupervisor.terminate_child/2`, which runs the whole shutdown inside
  `Troupe.Sessions`: a tree that took its thirty seconds held every other session's start
  and stop for as long. It is now `Supervisor.stop(pid, :shutdown, 30_000)` from the
  caller, and the tree killed if that runs out, which is what `terminate_child` did, and
  answers once the tree is gone. The tree is `:transient` and ends with `:shutdown`, so the
  supervisor does not start it again. `Troupe.stop_session/1` claims the stop first,
  `{:stopping, id}` in `Troupe.Registry` under the stopper (`Troupe.Sessions.stopping?/1`),
  then writes `session_dormant`, then stops the tree, and lets the claim go. A second stop
  of the same session while one runs waits for that one and writes nothing, so a session
  stopped by two callers at once says `session_dormant` once.
- **A command for a session being stopped waits, then is refused.** `Troupe.activate/2`
  handed out the registered tree, so a command that came in while a stop was under way
  went to a tree on its way down and was lost with it. Now, for a session being stopped,
  it waits for the tree to be gone and wakes the session afresh, as the command would have
  a moment later, for up to five seconds; past that it answers `{:error, :stopping}`, and
  the gateway says `session <id> is stopping; try again` (`unavailable`). Waiting first,
  because a stop with nothing slow in it takes milliseconds, and the command then simply
  works: nothing for a client to retry and no message for a person to type again.
  Refusing after five seconds, because the gateway answers a command inside the client's
  connection, whose other traffic waits meanwhile, and a client gives up on a call after
  fifteen; five is the bound the index's own calls have. Two commands that waited on the
  same stop both get the tree the first one woke. A tree that has just gone whose name
  `Troupe.Registry` still holds (a registry lookup does not ask whether the process it
  names is alive, and gives the name back a moment after the exit) is woken too, not
  handed out. Left: a command that arrives between the
  sweep deciding to stop a session and the stop being claimed, microseconds, reaches the
  tree as before.
- **An agent slow to answer the sweep is unknown, not gone.** An agent that did not answer
  its snapshot in five seconds, or was not registered at the moment (between two restarts
  of its Node), counted as gone, and the sweep dropped its entry while its tree ran on:
  listed dormant, and never swept again. It is now unknown: nothing decided, its clocks as
  they were, asked again at the next sweep. A tree that is really gone is dropped by its
  monitor, which was always the one that knew. With waking straight after a stop, a
  session's new tree may be registered before the old tree's monitor fires, so that
  monitor drops the entry only when no newer registration of the session is there.
- **A listing keeps a dormant session's row until its log changes.** `list` and
  `recent_workspaces` read every log on disk, in full, every time. A dormant session's row
  is now kept, in an ETS table the index owns and its read tasks write, against its log's
  size and modification time and the value of its `seen` mark: a log that has not changed
  is not read again. The mark is read by its value, a few bytes, because a reader that
  comes and goes within a second rewrites it with as many digits at the same time, which
  its size and time would not tell. Whether a client is attached is asked every time,
  since it is not on disk (`Unseen.since_mark/2` counts as if nobody were,
  `Unseen.unseen_now/2` asks). A full
  listing forgets the rows of logs it no longer finds. The first listing after the daemon
  starts still reads every log once. Measured with a private index over 2,000 session
  directories in WSL: with one recorded log each (9.7 MiB), `list` took 206 to 264 ms and
  `recent_workspaces` 213 to 234 ms every time, and now 49 to 51 ms after the first; with
  logs ten times that (97 MiB), 1,110 ms and 1,101 ms every time, and now 48 to 54 ms.

What did not change: when a session is due to sleep and what a stop does (Decision 848),
the calls' timeouts, and a session's state directory being whatever its config resolves.

Proof: `apps/troupe_core/test/troupe/sessions/lifecycle_test.exs` (a session's files and
its erasure running and dormant, with `state_dir` in the workspace's `config.yaml`; a stop
held six seconds while another session starts and stops in under one; a command waiting on
a held stop and waking the session, and refused when the stop runs past the wait),
`index_test.exs` (an agent suspended past the snapshot's timeout kept as running, then
swept; a dormant session in the state directory a user `config.yaml` names, and in one a
registered session was started with; a row kept while the log's size and time are
unchanged and read again when they change, and its unseen count following a mark
rewritten within the same second) and the gateway's
`stopping_session_test.exs`. Each failed on the chunk's tip before this.
