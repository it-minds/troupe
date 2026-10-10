---
number: 840
title: worktree.list says how each worktree stands against the checkout, the commits ahead and behind and the lines it would bring, untracked files included
date: 2026-10-10
status: accepted
issue: 502
paths:
  - apps/troupe_gateway/lib/troupe/gateway/worktrees.ex
  - apps/troupe_gateway/test/troupe/gateway/worktrees_test.exs
symbols:
  - Troupe.Gateway.Worktrees.list/1
gist: "worktree.list rows carry ahead/behind (vs the checkout's branch; the checkout vs its upstream) and added/removed since the branch left, untracked counted"
---

Issue #502's command mode (TUI Decision 155) lists, per worktree, its branch, how far it is
ahead of and behind, `+n −m`, whether it is dirty and whether its session is alive.
`worktree.list` answered the path, branch, live session and dirty bit; no event carries the
rest, and a client cannot run git against a pod's tree or, without Decision 833's
neutralised git, against a repository's own `.git`. So the daemon, which has the trees and
the confined git, says it, additively, on the call the clients already make.

- **Against what.** git lists the main worktree first; its branch is the one the others
  left. A linked worktree's `ahead` and `behind` are `git rev-list --left-right --count
  <checkout's branch>...HEAD`; its `added` and `removed` are `git diff --numstat` against
  the merge base of the two, so its commits and what it has not committed count alike,
  plus the lines of its untracked files: that is what `worktree.merge` would land, since it
  commits with `add -A` first (Decision 647). The checkout's own row is against its
  upstream (`@{upstream}...HEAD`) and its uncommitted changes against `HEAD`. Each is `null`
  where git cannot say: a checkout with no upstream, a detached main worktree.
- **Bounded.** One `git status --porcelain --untracked-files=all` per tree replaces the
  dirty check and names the untracked files; each is read only while it is a regular file
  inside the tree of at most 1 MB and valid UTF-8, the first 200 of them, and a name git
  had to quote is left out rather than unquoted here. A binary file in `--numstat` (`-`)
  counts no lines. Every call is `Troupe.Git.run/3`, so none runs what the repository's
  `.git` names.
- **When.** Only when asked: the terminal client asks at a screen's start and when an
  event says a tree may have moved, never on a timer.

Proof: `worktrees_test.exs`, "worktree.list says how far each worktree stands from the
checkout, and what it changed": a worktree one commit ahead and one behind, with a change on
top of its commit and a new two-line file, reads `ahead 1, behind 1, added 4, removed 1`,
dirty; the clean checkout with no upstream reads `null` for both counts and `0` lines. The
same file's "a repository whose own .git runs commands" lists through the new calls and its
marker stays unwritten. The terminal client's `command_mode_test.exs` draws a worktree's row
from it.
