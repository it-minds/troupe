---
number: 718
title: A session starts without reading the workspace's ignore rules; watching reads them when it starts
date: 2026-09-27
status: accepted
issue: 231
paths:
  - apps/troupe_core/lib/troupe/session.ex
  - apps/troupe_core/lib/troupe/session/files.ex
  - apps/troupe_core/lib/troupe/session/watcher.ex
  - apps/troupe_core/test/troupe/watch/watch_session_test.exs
gist: A session starts without reading the workspace's ignore rules; watching reads them when it starts
---

Issue #231's cause (TUI Decision 128 has the rest). The watcher and
`Session.Files` each walked the workspace for its `.gitignore`s in `init`, whether or
not they would ever watch: two walks per `session.create`, inside `Troupe.Sessions`'
`start_child`, which does not time out, for rules only a watch or `fs_events` backend
uses, and both are off by default. A directory with no `.gitignore` to prune the walk
is walked whole, and a home directory, where a new terminal opens, is the worst of
them: one walk of it took over 150 s on the machine of the issue (this repository,
8 s). So the TUI's embedded daemon answered `session.create` long after the client's
30 s, and plain `troupe` died in its boot. The rules are now read by the backend's
start, in both, and by a scan asked for (`Watcher.scan_now/2`). A session that
watches from its start still walks there, as before; that is a watch in a home
directory, which polling would not survive either. Proof: `watch_session_test.exs`
("a session that is not watching starts without reading the ignore rules"), and
plain `troupe` in a directory of 360,000 files, which died in its boot after 30 s
before and opens now, on the pull request.
