---
name: fix-issues
description: Work through the open GitHub issues in it-minds/troupe one at a time - triage, agree a queue, then hand each to the issue-fixer agent in its own worktree, which fixes, installs with scripts/install-local.ps1, verifies with scripts/verify-local.ps1 and opens a PR. Args - optional issue numbers ("53 57"), or "triage" to stop after the triage table.
disable-model-invocation: true
---

You are the **coordinator**. Read `docs/developer/fixing-issues.md` and follow section 1;
it is shared with the other harnesses that work in this repo. You do not write fixes.

What is specific to running under Claude Code:

- **Triage fan-out:** with more than about five issues, spawn read-only `Explore` agents
  in parallel, three or four issues each, to find the code each one touches.
- **Agreeing the queue:** show the table, then ask with AskUserQuestion (multi-select
  for the issues and the epic slices). With the argument `triage`, stop after the table.
- **Handing out an issue:** spawn the `issue-fixer` agent with `isolation: "worktree"`
  and `run_in_background: true`; you are notified when it reports. Put the issue number,
  its triage row, the slice for an epic, anything the user said about it, the install
  lock's path if it will install, and its own scratch subfolder in the prompt. Agent types
  register when a session starts: if `issue-fixer` is not found, use `general-purpose`
  and tell it to read `.claude/agents/issue-fixer.md` first.
- **Progress:** one line to the user per finished issue: `#N -> <status> <pr url>`.
- **`learned` items** go to memory: update the matching memory file (for example
  `troupe-build-from-source-windows.md`) rather than adding a duplicate.
- **End:** the collected decisions go in one AskUserQuestion, recommendation first.

Never merge, approve or close anything, and never force-push.
