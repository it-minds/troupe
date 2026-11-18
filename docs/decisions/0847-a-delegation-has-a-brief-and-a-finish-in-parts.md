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
symbols:
  - Troupe.Tools.Delegate.brief/1
  - Troupe.Tools.Finish.parts/1
  - Troupe.Agent.Writes
gist: "delegate takes goal, context, constraints, deliverable, do_not (task refused); finish takes summary, ran, passed, unverified, needs; Troupe counts changed; diff only via read_branch diff"
---

The maintainer settled the shape (2026-10-11): a brief without its parts is refused,
naming the missing one, and a finish carries what changed, what ran, what passed, what is
unverified and what the child needs.

- **The brief.** `delegate` takes `agent` and five parts, each its own field and each
  required: `goal`, `context`, `constraints`, `deliverable`, `do_not`. A part is text, or
  a list of strings, one line each; blank is missing. A call missing any is refused before
  a child starts, with one sentence naming every missing part and saying to write none
  where a part has nothing.
- **`task` is refused, not mapped.** Mapping it onto `goal` and `context` for a release
  would hand on a brief still missing `constraints`, `deliverable` and `do_not`, which the
  rule this decision follows refuses anyway; a mapped call would be the one blob of text
  the shape exists to end, under new names.
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
  the diff. A subagent shares its parent's workspace, so a `git diff` there would hold the
  parent's and the siblings' changes too: the calls are the only diff that is the child's
  own.
- **The parent is handed the report rendered**: the summary, then `changed`, `ran`,
  `passed`, `unverified` and `needs` under their names. The same text is `agent_done`'s
  `summary`, so `read_branch`, the TUI's done line, the headless printer and A2A show what
  the parent saw, and `agent_done` carries the parts as `report` for a client to lay out.
- **Never the full diff, unless asked.** The stat names the call that reads the rest:
  `read_branch(child: "root/implementer#2", diff: true)` for a subagent, by the path its
  finish gives or by its last part for one of the reader's own, and
  `read_branch(session_id: ..., diff: true)` for a branch.
