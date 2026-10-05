---
number: 42
title: "`/worktree <name>: <prompt>` works in a Troupe-managed worktree of that name, created on first use and reused afterwards (`.troupe/worktrees/<name>` on `troupe/<name>`), and `Worktree.create/2` is idempotent: it reuses a registered worktree and re-adds one whose directory was removed but whose branch survived"
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: "`/worktree <name>: <prompt>` works in a Troupe-managed worktree of that name, created on first use and reused afterwards…"
---

The trailing colon is what separates a name from prompt text — an unmarked first word stays prompt text (Decision 39), so `/worktree fix the login bug` cannot silently create a worktree called `fix`. A name in use by a still-active branch is refused rather than letting two agents write the same tree, `/merge` and `/discard` act on the name, and `/worktree <Tab>` offers the managed names with their colon.
