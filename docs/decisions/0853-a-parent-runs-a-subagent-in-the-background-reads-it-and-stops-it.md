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
symbols:
  - Troupe.Tools.StopChild
  - Troupe.Agent.Background
gist: "delegate wait false: child runs in the background, its end reaches the parent once as a subagent user_input; read_branch child reads it; stop_child stops it"
---

Issue #554, the part the maintainer settled on 2026-10-11: a parent can see a running
child's state (its turn, its last line, its cost, the tool in flight) and stop it, the
stop recorded in both logs and the child's `finish`-less end reported to the parent as
stopped.

- **Background is asked for, per call.** `delegate` takes `wait`, `true` when left out: a
  delegation runs as it always did, and its finish is the call's result. With `wait:
  false` the child starts the same way (the gate first when it asks, Decision 850; its
  path, its budget share, its depth), and the call answers at once with the child's path
  and how to read, stop and wait for it. `delegation_started` says `wait: false`. Not a
  separate tool, so the brief's shape and the gate stay one; not the default, since a
  parent that needs the answer before its next step is the common case and waiting is what
  it wants.
- **Its end reaches the parent once.** Whatever ends a background child (its finish, an
  end cut short, a stop, a cancel, a failure past its restart limit, its parent's
  restart), the parent's model is handed one message about it: a line saying which child
  it was and how it ended, then the report in Decision 847's parts. Not postponed like
  input: that is delivered when the parent rests, and a parent working through a long run
  would read its child's end only after it.
- **Waiting is resting.** An agent that ends its turn while a background child runs rests
  until an end arrives, a subagent too, which never rested before: replying in text is
  otherwise its finish. `finish` is refused while one runs, naming it: a finish is the
  whole report, and the agent's parent stops it on receipt, which would cut off what still
  ran with nothing written.
- **Stopping is `stop_child`.** It stops one of the caller's own background children, by
  path or by its last part. Only the caller's own background children: a waited-for one
  blocks its parent, which cannot call a tool until it ends, and another agent's child is
  that agent's to stop.
- **`stop_child` goes with `delegate`.** A definition whose tool list names `delegate`
  holds `stop_child` too (`Troupe.Agent.Definition.allows_tool?/2`): starting a subagent
  and stopping one are one capability, and a repository's own definition that lists
  `delegate` need not learn a new name. Its permission, `stop_child: deny` or `ask`, still
  applies.
- **A session at rest with a child at work is not asleep.** The sessions index puts a
  session whose root is at rest to sleep after `detached_idle_ms` (two minutes) once
  nobody watches it, and a sleep stops the tree. A root that rests while a background
  child works is now busy to it, as a root waiting on a waited-for child always was, until
  no subagent is at work.
