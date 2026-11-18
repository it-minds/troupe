---
number: 793
title: An agent with every tool is offered the task list only once its turn has made ten model calls or while there is a list, so a small task takes no calls for one; plan and workflow have it always.
date: 2026-10-05
status: accepted
issue: 428
paths:
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe/tool.ex
  - apps/troupe_core/lib/troupe/tools/todo.ex
symbols:
  - Troupe.Tools.available/2
  - Troupe.Tool.Ctx
gist: Don't offer todo_write to a tools-all profile before ten model calls of a turn unless a list exists; words alone did not stop qwen3-235b listing 3-step tasks.
---

- **Words were not enough.** The first change was words only: `build.md`, `implementer.md`
  and the tool's description said a list is for work of more than five steps, and that for
  five or fewer the work is done without one, and "call `todo_write` first" was gone. The
  model writes a list when it has the tool.
- **So the harness decides when it has the tool.** `Troupe.Tools.available/2` leaves
  `todo_write` and `todo_read` out of the tools a profile with every tool (`build`,
  `general`, `implementer`, a person's own agent with no `tools:` list) is offered until
  its turn has made ten model calls, a subagent's included as the turn's line counts them
  (`Tool.Ctx.turn_calls`), unless there is a list, written earlier or added by a person in
  a client. A profile that names them in its `tools:`, as `plan` and `workflow` do, has
  them on every call: the list is what those are for. A call to the tool while it is not
  offered still runs, as the profile allows it, and the list it writes keeps the tool
  offered. Ten because no task of the suite took more than nine calls without its list
  (eight tool calls and the answer, in both runs), so none of them is offered one, and
  because a turn past ten calls is work long enough that the list carries what the
  conversation may lose and what a person watches the work by. A turn starts counting
  again: one with no list starts without the tool.
- **The words follow the tool.** `build.md` says `todo_write` is offered once the work
  has run long and what to do with it then; the tool's description says nothing of when a
  list is worth it, since it is only offered when one is; `implementer.md` the same as
  `build.md`. A prompt that names a tool the model does not have invites a call to it.
- **What it costs.** The tools are the start of every prompt, so the call that first
  offers the list writes the whole prompt to the cache again, at most once a turn: on a
  turn of eleven calls or more with no list before it, or after a call to the tool
  unoffered. Every call before it is a little smaller (the two tools' definitions, about
  1 kB). A long turn on a model that batches its updates with the work, as 777 asked,
  starts its list ten calls later than it could have.
- **Not chosen.** Answering a `todo_write` that only marks progress without a model round
  trip, or folding a lone one into the next call: by the time the harness reads a
  response holding only a `todo_write`, its call is spent, and the work it did not do
  needs the next call anyway; the harness could only stop counting it, which hides a call
  paid for, or rewrite the conversation afterwards, so that what was sent is not what the
  log replays and the cache is written again from that message on. Marking progress from
  the calls themselves: nothing in a `read_file` or an `edit_file` says which item it
  finishes, and a list marked by guesswork is worse than none for the person watching it.
  A bar in a number of steps alone: tried, above.
