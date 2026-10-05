---
number: 39
title: "`/worktree <existing> <prompt>` runs in a worktree the user already checked out (`git worktree list`, matched by relative path or branch) instead of creating one, and `/worktree <Tab>` completes those names"
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: "`/worktree <existing> <prompt>` runs in a worktree the user already checked out (`git worktree list`, matched by relative path or branch) instead…"
---

In a user-managed worktree Troupe never commits: the window shows `git diff --stat` on finish and `/merge` / `/discard` are refused because the branch is the user's; an unmatched first word is simply part of the prompt.
