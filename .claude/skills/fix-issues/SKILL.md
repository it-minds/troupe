---
name: fix-issues
description: Work through the open GitHub issues in it-minds/troupe one at a time - triage them, agree a queue, then hand each to the issue-fixer agent in its own worktree, which fixes, installs locally with scripts/install-local.ps1, verifies with scripts/verify-local.ps1 and opens a PR. Use when asked to fix the GitHub issues, run the issue suite, or continue it. Args - optional issue numbers ("53 57"), or "triage" to stop after the triage table.
disable-model-invocation: true
---

# Fix the open issues, one by one

You are the orchestrator. You do not write fixes yourself: you triage, keep the queue,
spawn one `issue-fixer` at a time, read its report, and keep the user informed. GitHub is
the ledger - an issue with an open PR is in progress, a merged one is done - so a run can
stop anywhere and the next run picks up from what GitHub says.

## Why one at a time

`install-local.ps1` installs to one place per machine (`%LOCALAPPDATA%\Programs\troupe*`)
and stops the running daemon. Two fixers verifying at once would test each other's
builds. Triage is read-only and can fan out; fixing and verifying are strictly serial.

## 1. Build the queue

1. `gh issue list --repo it-minds/troupe --state open --limit 100 --json number,title,labels,assignees,body`
   (or just the numbers passed as args).
2. Drop issues that already have an open PR
   (`gh pr list --repo it-minds/troupe --state open --json number,title,body,headRefName`
   and match `#N` in the body or `N` in the branch name) and issues assigned to someone else.
3. Triage each remaining issue. For more than ~5 issues, spawn read-only `Explore`
   agents in parallel (one per 3-4 issues) to locate the code each one touches; otherwise
   do it directly. For each issue record:
   - **area**: daemon/core, tui, server, gui, docs, release/ci, cross-cutting
   - **size**: `bug` (a defect with a reproduction), `small` (a contained change, one PR),
     `epic` (several PRs, or needs design/product decisions)
   - **verification** it will get, from the table in the issue-fixer agent
   - for an epic: the smallest first slice that is useful on its own and needs no
     undecided product question, or "none without a decision: <the question>"
4. Order: `bug` first (user-facing before internal), then `small`, then epic slices.
   Within a group, prefer what the local install can actually verify (daemon, TUI) over
   what it cannot (GUI Tauri shell, cluster-only server paths).

## 2. Agree the queue - once, before any fixing

Show the triage as one table: `# | title | area | size | plan | verification`. Then ask
with AskUserQuestion (multi-select where it fits):

- which bugs/small issues to run (default: all of them)
- which epic slices to run, each named by its slice, not the epic title
- any `needs-decision` questions surfaced during triage

This approval is what authorises pushing branches and opening PRs for the chosen issues
in this run. It does not extend to issues added later or to merging anything. If args
were `triage`, stop after showing the table.

## 3. Run the queue

Before the first fixer, check the toolchain once
(`$env:LOCALAPPDATA\Programs\erlang\bin\erl.exe` and `...\elixir\bin\mix.ps1` exist); if
not, tell the user to run `scripts\setup-windows-toolchain.ps1` and stop. Also check that
`scripts\verify-local.ps1` is on `origin/main`: fixers branch from there, so without it
they have no smoke test.

For each issue, in order:

1. Spawn `issue-fixer` with `isolation: "worktree"`, `run_in_background: false` (the
   next one cannot start until this one's install is settled). The prompt carries: the
   issue number and title, the triage row, the slice for an epic, and anything the user
   said about it when approving.
2. Read the report. Post a one-line progress note to the user: `#N -> <status> <pr url>`.
3. By status:
   - `pr-opened`: next issue.
   - `needs-decision`: collect it; next issue. Ask all collected decisions together at
     the end, not mid-run, unless the rest of the queue depends on it.
   - `cannot-reproduce`, `too-large`, `duplicate`: note it; next issue.
   - `verify-failed`: confirm `install-state` is `rolled-back` (run
     `.\scripts\install-local.ps1 -Rollback` yourself if not), note it, next issue. Two
     `verify-failed` in a row means something is wrong with the machine or the toolchain,
     not the issues: stop the run and report.
4. `noticed` items: collect them. Do not file issues without asking.
5. `learned` items: save genuinely new traps to memory (update the matching memory file,
   e.g. `troupe-build-from-source-windows.md`, rather than adding a duplicate).

Never merge a PR, never approve one, never close an issue, never force-push.

## 4. Finish

One summary table: `# | status | PR | verified | not verified`. Then the collected
decisions (AskUserQuestion, recommendation first), and the `noticed` list with an offer
to file them. End by stating the install state of the machine: which build is installed
now and that `.\scripts\install-local.ps1 -Rollback` goes back one step. The last
fixer's build stays installed; a later fix on the same area should be rebuilt from main
once its PR merges.
