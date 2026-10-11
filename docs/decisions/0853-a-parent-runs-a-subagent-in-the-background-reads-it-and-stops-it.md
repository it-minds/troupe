---
number: 853
title: A parent starts a subagent in the background with delegate's wait false, reads it while it runs through read_branch's child, and stops it with stop_child, and each background subagent's end reaches its parent once, before its next model call or as its next turn
date: 2026-10-11
status: accepted
issue: 554
paths:
  - apps/troupe_core/lib/troupe/tools/delegate.ex
  - apps/troupe_core/lib/troupe/tools/stop_child.ex
  - apps/troupe_core/lib/troupe/tools/read_branch.ex
  - apps/troupe_core/lib/troupe/tools/finish.ex
  - apps/troupe_core/lib/troupe/agent/background.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/agent/spend.ex
  - apps/troupe_core/lib/troupe/agent/definition.ex
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe/tool.ex
  - apps/troupe_core/priv/bench/budgets.json
  - apps/troupe_core/lib/troupe/sessions/index.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - PROTOCOL.md
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/gui/packages/client/src/transcript.ts
  - clients/gui/apps/desktop/src/views/Session.tsx
symbols:
  - Troupe.Tools.StopChild
  - Troupe.Agent.Background
gist: "delegate wait false: child runs in the background, its end reaches the parent once as a subagent user_input; read_branch child reads it; stop_child stops it"
---

Issue #554, the part the maintainer settled on 2026-10-11: a parent can see a running
child's state (its turn, its last line, its cost, the tool in flight) and stop it, the stop
recorded in both logs and the child's `finish`-less end reported to the parent as stopped.
A parent waited inside its `delegate` call until every child of its turn had ended, so it
could call no tool while one ran, and mid-run control needs a parent that keeps working.
Decision 847's brief and finish and Decision 850's gate are unchanged; this builds on them.

- **Background is asked for, per call.** `delegate` takes `wait`, `true` when left out: a
  delegation runs as it always did, and its finish is the call's result. With `wait:
  false` the child starts the same way (the gate first when it asks, Decision 850; its path,
  its budget share, its depth), and the call answers at once with the child's path and how
  to read, stop and wait for it. `delegation_started` says `wait: false`. Not a separate
  tool, so the brief's shape and the gate stay one; not the default, since a parent that
  needs the answer before its next step is the common case and waiting is what it wants.
- **Its end reaches the parent once.** Whatever ends a background child (its finish, an
  end cut short, a stop, a cancel, a failure past its restart limit, its parent's restart),
  the parent's model is handed one message about it: a line saying which child it was and
  how it ended, then the report in Decision 847's parts. It goes in before the parent's
  next model call, where a person's own command goes (Decision 813), so a parent at work
  reads it at its next step rather than when its run ends; a resting parent takes it as
  its next turn; a run that ends with one still held takes it as its next turn at once,
  after any input that waited for the run to end. After a person's cancel, or a turn the
  harness ended, it waits for the next input, which is what those mean. It is written as a `user_input`
  from `subagent`, with `child_path` and `ended` (`finished`, `cut_short`, `stopped`,
  `cancelled`, `interrupted`, `failed`): a replay rebuilds the conversation from it with no
  new fold, and the clients already tell a harness's words from a person's by `source`. It
  is also the record that the end was handed over, so a restart holds again only the ends
  without one, and closes as `interrupted` a child its restart took down (its Node goes
  with its parent's, as a waited-for child's does, Decision 693). Not postponed like input:
  that is delivered when the parent rests, and a parent working through a long run would
  read its child's end only after it.
- **Waiting is resting.** An agent that ends its turn while a background child runs rests
  until an end arrives, a subagent too, which never rested before: replying in text is
  otherwise its finish. A subagent's rest is no end of its task: its `turn_ended` says
  `waiting` and carries no `turn`, and what it spends before and after is one sum, handed
  to its parent with its finish (a root's rest ends a run and its sum, as always).
  `finish` is refused while one runs, naming it: a finish is the
  whole report, and the agent's parent stops it on receipt, which would cut off what still
  ran with nothing written. An agent that ends any other way (its budget, a failed request,
  a refusal) stops what it still runs, each recorded as stopped by its parent.
- **Reading is `read_branch`'s `child`.** It read a finished subagent (Decision 847); a
  running one now answers with what it is doing: its goal, its turn (the model calls it has
  made), the tools in flight and for how long, or that it waits on its model, its last line,
  what it has cost so far (its model calls and those of every agent under it, off the log,
  `Troupe.Agent.Spend.of/2`) and the subagents running under it. Off the log, as the rest of
  `read_branch`: it reads the same whoever asks, a grandchild included, and costs the child
  nothing. Not a new tool: the call to read a child was already there.
- **Stopping is `stop_child`.** It stops one of the caller's own background children, by
  path or by its last part. The parent ends the child's Node, which takes its model call,
  its tasks and its own subagents with it (supervision, as a cancel does), closes its log
  and every log under it (each open call `stopped`, `agent_done` with reason `stopped`,
  the child's with `by`, the parent's path, and a report: what it last said, Decision
  847's `changed` counted from its writes so far, `unverified` "all of it"), charges what
  the log says it spent, and holds its end like any other. The call answers that it
  stopped it; the report is the next message. The parent's log has the call, the child's
  the `agent_done`. The `delegate` already answered, so this is neither a denial nor a
  failure of the parent's. A sibling runs on: each child is a Node of its own. Only the
  caller's own background children: a waited-for one blocks its parent, which cannot call
  a tool until it ends, and another agent's child is that agent's to stop. The parent
  closes the log rather than asking the child to stop itself: it is synchronous, cannot
  race a child restarting, and is how a restart closes a child already (Decision 693). What
  that costs: the model call in flight when the child is stopped is not counted, as for a
  child a cancel ends (D65).
- **`stop_child` goes with `delegate`.** A definition whose tool list names `delegate` holds
  `stop_child` too (`Troupe.Agent.Definition.allows_tool?/2`): starting a subagent and
  stopping one are one capability, and a repository's own definition that lists `delegate`
  need not learn a new name. Its permission, `stop_child: deny` or `ask`, still applies.
- **A person's cancel stops them too**, each `agent_done` `cancelled`, and their ends reach
  the parent with the next input. A cancel while the agent rests stops them as well: they
  are all it has in flight.
- **A session at rest with a child at work is not asleep.** The sessions index puts a
  session whose root is at rest to sleep after `detached_idle_ms` (two minutes) once nobody
  watches it, and a sleep stops the tree. A root that rests while a background child works
  is now busy to it, as a root waiting on a waited-for child always was, until no subagent
  is at work. The probe runs in the sweep's task, as Decision 848 has every probe do.
- **The depth cap and the budget shares are unchanged.** A background child takes its slice
  when it starts, as a waited-for one does, and the parent's budget is charged when it ends.
  Meanwhile the parent may spend what the slice was cut from, as parallel delegations
  already could; the overshoot is bounded by the shares of the children still running.
- **The clients.** A background child shows as any delegation does, its line saying it runs
  in the background; its live state is its `agent_state`, as any child's; its stop says
  "stopped by its parent"; the end handed to the parent is a line, not a person's words. The
  TUI's translation and the desktop app's fold do it, so the headless printer and every
  window follow.
- **The bench, and two budgets raised.** `stop_child` and `wait` are tool definitions
  `build` is sent on every call: 303 bytes, `stop_child` 228 of them and `wait` 75;
  `read_branch`'s description and its `child` changed by nothing in sum. The budgets are
  held by `Troupe.BenchTest`, in the test build, which also registers four tools of the
  tests' own, and there the tool definitions went from 13,337 to 13,640 bytes of 13,500 and
  the first prompt from 14,852 to 15,155 of 15,000. Both budgets are raised by 300, to
  13,800 and 15,300, which keeps the room they had; the input over the turn, 178,703 tokens
  of 180,000, and the rest hold. (`mix troupe.bench` in the build that ships, without those
  four, measures 13,058 and 14,573.) Folding the stop into `read_branch` instead would have
  fitted in fewer bytes, but a call that ends processes would have hidden behind a read's
  name and its permission, and `wait` needs its line for a model to use it.
- **Proof:** `Troupe.Agent.BackgroundDelegationTest`, whose first test failed on the chunk's
  tip (`5636f38`: the root's second model call came after its child's `agent_done`).
