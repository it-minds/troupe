---
number: 44
title: "Every agent's system prompt opens with a workspace survey: what kind of project this is and which files it holds"
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: "Every agent's system prompt opens with a workspace survey: what kind of project this is and which files it holds"
---

`Troupe.Workspace.Survey` runs once per agent at `init` (after the worktree exists, so the survey describes the tree the agent actually works in) and reports the VCS and branch, the project markers it found up to depth 2 with their package names, the language mix by file count, and the file list itself — falling back to per-directory file counts when the listing would exceed ~4 KB. The file list comes from `git ls-files --cached --others --exclude-standard` in a repo (so gitignored build output is absent for free) and from a pruned filesystem walk otherwise, capped at 20 000 paths either way. It is a derived snapshot, never an event and never persisted: replay does not depend on it, and it is deliberately built once rather than per turn so the system prompt stays byte-stable across a conversation and the provider's prompt cache keeps hitting. The point is the first question — an agent that already knows it is holding an Elixir/Mix project with `lib/troupe/session/` in it does not spend a turn discovering that.
