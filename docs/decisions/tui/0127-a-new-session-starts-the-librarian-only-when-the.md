---
number: 127
title: A new session starts the librarian only when the daemon says the refresh is due
date: 2026-09-27
status: accepted
paths:
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/test/troupe/memory_client_test.exs
gist: A new session starts the librarian only when the daemon says the refresh is due
---

Amends 105, which started it whenever `memory.get` said the brief was
`absent` or `stale`: a librarian that failed, or wrote nothing where there was no
brief, left it so, and the next session started another (root Decision 713). The
daemon records each librarian's try and answers `refresh_due`, false while a try
that built nothing is younger than `memory_max_age_days`; `create_session` starts
no branch then, and the prompt still follows the status. A daemon from before the
field leaves it to the status, as 105 did. `/memory refresh` is not held off, and
`/memory` shows the status as before. Proof: `test/troupe/memory_client_test.exs`
("a session after a librarian that failed starts none"), which failed on the
chunk's tip, and the installed TUI on a scratch repository, on the pull request.
