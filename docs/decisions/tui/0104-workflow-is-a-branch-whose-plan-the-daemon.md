---
number: 104
title: "`/workflow` is a branch whose plan the daemon writes"
date: 2026-09-20
status: accepted
paths:
  - apps/troupe_core/lib/troupe/workflow.ex
gist: "`/workflow` is a branch whose plan the daemon writes"
---

The harness's `Troupe.Workflow` moved into the core (troupe-remote Decision 648), so the TUI keeps only the spelling: `/workflow release: cut 1.2` or `/workflow release cut 1.2` names one of the workspace's workflows (`workflows.list`), anything else is the default pipeline with the whole line as the task. The branch is created with `workflow: <name>` and `worktree: "always"` — a workflow's subagents write, so it never shares the checkout — and the daemon renders the step list around the task as the `workflow` agent's first input. Everything else is Decision 103: the window is `workflow-1`, the transcript arrives under that name, and `/merge` lands what the subagents wrote.
