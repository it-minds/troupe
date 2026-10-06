---
number: 118
title: A remote session the plane moves to another pod is followed there, and a worker that cannot find it stops after ten tries and says so
date: 2026-09-26
status: accepted
issue: 184
paths:
  - clients/tui/lib/troupe/remote/worker.ex
  - docs/developer/architecture.md
gist: A remote session the plane moves to another pod is followed there, and a worker that cannot find it stops after ten tries and says so
---

D21 in
docs/developer/defects.md, issue #184. A drain, a replaced pod, a lost one and an
activation by another client all leave a session dormant where it was, and its next
activation places it wherever there is room; `Troupe.Remote.Worker` reconnected to
the endpoint it was opened with for ever, and sent commands to a pod that answered
`not_found`. A reconnect after any failure now asks the plane's `session.open`, in
`read` mode, where the session is, and connects with the endpoint and token it is
given; a plane that does not answer leaves the endpoint as it was, and one that
answers `not_found` or `forbidden` ends the search. A pod's `not_found` naming the
session (`data.kind` of `session`) is that pod saying it does not hold it, before it
ran anything: an activating command is sent once more, with the same command id,
after `session.open activate`, and a second refusal of the same command is
answered, as is anything else, while the connection goes after the session. The
log's `session_dormant` and `session_activated` set whether the next activating
command goes through the plane first, for a plane session only, since a daemon wakes
its own. The failures count from the drop, and ten attempts that reach no session end
in a notice and a capability that say why; the next command is refused with "trying
again" and starts again from the plane. A session is reached when its subscription
is answered, not at the handshake, so the backoff resets there too. The plane's
`session.open` and `token.mint` answers now carry the session's `state` (additive),
so a client knows whether the pod it is handed runs the session or only serves its
history, and PROTOCOL.md §6 says how a move looks ("A session that moves"). Proof:
`test/troupe/remote_move_test.exs`, six cases that all failed before this, over a
`FakeRemote` that can move a session between workers and take a worker away.
