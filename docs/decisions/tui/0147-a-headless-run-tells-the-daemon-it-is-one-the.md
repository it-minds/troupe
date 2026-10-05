---
number: 147
title: "A headless run tells the daemon it is one: the link connects as `troupe-headless`, and the terminal UI as `troupe`"
date: 2026-10-05
status: accepted
issue: 419
paths:
  - clients/tui/lib/troupe/cli/runner.ex
  - clients/tui/lib/troupe/client/daemon/link.ex
  - clients/tui/test/troupe/cli_test.exs
gist: "A headless run tells the daemon it is one: the link connects as `troupe-headless`, and the terminal UI as `troupe`"
---

Issue #419, root Decision 787: the daemon names a
session's model calls by what the connection that created it called itself, and a
headless run and the terminal UI are one binary on one link. `Runner.run/1` puts
`client_name/1` in the application's `:client_name` before it creates the session,
and `Link.client_info/0` reads it when the link connects, which in a headless run is
that first call. Only the link: a headless run's session is created there and runs
its task to the end, and the session's per-session connection, which still says
`troupe`, wakes nothing in it. `troupe doctor` prints the root's `identify` line with
no change here. Proof: `test/troupe/cli_test.exs` ("a headless run tells the daemon
it is one"), and the installed `troupe run --headless` against a stand-in, whose
User-Agent said `headless`.
