---
number: 131
title: A session that starts no librarian says why, when the reason is one a person would want
date: 2026-09-28
status: accepted
issue: 246
paths:
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/test/troupe/memory_client_test.exs
gist: A session that starts no librarian says why, when the reason is one a person would want
---

Issue #246. Amends 105 and 127: every way `create_session` decided
against the librarian was silent, a branch the daemon refused was thrown away, and
since 127 a librarian that failed once (a `cheap` model the gateway answers with a
401) meant a week of sessions on that repository with no librarian and no word. The
reason is now logged, and when it is no model to ask, `memory.get` or the branch
failing, or a try being waited out, it is also one line in the session's window:
`no librarian for the project brief: …`, the hold with the day it ends
(`refresh_held_until`, root `PROTOCOL.md`), and `/memory refresh` as the way round.
Memory off, a directory git does not know and a fresh brief are the ordinary cases
and stay off the screen. The line is the client's own `remote_note` in the journal,
written by the worker once the session's first event has opened the window
(`Worker.note/2`): written before, it would sort ahead of those events, which a
window rebuilt from the journal has nowhere yet to draw. Proof:
`test/troupe/memory_client_test.exs` ("a session after a librarian that failed starts
none" and "a session with no model to ask says why no librarian starts"), which
failed on `main`, and the installed TUI on scratch repositories, on the pull request.
