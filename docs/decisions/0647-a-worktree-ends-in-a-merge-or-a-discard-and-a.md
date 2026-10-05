---
number: 647
title: A worktree ends in a merge or a discard, and a merge that cannot complete leaves no trace
date: 2026-09-20
status: accepted
paths:
  - apps/troupe_gateway/lib/troupe/gateway/worktrees.ex
  - apps/troupe_gateway/test/troupe/gateway/branches_test.exs
gist: A worktree ends in a merge or a discard, and a merge that cannot complete leaves no trace
---

`worktree.merge` commits whatever the agent left uncommitted (as the
harness, `troupe <troupe@localhost>`, so a machine where nobody told git who they
are still works), merges the branch into the checkout it came from with a merge
commit — `--no-ff`, so the branch stays visible in history as one piece of work —
and removes the worktree and the branch. When git cannot merge it, the merge is
aborted before anything is answered: the checkout is exactly as it was, the
worktree is exactly as it was, and the client gets `conflict` with git's own words,
because a half-applied merge is the one outcome worse than a refused one.
`worktree.discard` removes the tree and deletes the branch, uncommitted work
included, which is what the word means. Both refuse with `conflict` while the
session in that worktree is mid-turn; an idle or finished agent is not consulted,
and its next turn, if any, fails loudly rather than editing files nobody will look
at. Both are `admin`: they change the user's own checkout.
