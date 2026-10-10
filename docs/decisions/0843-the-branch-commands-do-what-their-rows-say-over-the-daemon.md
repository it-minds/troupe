---
number: 843
title: The branch commands do what their rows and TUI Decisions 39, 42 and 57 say over the daemon, a session's own window is not dismissed, and read_branch lists no parent
date: 2026-10-10
status: accepted
issue: 502
supersedes: [646]
paths:
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/client/remote.ex
  - apps/troupe_gateway/lib/troupe/gateway/worktrees.ex
  - apps/troupe_core/lib/troupe/tools/read_branch.ex
  - clients/tui/test/troupe/branch_commands_test.exs
gist: "/cancel discards Troupe's tree at rest; worktree_name; local changes no conflict; landed merge stays one; own window stays; read_branch lists no parent"
---

The command audit of #502 (`docs/developer/command-audit.md`) found the branch commands
short of their rows since a branch became a session of its own (Decision 646, TUI
Decision 103): D105. What each now does, and where a rule had to be chosen:

- **`/cancel` and `x x`** keep TUI Decision 57 rather than the row changing: the branch's
  turn is cancelled, and once it is at rest the worktree Troupe made for it is discarded
  and the window closed. The daemon refuses `worktree.discard` while the branch works
  (Decision 647), so the client asks again, every 200 ms for up to a minute, from a task
  of its own rather than the screen's process; a tree still kept after that, or one git
  would not remove, is said in the session's window with `/discard` to finish it. A
  branch in the checkout, or in a worktree the person checked out, keeps its files and
  loses its window, recorded `window_dismissed` with `cancelled: true`.
- **`/worktree <name>: <prompt>`** is TUI Decision 42 in the daemon: `session.create`
  takes `worktree_name`, the tree `<workspace>-<name>` on `troupe/<name>`, made the first
  time, the same one after, made again from its branch once only its directory went, and
  refused while a session works in it. The tree sits beside the checkout, as every
  worktree the daemon makes does, not under `.troupe/worktrees/` as the TUI's own harness
  had it. A name is one path segment git takes as a branch.
- **`/worktree <existing> <prompt>`** is TUI Decision 39: a first word naming a worktree
  the person checked out, by its directory's name or its branch, runs the branch there,
  as a session in that directory, recorded `managed: false`; `/merge` and `/discard`
  say it is theirs. Tab offers those and Troupe's own as `<name>:`, never the checkout
  itself (git lists it first) nor the workspace on screen. A `troupe/` tree is reached by
  its name, not as the person's.
- **A dismissed branch** is listed in `/sessions` after the directory's sessions, named
  for the window it was, read from the parent's journal (only it knows which windows were
  dismissed); one merged, discarded or cancelled is not, since it was ended, not let go.
- **A merge** git would not start because the checkout's own uncommitted changes are in
  its way is `conflict` with `reason: "local changes in the checkout"`, told apart from
  a conflict by MERGE_HEAD (git starts no merge it refuses) and a dirty checkout, not by
  git's words, which a locale changes. A merge that landed and whose tree git then could
  not remove is answered as the merge it is, `"removed": false` with `removal_error`;
  answered as an error, as it was, it read as though nothing had happened.
  `worktree.remove` runs git from the checkout the tree belongs to
  (`Troupe.Config.Trust.root/1`), as merge and discard already did: on Windows git cannot
  delete the directory it was started in.
- **A session's own window is not dismissed** (the row changes): letting go of the session
  left the screen on one it no longer reached, and on a pod sent what was typed next to
  this machine's daemon, since the route to the pod went with the connection. `/back`,
  `/sessions` and `/new` leave a session; command mode (#502 part A) decides what the
  root's window is.
- **`read_branch`** lists a session's branches and, for a branch, its siblings, but no
  longer the session they came from (this part of Decision 646): it is no branch, and
  `/ask`, a branch of the session it was asked from, read it as `build idle (no prompt)`.

Proof: `clients/tui/test/troupe/branch_commands_test.exs` (each item, against the
embedded daemon, a pod's on the suite's `FakeRemote`); `branches_test.exs` and
`worktrees_test.exs` in the gateway (the merge answers, the named tree, and, through a
stand-in for git on PATH, where `worktree.remove` starts git); `read_branch_test.exs`.
