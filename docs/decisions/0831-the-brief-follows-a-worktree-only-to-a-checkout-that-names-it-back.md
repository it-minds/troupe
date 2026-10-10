---
number: 831
title: The project brief follows a worktree to its main checkout only when that checkout names the worktree back; otherwise it is the workspace's own
date: 2026-10-10
status: accepted
issue: 524
paths:
  - apps/troupe_core/lib/troupe/session/memory.ex
  - apps/troupe_core/test/troupe/tools/remember_test.exs
symbols:
  - Troupe.Session.Memory.path/1
gist: "git's --git-common-dir alone never places the brief: the checkout must hold the workspace or name the worktree back (Config.Trust.root/1)"
---

Decision 649 put the brief at the repository's main checkout, found through
`git rev-parse --git-common-dir`, so a session in a worktree writes the brief the
checkout's sessions read. git takes a `.git` at its word: a workspace's own `.git` file
naming a git directory whose `commondir` gives another checkout's `.git`, a `.git`
directory with such a `commondir` in it, or a `.git` file naming another worktree's
`.git/worktrees/<name>` all make git answer that other checkout's `.git` as the common
directory. The brief was then read
into this session's prompt from there, and `remember` wrote there. A session's agent can
write those files in its own workspace, so where several workspaces sit side by side, one
could read and write another's brief (#524).

- **The rule.** `Troupe.Session.Memory`'s repository root is the checkout git names only
  when the workspace is in that checkout's tree (git's top level, which must hold the
  workspace), and `Troupe.Config.Trust.root/1` of that top level is the checkout: for a
  checkout, itself; for a worktree, the checkout whose `.git/worktrees/<name>/gitdir`
  names the worktree's `.git` back, the check trust and `Troupe.Worktree.main/1`
  (Decision 826) already make. Anything else, the brief is the workspace's own
  `.troupe/memory.md`, as it is for a workspace that is not in git.
- **Why trust's check and not a second one.** Trust, the worktree layers and the brief
  answer the same question, which checkout a worktree belongs to, and a forged `.git`
  should fail all three the same way. The brief keeps asking git as well, so a subdirectory
  of a checkout or of a worktree still finds its repository, a submodule still keeps its
  own brief, and the path is the one git gives, as before.
- **Why the top level must hold the workspace.** git's top level can come from
  configuration: where the other checkout has `extensions.worktreeConfig` on, a forged
  git directory's own `config.worktree` sets `core.worktree` to that checkout, and git
  then answers it as both the top level and, through `commondir`, the common directory,
  which trust's check alone would accept. A top level that is not the workspace or above
  it is not where the session works.
- **Not done here.** The other git calls the brief makes (the HEAD and file count it is
  stamped with) still run in the workspace with whatever `.git` it has.
- **Proof:** `Troupe.Tools.RememberTest` — four workspaces, each with one of the forged
  `.git`s above (the fourth with `config.worktree`) and git answering the other
  checkout's `.git` as their common directory, read no brief, write and forget their own,
  and leave the other checkout's as it was. The test failed on the chunk's tip with the
  other checkout's path, and the fourth fails again with the top-level check taken out. A
  real `git worktree`, and a subdirectory of it or of its checkout, still share the
  checkout's brief.
