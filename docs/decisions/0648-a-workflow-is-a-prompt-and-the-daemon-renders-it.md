---
number: 648
title: A workflow is a prompt, and the daemon renders it
date: 2026-09-20
status: accepted
paths:
  - apps/troupe_gateway/test/troupe/gateway/workflows_test.exs
  - clients/tui/lib/troupe/client/daemon.ex
gist: A workflow is a prompt, and the daemon renders it
---

`Troupe.Workflow` is a named
step list from `.troupe/workflows/<name>.json` (or a built-in six-step pipeline),
rendered around the task into the plan an orchestrating `workflow` agent starts
from — an agent that cannot write, edit or run, and delegates each step to
`explore`, `implementer` or `reviewer`. It needs the step list read where the
workspace is and the three agents to exist, and nothing else: the definitions are
built-ins (`workflow` a primary the daemon offers in `agents.list`, the other two
subagents `delegate` can name), and `session.create` takes `workflow`: the daemon
loads the steps from the workspace the client named — not the worktree the session
may get — renders the plan, and starts the `workflow` profile on it.
`workflows.list` says which names a workspace has, so a client can complete them.
Running a workflow is therefore starting a session, which is what makes worktrees,
approvals, budgets and dormancy apply to it without a line written for the purpose;
a client that wants the result reviewable asks for `worktree: "always"` and ends it
with `worktree.merge` or `worktree.discard`.
