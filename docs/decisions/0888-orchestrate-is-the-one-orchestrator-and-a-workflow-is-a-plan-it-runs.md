---
number: 888
title: orchestrate is the one agent that orchestrates, a workflow is a plan it is started on, and the live bench compares it with build on the same tasks
date: 2026-10-12
status: accepted
issue: 554
supersedes: [850]
paths:
  - apps/troupe_core/priv/agents/orchestrate.md
  - apps/troupe_core/lib/troupe/workflow.ex
  - apps/troupe_core/lib/troupe/commands.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_core/lib/troupe/bench/live_scenarios.ex
  - apps/troupe_core/test/troupe/workflow_test.exs
  - apps/troupe_gateway/test/troupe/gateway/workflows_test.exs
  - apps/troupe_core/test/troupe/bench_live_test.exs
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/README.md
  - PROTOCOL.md
symbols:
  - Troupe.Workflow.agent/0
  - Troupe.Workflow.agent/1
gist: "No workflow agent: a workflow runs on orchestrate (profile workflow too); /workflow is a built-in; build vs orchestrate live pairs; build stays default"
---

Issue #554, slice 4, and the comment on it, "The pipeline already exists — reconcile before
building `orchestrate`". Decision 850 kept two profiles: `workflow` for a repository's
declared step list, `orchestrate` for work nobody wrote one for, sharing the brief, the
finish and the gate. On the chunk's tip that was two orchestrators for one job.

**What each did.** On one multi-file task against the fake provider (a function renamed in
two files, the same script for both), `orchestrate` on the person's words and `workflow` on
the rendered default plan delegated the same two parts (`implementer`, then `reviewer`) and
left the same files. Their definitions differed in one tool (`git_read`, which only
`orchestrate` had), and both denied `write_file`, `edit_file` and `shell`. Every rule the
contract has was said by both instructions: the brief's five parts, two subagents never
writing one file, judging a finish by what passed and what is unverified, a `reviewer` for
the check, briefing a failed part again with the failure quoted, `remember` once,
`ask_user` only for the person's decision. The `workflow` agent's `max_turns: 200` did
nothing, since a definition's cap only ever lowers the session's (40 by default), and
`budget_share` applies only to an agent that is delegated to, which neither was. What was
left was `model: expensive` and a paragraph on reading the plan.

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

`fix_test_orchestrate`, `rename_symbol_orchestrate` and `follow_steps_orchestrate` are the
three tasks as their pairs have them, prompt, files, outcome and checks, with
`orchestrate` as the session's agent and a check that the root called `delegate`; run by
name, in no suite. A run's cost, calls and tokens are its whole tree's. They have 600 s of
wall clock rather than 240, since subagents run one after another on shares of the
root's.

**Live**, on the installed build of this change, Claude Sonnet 5.5 ($2 in, $10 out, $0.20
a cache read, $2.50 a cache write per million), on Windows, 2026-10-12, five runs of each
scenario, a pair a bench. Medians; tokens are fresh (sent uncached or written to the cache)
/ read from the cache / output.

| task | agent | runs that succeeded | cost | model calls | wall clock | tokens |
|---|---|---:|---:|---:|---:|---|
| `fix_test` (one file) | `build` | 5 of 5 | $0.0107 | 3 | 5.0 s | 1,448 / 19,892 / 311 |
| | `orchestrate` | 5 of 5 | $0.0268 | 6 | 12.5 s | 3,754 / 36,909 / 1,052 |
| `rename_symbol` (three files) | `build` | 5 of 5 | $0.0095 | 3 | 4.6 s | 1,284 / 19,880 / 233 |
| | `orchestrate` | 5 of 5 | $0.0279 | 6 | 12.7 s | 4,194 / 37,267 / 1,014 |
| `follow_steps` (three steps, two files) | `build` | 5 of 5 | $0.0126 | 4 | 7.5 s | 1,394 / 26,601 / 381 |
| | `orchestrate` | 5 of 5 | $0.0389 | 10 | 18.3 s | 4,485 / 63,551 / 1,554 |

- **The same outcome at two and a half to three times the cost.** Every run of both agents
  got the work done and held every check. `orchestrate` cost 2.5, 2.9 and 3.1 times what
  `build` did, made twice the model calls (2.5 times on `follow_steps`), and took 2.4 to
  2.8 times as long.
- **How it spent it.** In all fifteen runs the root looked first (`read_file`, or `grep`
  for the rename), delegated the whole change once (to `general` nine times, `implementer`
  six) and answered from the finish; on `follow_steps` it also read the files back before
  answering, and in four runs of five wrote a task list first. None briefed a `reviewer` or an `explore`, which these
  tasks give little reason to. The root's own calls were about half the cost: it reads what
  the subagent then reads again, and each subagent starts on a prompt of its own.
- **So `build` stays the default and `orchestrate` is suggested nowhere.** On these tasks
  it buys nothing a person can see. What the bench does not have is a task large enough
  that `build`'s own context grows past what a few briefs cost, or one where a reviewer
  catches what the writer missed; every task here takes `build` three or four calls.
- A first bench of the `rename_symbol` pair, three runs each, gave the same: $0.0096
  against $0.0344 at the median, all six succeeded. Spent in all: $0.80 of the slot's $3,
  36 runs. To run it again:
  `troupe bench --live --scenario rename_symbol,rename_symbol_orchestrate --repeat 5 --model claude-sonnet-5-5`,
  and the same for the other two pairs.

## Which to use

`build` for a change you would make yourself, which on the bench is every one of them;
`/workflow` when a repository has written down the steps a change goes through (a release,
a migration) and wants each owned by a subagent, with a reviewer at the end, in a worktree
of its own; `orchestrate` on your own words when you want that shape without a declared
list, knowing that on small tasks it costs about three times as much. The terminal
client's README says the same, with these numbers.

## Proof

Each failed on the chunk's tip, `d2ae42f`, eight in all: `Troupe.WorkflowTest` (the runner
is `orchestrate` on the expensive model with the task list's tools; there is no `workflow`
agent and `orchestrate`'s instruction reads a workflow; `agent/1` for no profile, the old
name and another), `Troupe.Agent.DefinitionTest` (the primaries; `orchestrate` reads a
workflow and is `expensive`), `Troupe.CommandsTest` (`/workflow` is a built-in in the agents
section) and `Troupe.Gateway.WorkflowsTest` (over the daemon's socket: `session.create` with
a workflow runs `orchestrate` on the plan and it delegates; a client naming `workflow` gets
`orchestrate`, one naming its own agent runs that). `Troupe.BenchLiveTest` holds the three
pairs to their tasks and to no suite, runs `rename_symbol_orchestrate` against the stand-in
(the root's two calls and the implementer's three in the record, and the cost all five's),
and scores nothing when the root edits instead of delegating. The terminal client's
`BranchClientTest` starts `/workflow` on `orchestrate`, and its palette test keeps
`/workflow` among the built-ins. On the installed build with scratch homes, the daemon
lists no `workflow` agent, its command table has `/workflow` as a built-in, and
`session.create` with `workflow: "default"`, with no profile and with `workflow`, runs
`orchestrate` on the plan.
