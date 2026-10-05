---
number: 103
title: A branch is a session the parent's screen shows as a window
date: 2026-09-20
status: accepted
paths:
  - clients/tui/CLAUDE.md
  - clients/tui/test/troupe/branch_client_test.exs
gist: A branch is a session the parent's screen shows as a window
---

Decision 101 made a session one agent and one window; Martin's 7.3 (b) says a second agent is a second session. This is where the two meet without giving up the product: `/build fix the test` on a session's screen creates a session with `parent` set to this one (troupe-remote Decision 646), in its own worktree because the checkout is busy, and shows it as the window `build-1` — named the way a local branch always was. The renaming is the branch worker's (`Troupe.Remote.Branch`): its events reach this screen's subscribers under the window's name, its journal keeps its own; `Troupe.Client.Daemon.events/1` reads both back in one order, input typed into the window is routed to the branch's session, an approval it asks is answered through the call id the worker registered. The parent's journal, not the daemon, records which windows exist (`branch_spawned` with the branch's session id, `worktree_created`, `window_dismissed`, `worktree_merged`, `worktree_discarded`): the daemon knows a session's parent but not what its parent's screen called it, and the journal is what re-opens the windows with the session. `/merge` and `/discard` speak `worktree.merge` and `worktree.discard` (Decision 647) and close the window on success; a conflicting merge leaves the window and says so. `/worktree …` is the default agent, always in a worktree. The UI did not change: it already drew windows, approvals and worktree state from these events.
