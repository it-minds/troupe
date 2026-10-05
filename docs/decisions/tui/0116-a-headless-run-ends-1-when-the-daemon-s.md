---
number: 116
title: A headless run ends `1` when the daemon's connection stays down a minute, and the terminal UI is refused without a terminal
date: 2026-09-26
status: accepted
paths:
  - clients/tui/lib/troupe/remote/worker.ex
gist: A headless run ends `1` when the daemon's connection stays down a minute, and the terminal UI is refused without a terminal
---

D20 in docs/developer/defects.md, left
over from the first-run and headless work. The client reconnects to a daemon on its
own and never gives up, so `troupe run --headless` against a daemon that was stopped
or crashed waited for ever on a rest that could not come. The printer now reads the
connection as the status line does, from the worker's `:remote_status`: down starts
a minute's clock (`:reconnect_ms`), up stops it, and a clock that runs out is a run
that ended short, `1`, with the reason as its last line. A minute outlasts a daemon
restart and the reconnect backoff's 30-second ceiling. Plain `troupe`, `troupe
resume` and `troupe run` without `--headless`, with standard output not a terminal
(`:io.getopts/1`'s `stdout`), drew into the file and never exited, since nothing
could press the key that quits; they now say so in one line that names `troupe run
--headless` and `troupe config`, and exit `1` before a session is made. A plane
session's model key is the plane's, which `troupe config` cannot change, so the
translation gives a key error a `next_step` of its own, the plane's administrator,
and `Troupe.UI.ModelError` prefers it: the screen still branches on nothing. The root
window of a session whose profile the client knows is named for it (`spawned
/build`, not `/root`), as the window the worker opens before any event already was;
a question or approval asked again under the same call id, as a call re-run after a
restart asks it, replaces the one pending instead of being drawn twice; and `/todo
complete <n>` sends the `complete` that `todo.edit` has always taken. Proof:
`test/troupe/cli_test.exs`, the translation, model-config, recorded-question and
recorded-approval tests, and `worker_commands_test.exs`.
