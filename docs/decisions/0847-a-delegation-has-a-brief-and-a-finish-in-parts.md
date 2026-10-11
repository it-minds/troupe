---
number: 847
title: A delegation has a contract both ways, a brief in five parts refused before any child starts when one is missing, and a finish in parts whose changes Troupe counts, with the full diff only through read_branch
date: 2026-10-11
status: accepted
issue: 554
paths:
  - apps/troupe_core/lib/troupe/tools/delegate.ex
  - apps/troupe_core/lib/troupe/tools/finish.ex
  - apps/troupe_core/lib/troupe/agent/writes.ex
  - apps/troupe_core/lib/troupe/tools/read_branch.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/priv/agents/
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/gui/packages/client/src/transcript.ts
  - clients/gui/apps/desktop/src/views/Session.tsx
symbols:
  - Troupe.Tools.Delegate.brief/1
  - Troupe.Tools.Finish.parts/1
  - Troupe.Agent.Writes
gist: "delegate takes goal, context, constraints, deliverable, do_not (task refused); finish takes summary, ran, passed, unverified, needs; Troupe counts changed; diff only via read_branch diff"
---

Issue #554, slice 1. A subagent was a black box both ways: the root wrote one free `task`,
and the child handed back one free `summary`. What the child needed went missing from the
first, and what the parent needed to judge it (what ran, what passed, what was never
checked) from the second. The maintainer settled the shape (2026-10-11): a brief without
its parts is refused, naming the missing one, and a finish carries what changed, what ran,
what passed, what is unverified and what the child needs. The opt-in gate (slice 2), the
`orchestrate` profile (slice 3) and a parent reading a running child are built on these
shapes and are not here.

- **The brief.** `delegate` takes `agent` and five parts, each its own field and each
  required: `goal`, `context`, `constraints`, `deliverable`, `do_not`. A part is text, or a
  list of strings, one line each; blank is missing. A call missing any is refused before
  a child starts, with one sentence naming every missing part and saying to write none
  where a part has nothing. The child's first message is the parts under their names
  (`Goal: ...`, `Context: ...`, and so on, a part of several lines under its name), and
  `delegation_started` carries that text as `task`, as it always has, and the parts as
  `brief`.
- **`task` is refused, not mapped.** Mapping it onto `goal` and `context` for a release
  would hand on a brief still missing `constraints`, `deliverable` and `do_not`, which the
  rule this decision follows refuses anyway; a mapped call would be the one blob of text
  the shape exists to end, under new names. So a call in the old shape gets the refusal,
  which also says the single `task` field is gone and to split what it said into the five
  parts: enough for a model to send it again, as an agent of a bundle or a person's own
  that still calls the old way will. A delegation a restart takes up again from a log
  written before this is refused the same way, and its model sends it again in parts.
- **The finish.** `finish` takes `summary` (the result the brief's deliverable asked for),
  `ran`, `passed`, `unverified` and `needs`, each required and refused the same way, so a
  child cannot leave out what it did not check. `summary` stays, beside the five the
  maintainer named: the deliverable has to go somewhere, and every reader of a finish
  (`agent_done`, `read_branch`, the clients, A2A) already reads it there. One shape for
  every caller, primaries that finish (`answer`, `quick`, `ask`, the librarian) included,
  because a branch's finish is read by its parent session as a subagent's is by its
  parent.
- **What changed is Troupe's to say.** Once every call of the finishing turn is back,
  Troupe counts what the agent and every agent under it wrote through `write_file` and
  `edit_file`, off the log (`Troupe.Agent.Writes`): each file with the lines added and
  removed (an edit by the lines its old and new text differ in, a write whole by the lines
  it wrote, said to be written whole since what it held before is not in the log), the
  totals, how many `shell` commands ran whose changes are not counted, and where to read
  the diff. A subagent shares its parent's workspace, so a `git diff` there would hold
  the parent's and the siblings' changes too: the calls are the only diff that is the
  child's own. The model's own `changed` is only for what those tools did not do, and is
  shown as what it says. A subagent that answers in text without calling `finish` is
  reported in the same parts, its changes counted, its `unverified` "all of it".
- **The parent is handed the report rendered**: the summary, then `changed`, `ran`,
  `passed`, `unverified` and `needs` under their names. The same text is `agent_done`'s
  `summary`, so `read_branch`, the TUI's done line, the headless printer and A2A show what
  the parent saw, and `agent_done` carries the parts as `report` for a client to lay out.
  A replay rebuilds it from the `finish` call's arguments and the log, as it rebuilt the
  summary (Decision 693); a `finish` from before the parts gave a summary alone and is
  handed over as it was.
- **Never the full diff, unless asked.** The stat names the call that reads the rest:
  `read_branch(child: "root/implementer#2", diff: true)` for a subagent, by the path its
  finish gives or by its last part for one of the reader's own, and
  `read_branch(session_id: ..., diff: true)` for a branch. `child` reads a finished
  subagent's brief and report; `diff` adds the whole diff of the writes, one hunk a call
  in the order they ran, and only then. A wrong path is answered with the subagents there
  are, as a wrong branch id is (#116). `reviewer` has `read_branch`, so a reviewer briefed
  with an implementer's finish can read its diff.
- **The shapes are taught** where the agents are defined: the primaries that delegate
  (`build`, `plan`, `workflow`) say what a brief needs and how to judge a finish, every
  subagent and every primary that calls `finish` says what goes in each part, and the
  tool schemas say it to an agent of a repository's own.
- **The clients.** The TUI shows the brief as the child's first message and the report
  as the delegate call's result and the done line, all text, and needs no change. The
  desktop app showed a delegate call's and a finish call's arguments as JSON; it now lays
  them out as their parts under their names, and its delegation line gives the brief's
  goal rather than the whole brief.
- **The bench.** The tool definitions `build` is sent grew from 12,827 to 13,336 bytes
  of the 13,500 budget, the first prompt from 14,285 to 14,851 of 15,000, and `build`'s
  system prompt from 1,326 to 1,383 of 1,500. The descriptions were tightened (delegate's
  own, finish's, read_branch's, and the implementer's and reviewer's lines in the agent
  list) to stay inside without raising a budget; a later change to these tools has
  little room left.
- **Proof:** `Troupe.Tools.DelegateContractTest`: a brief with no goal (the old `task`
  call) refused with no child started, the refusal naming every missing part, the child's
  first message, a finish missing parts refused and sent again whole, the stat with its
  files, totals, uncounted command and the agent's own words, the diff only with `diff`, a
  branch's diff, a replayed old summary. `DelegationTest`, `ResilienceTest` and the rest
  scripted in the new shapes, a finish replayed after a restart handed over as live. The
  offline bench within every budget. The installed daemon driven with a fake-provider
  script: a root delegating to `explore` with no `deliverable`, refused, then whole; the
  child's shaped finish at the root; `read_branch` with and without the diff.
