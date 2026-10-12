---
number: 881
title: A folder inside another repository follows git, a tracked or addable one belonging to the repository and an ignored one being a workspace of its own, for worktrees, the brief and the desktop app's check; and worktree.list answers in bounded time, its status read for two seconds, the checkout first, or not at all with status false
date: 2026-10-12
status: accepted
issue: 650
supersedes: [831, 851]
paths:
  - apps/troupe_core/lib/troupe/git.ex
  - apps/troupe_core/lib/troupe/session/memory.ex
  - apps/troupe_core/lib/troupe/memory/facts.ex
  - apps/troupe_gateway/lib/troupe/gateway/worktrees.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/client/daemon/start.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/gui/packages/client/src/memory.ts
  - clients/gui/packages/client/src/daemon.ts
  - clients/gui/apps/desktop/src/views/Local.tsx
  - PROTOCOL.md
  - apps/troupe_gateway/test/troupe/gateway/enclosing_repository_test.exs
  - apps/troupe_gateway/test/troupe/gateway/worktrees_test.exs
  - apps/troupe_core/test/troupe/tools/remember_test.exs
  - clients/tui/test/troupe/workspace_in_another_repository_test.exs
symbols:
  - Troupe.Git.ignored?/1
  - Troupe.Session.Memory.locate/1
  - Troupe.Session.Memory.repository?/1
  - Troupe.Gateway.Worktrees.list/2
  - Troupe.Gateway.Worktrees.resolve/3
  - Troupe.Gateway.Worktrees.named/2
gist: "Ignored folder: own workspace, no worktrees, own brief; tracked: the repository's. worktree.list reads status 2 s, checkout first, else checked false"
---

Issue #650, after #621. A workspace that is a plain directory inside another repository
was that repository everywhere: `worktree.list` listed and looked at every worktree of the
repository around it (in the repository #621 was found in, 199 of them, minutes on
Windows), `session.create` in `auto` or `always` mode made a worktree of the whole
repository *inside* it (`<folder>-<slug>`, an untracked directory in the checkout),
`memory.get` answered the repository's brief, and with `memory_auto_refresh` on a session
started there launched a librarian that rewrote that brief. The desktop app asked
`worktree.list` whether the workspace was a repository, so it waited as long. The
maintainer's rule (2026-10-12): worktrees and the brief follow git.

**The rule.** `Troupe.Git.ignored?/1` asks git (`git check-ignore -q -- .`, through
`Troupe.Git.run/3`, so neutralised and confined as every other call).
- A folder git does not ignore belongs to the repository around it. That is a folder the
  repository tracks, and also one it would add (untracked, not ignored: `git status`
  names it and `git add -A` takes it), because git counts both as its working tree and
  the rule is git's.
- A folder git ignores (`.gitignore`, `info/exclude`, the person's excludes file, or
  inside an ignored folder) is a workspace of its own, as a directory in no repository
  is. The top of a checkout or a worktree is never ignored (git answers `1` for `.`
  there), so a linked worktree that sits in its checkout's ignored `.worktrees/` is still
  the repository's, and a nested repository is its own as before.
- The check runs only for a folder below git's top level, so a workspace at a checkout's
  top pays nothing for it; one below pays one `check-ignore` where it asks where it is.

**Where it holds.**
- *The brief.* `Troupe.Session.Memory.locate/1` (Decision 831's repository root) adds the
  ignored check to its conditions: an ignored folder's brief, facts and anchors are its
  own (`root` and `top` the folder). Decision 831's rule for a forged `.git` stands; this
  adds an ignored folder to its "anything else". `repository?/1` now follows `locate/1`
  (the checkout it names has a `.git`), so `refresh_due` is false there and no librarian
  starts by itself; `/memory refresh` still writes the folder's own brief. It first walks up
  for a `.git` as before and runs no git where there is none, so a home directory costs
  what it did. `Troupe.Memory.Facts` asks it with the location it already has. Onboarding,
  which asks the same `repository?/1`, is due nothing in an ignored folder either, and
  `onboard.apply` refuses there as it does outside a repository. The instruction files are
  not part of this: they are still read up to the nearest `.git`.
- *`memory.get`* gains `repository`, and asks git where the brief is once
  (`locate/1` takes a location in place of a path) rather than once per field. The
  terminal client's start reads `repository: false` as the quiet "not a repository" case;
  without it, `refresh_due: false` on an absent brief read as a librarian held off and said
  so on screen.
- *`worktree.list`* in an ignored folder answers no rows. In a tracked one it answers the
  repository's worktrees, as before.
- *`Worktrees.resolve/3`* in `auto` and `always`: an ignored folder works where it is. A
  tracked folder's new tree is `<checkout>-<slug>` beside the checkout (git's top level),
  never inside it, and the session works in the same folder of the new tree; a folder with
  nothing committed in it yet is made there, empty. `named/2` the same, at
  `<checkout>-<name>`; in an ignored folder or in no repository it is refused with
  `invalid_params`, field `workspace`, saying why, where git's own error was answered
  before. Whether the workspace is busy is still the same directory, not the repository.
- *Which session a tree is.* A row's `session_id` is the session in the tree's directory,
  or failing that one in a folder of it git does not ignore, given to the nearest tree that
  holds it (a checkout that holds its worktrees' directories does not take theirs). A merge,
  a discard and a named tree's reuse are refused while a session works anywhere in the
  tree, its folders included, since sessions now start in them.
- *The desktop app* asks `worktree.list` with `status: false` whether a workspace is a
  repository (`librarianBarred` in `memory.ts`), so it no longer waits on a listing that
  looks at every tree.

**Bounded time: lazy for those that need no status, bounded for those that do.**
- `status: false` answers each row's `path`, `branch` and `session_id` from git's list of
  the trees alone, with no git per tree. The terminal client's `/worktree` placement and
  Tab completion ask it so, and so does the desktop app's repository check.
- Otherwise the status is read as Decision 851 reads it (one `status --porcelain=v2` and one
  `diff --numstat` a tree), but within a budget of two seconds
  (`:worktree_status_ms` in the gateway's application environment, a test's knob), eight
  trees at once, the checkout first, then the trees a session works in, then the rest in
  git's order; the rows go back in git's order. Each git call a tree runs is given only what
  is left of the budget, and none starts after it, so the answer comes in about the budget,
  at worst a few times it when a slow tree was begun just before the end, however many
  trees there are. `list(nil)` shares one budget across every live session's workspace.
- A row says `checked`. One the budget did not reach has `checked: false` with `dirty` and
  every count `null`, never a clean tree's answers; a tree whose status was read but whose
  diff ran out of time has its counts `null` and its `dirty` read. The terminal client draws
  such a row with no state (not `clean`), and the desktop app's worktree table says "Not
  looked at"; its Remove forces only a tree it knows is dirty, and the daemon still refuses
  a dirty one without force.
- Chosen over caching each tree's status (it changes with every edit, so a cache would need
  an index and mtime check per tree, which is most of the cost on Windows), over a fixed
  count of trees (a count bounds nothing when one tree is large), and over a separate
  per-tree status method (both clients would have to fetch row by row; the budget gives the
  rows that matter at once). Not done: a client cannot ask for the rest later; a refresh
  reads the same first trees again.

**Measured**, 201 trees (a checkout and 200 linked worktrees of a one-file repository),
through the daemon's socket. In WSL (Linux) on the chunk's tip: `worktree.list` 33.8 s,
every tree read; with this change 2.7 s with 24 trees read, and 0.16 s with `status: false`
(which the tip ignored, 38.9 s). On Windows, the installed builds on scratch homes: before,
54.7 s at the checkout and 48.5 s in an ignored folder (201 rows each, every tree read);
after, 2.7 to 2.8 s at the checkout or in a tracked folder (about 40 trees read), 0.6 to
0.7 s with `status: false`, and 0.7 s with no rows in the ignored folder. A plain line in
the ignored folder opened `build-1` in 0.75 s.

**Proof.** Each failed on the chunk's tip (8b1b760) first.
- `Troupe.Gateway.EnclosingRepositoryTest`. An ignored folder: `worktree.list` empty with
  and without status; `memory.get`'s path the folder's own, `refresh_due` and
  `repository` false; `session.create` `always` and `auto` in the folder itself, with no
  tree made; a named tree refused. A tracked folder: the repository's trees; its brief;
  `always` makes `outer-<slug>` beside the checkout with the session in `packages/ws` of it;
  a named tree at `outer-login`, whose row names its session. A folder the repository would
  add belongs too, its folder made in the new tree.
- `Troupe.Gateway.WorktreesTest`, "worktree.list answers in bounded time with many
  worktrees": 200 worktrees; `status: false` runs one `worktree list` and no status, diff or
  rev-list; a budget of 0 reads none and every row says `checked: false`; a budget of a
  second answers within ten, the checkout read and clean.
- `Troupe.Tools.RememberTest`, "a folder the repository ignores keeps a brief of its own":
  `locate/1`, `path/1`, `repository?/1`, `refresh_due?/2`, the brief and onboarding notices,
  and a fact written there landing in the folder's own brief.
- The terminal client's `WorkspaceInAnotherRepositoryTest`: in an ignored folder command
  mode and `/worktree` list nothing and no librarian starts or is mentioned (on the tip a
  librarian started on the repository's brief); in a tracked one the repository's trees.
  Its `CommandModeTest`: a row the listing did not reach shows no state, where the tip
  drew it `clean`.
- The desktop app's `memory.test.ts`: the repository check asks `worktree.list` with
  `status: false`.
