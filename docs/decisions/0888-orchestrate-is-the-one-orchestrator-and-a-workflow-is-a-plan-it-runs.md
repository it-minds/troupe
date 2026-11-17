---
number: 888
title: orchestrate is the one agent that orchestrates, a workflow is a plan it is started on, and the live bench compares it with build on the same tasks
date: 2026-10-12
status: accepted
issue: 554
supersedes: [850]
paths:
  - apps/troupe_core/lib/troupe/workflow.ex
  - apps/troupe_core/lib/troupe/commands.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_core/lib/troupe/bench/live_scenarios.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
symbols:
  - Troupe.Workflow.agent/0
  - Troupe.Workflow.agent/1
gist: "No workflow agent: a workflow runs on orchestrate (profile workflow too); /workflow is a built-in; build vs orchestrate live pairs; build stays default"
---

## The decision

- **One agent orchestrates: `orchestrate`.** The `workflow` built-in is gone. `orchestrate`
  takes its model, `expensive`, which is the default model unless a person names a dearer
  one (`models.expensive`), so nothing changes for anyone who has not, and its paragraph:
  a prompt that is a numbered step list is a workflow, the steps are the plan, `[you]` is
  its own step, `parallel` steps may go out together, and no step, least of all a test or
  verify step, is dropped without saying why. The rendered plan says the rest, as it did.
- **A workflow is a plan `orchestrate` is started on.** `Troupe.Workflow.agent/0` names
  the runner, and `session.create` with `workflow` starts it on `Troupe.Workflow.plan/2`'s
  prompt. A client that names `profile: "workflow"`, the old runner's name, gets
  `orchestrate` (`Troupe.Workflow.agent/1`); one that names another agent runs the plan
  there, as before. Worktrees, approvals, budgets and resume apply unchanged, since running
  a workflow is still starting a session (Decision 648).
- **`/workflow` is a built-in command** in the harness's table and the terminal client's,
  since no agent row carries it any more; the terminal starts the branch on `orchestrate`,
  in a worktree of its own, its window still `workflow-<n>`. The desktop app starts no
  branch and lists it as one it cannot run.
- **What this replaces.** Decision 850's choice of two profiles (the rest of 850 stands),
  TUI Decision 87's "the `workflow` agent" (its reasoning holds for `orchestrate`: an
  expensive orchestrator that cannot write and owns only the decisions), and TUI Decision
  104's "the `workflow` agent's first input" (now `orchestrate`'s).
- **Not chosen.** Two profiles with a stated boundary: the step list was the only thing the
  `workflow` agent had that `orchestrate` did not, and a list is data the plan renders, not
  a second agent to keep in step. `workflow` as the name of the one agent: `orchestrate` is
  the name #554 and Decision 850 gave the profile people choose, and `workflow` names the
  plan. `orchestrate` handing a multi-step task to a workflow through a tool: a second
  session for what a task list already does.
- **A repository's own `.troupe/agents/workflow.md`** is an ordinary primary now, which
  `/workflow` does not run; one that changed how workflows run copies `orchestrate.md`
  instead.

## The bench

- **The same outcome at two and a half to three times the cost.** Every run of both agents
  got the work done and held every check. `orchestrate` cost 2.5, 2.9 and 3.1 times what
  `build` did, made twice the model calls (2.5 times on `follow_steps`), and took 2.4 to
  2.8 times as long.
- **So `build` stays the default and `orchestrate` is suggested nowhere.** On these tasks
  it buys nothing a person can see. What the bench does not have is a task large enough
  that `build`'s own context grows past what a few briefs cost, or one where a reviewer
  catches what the writer missed; every task here takes `build` three or four calls.

## Which to use

`build` for a change you would make yourself, which on the bench is every one of them;
`/workflow` when a repository has written down the steps a change goes through (a release,
a migration) and wants each owned by a subagent, with a reviewer at the end, in a worktree
of its own; `orchestrate` on your own words when you want that shape without a declared
list, knowing that on small tasks it costs about three times as much. The terminal
client's README says the same, with these numbers.
