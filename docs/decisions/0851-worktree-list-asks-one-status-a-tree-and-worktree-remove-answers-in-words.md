---
number: 851
title: worktree.list asks each tree one `git status --porcelain=v2 --branch`, the checkout's branch its upstream for that call, worktree.remove answers a git that refused as merge and discard do, and read_branch says when no branch has finished
date: 2026-10-11
status: accepted
issue: 502
supersedes: [840]
paths:
  - apps/troupe_gateway/lib/troupe/gateway/worktrees.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/test/troupe/gateway/worktrees_test.exs
  - apps/troupe_core/lib/troupe/tools/read_branch.ex
  - apps/troupe_core/test/troupe/tools/read_branch_test.exs
symbols:
  - Troupe.Gateway.Worktrees.list/1
  - Troupe.Gateway.Worktrees.remove/2
  - Troupe.Tools.ReadBranch
gist: "worktree.list: one status v2 a tree (checkout's branch as upstream, checked, rev-list fallback) + one diff --merge-base; remove's git refusal is internal_error"
---

D113 and D105 in `docs/developer/defects.md` (#502's command mode). Three answers of the
daemon's change; Decision 840's numbers do not. This replaces the calls 840's "Bounded"
names, and nothing else of it.

- **`worktree.list`, one status a tree.** A linked tree took four git calls (`status`,
  `rev-list --left-right --count`, `merge-base`, `diff --numstat`) and the checkout three,
  each of them two or three processes through `Troupe.Git` (Decision 833). Now one
  `git status --porcelain=v2 --branch --ahead-behind --untracked-files=all` says whether
  the tree is dirty, names its untracked files (`? path`, a quoted name still left out),
  and gives `# branch.ab`: for the checkout against its upstream, as before; for a linked
  tree against the checkout's branch, which is its upstream for that one call
  (`-c branch.<name>.remote=. -c branch.<name>.merge=refs/heads/<checkout's>`, git's own
  way of tracking a local branch). The count is taken only when `# branch.upstream` names
  the checkout's branch: a branch with an upstream of its own keeps it (git adds a merge
  ref from `-c`, it does not replace one), and a detached tree or a branch whose name has a
  `=` (which `-c` would split) gets none, so those are counted with `rev-list` as before.
  The lines are one `git diff --numstat --merge-base <checkout's branch>` (git 2.30;
  `Troupe.Git` already needs 2.31), the same diff the `merge-base` call fed. So two calls a
  tree, a third only in those cases.
- **`worktree.remove`'s answers.** git's refusal (a directory that is no working tree,
  one git cannot delete) was `invalid_params` with `inspect` of git's words, quotes and
  all; it is `internal_error` with git's words, as `worktree.merge` and
  `worktree.discard` answer theirs. A path that is not there is `not_found` (`kind:
  worktree`), as theirs is, not `invalid_params` `":not_found"`; a git that did not run is
  `internal_error` in `Troupe.Git.explain/1`'s words. The refusal of a dirty tree is
  `conflict`, as it was.
- **`read_branch` with none finished.** Its listing gave each branch's state and nothing
  more, which `/ask`, a branch asked before any other had finished, read as though one had.
  A listing in which none has finished ends `None of them has finished yet, so there is no
  summary to read.`

Not done here: `worktree.merge` and `worktree.discard` still answer a git that did not run
(`Troupe.Git`'s reasons) as `invalid_params` with an inspected term, through the same
fallback `session.create` uses for a worktree it cannot make.

Proof: `worktrees_test.exs`, failing on the chunk's tip (f74b3c6) first: "worktree.list
says how far each worktree stands" records every git it starts through a stand-in on PATH
and finds two `status --porcelain=v2 --branch`, no other status and no `rev-list` or
`merge-base` call, with the numbers unchanged (ahead 1, behind 1, added 4, removed 1, and
the checkout's `nil`s), and the same numbers once the tree's branch has an upstream of its
own; "worktree.remove answers git's refusal as an internal error in git's words" (on the
tip `invalid_params` with `"\"fatal: ... is not a working tree\""`), and `not_found` for a
path that is not there. `read_branch_test.exs`: the listing says none has finished, for a
parent and for `/ask`'s sibling listing, and stops saying it once one has.
