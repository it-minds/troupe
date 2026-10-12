---
number: 163
title: Nothing of a session's own sorts ahead of its window's opening when the daemon client reads its journal back, as nothing of a branch did
date: 2026-10-12
status: accepted
paths:
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/test/troupe/branch_client_test.exs
gist: The daemon client reads a session's own events back no earlier than its window's `branch_spawned`, so a rebuilt screen never drops the first line
---

Amends 132. `Troupe.ClipboardTest` and `Troupe.TUISelectionTest` copied a transcript
without its first line now and then on a busy machine (defects D8): the reply was there,
"do the thing" was not, and it was missing from the rebuilt screen too, not only from the
copy. `Client.Daemon.events/1` reads the session's journal back sorted by time, and the
journal's events carry two clocks: the `branch_spawned` that opens the session's own window
is stamped by this client as `Troupe.Remote.Worker` opens it, the line and everything the
session says by the daemon. The journal had them in the order they came, window first, but
the daemon had stamped the line a millisecond before the client stamped the window, so the
sort put the line ahead of it, and `Model.rebuild/3` folded the line into a window that did
not exist yet and dropped it.

Decision 132 settled the same thing for a branch's window: nothing of a branch sorts ahead
of its window's opening. The session's own events now take the same rule, each lifted to
its window's opening time where it was stamped earlier, and at an equal time the sort keeps
the journal's order, which is the order they came. An event stamped after its window sorts
by its own time, as before, so the session's events and its branches' still interleave by
when they happened.

Proof: `test/troupe/branch_client_test.exs` "the session's own first events are read back
inside its window" (a journal with the line stamped a millisecond ahead of its window)
fails on the chunk's tip and passes now. Under load, the Ctrl-Y test pinned to two busy CPUs
lost the line in two to four runs of every twenty on the tip, and in none of a hundred
after.
