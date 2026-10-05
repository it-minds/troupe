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
  - apps/troupe_core/priv/agents/build.md
  - apps/troupe_core/priv/agents/implementer.md
symbols:
  - Troupe.Tools.available/2
  - Troupe.Tool.Ctx
gist: Don't offer todo_write to a tools-all profile before ten model calls of a turn unless a list exists; words alone did not stop qwen3-235b listing 3-step tasks.
---

Found by the live bench on `qwen3-235b` (issue #428), and measured before and after a first
change by `troupe bench --live --suite standard --repeat 3 --model qwen3-235b`.

- **One call to a response.** In the before run (the installed 0.8.3-beta, whose
  task-list words were this chunk's) each of the 179 responses held at most one tool
  call, and 42 of them were a `todo_write`: not one went with the call doing the work, as
  Decision 777 asked. On a model that answers this way a list of n items costs about
  n + 1 calls, each sending the whole conversation again. All three `follow_steps` runs
  did the work and stopped on the run's 12-call cap with a call pending, four of their
  twelve calls the list; every run of `fix_test`, `rename_symbol`, `implement_spec` and
  `follow_steps` wrote a list, of up to five items, for a task of two to four steps.
- **Words were not enough.** The first change was words only: `build.md`, `implementer.md`
  and the tool's description said a list is for work of more than five steps, and that
  for five or fewer the work is done without one, and "call `todo_write` first" was gone.
  The after run made 163 calls, 32 of them `todo_write`, none sharing a response. The
  words moved `fix_test` (its lists had been written first, before any file was read) and
  nothing else: every `follow_steps` run still wrote a list for its three steps after
  reading them and updated it after each, `rename_symbol` and `implement_spec` still wrote
  theirs first, and one `follow_steps` run and two `rename_symbol` runs stopped on the cap
  with the list's update pending or the work's last check undone. The model writes a list
  when it has the tool.
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
- **Proof:** `Troupe.Agent.TaskListCallsTest` runs `follow_steps` through the bench's
  runner under a live run's cap against a stand-in that answers as the model did: one tool
  call to a response, a list whenever `todo_write` is offered, updated after each step,
  and the three reads it checked the work with. With the tool offered, on the chunk's tip
  and with the words alone, the run made twelve calls, four of them `todo_write`, and was
  cut off by the cap with a call pending, as live; now nine, ending by itself.
  `Troupe.Agent.TaskListOfferTest`: a turn is offered the list from its eleventh call and
  the next turn starts without it; the list written then is logged as `todo_updated` and
  is the agent's; a call to it unoffered runs and keeps it offered; a list a person added
  in the TUI offers it; `plan` has it on every call. `PromptCacheTest`: the call after a
  list written unoffered reads nothing, the first to carry the list's tools, and every
  call after it reads as before. The offline bench within every budget (on Linux the
  system prompt 1,326 bytes from 1,377, the first call's tool definitions 11,685 from
  12,723, the growth per round trip 516 bytes from 484, as the list's tools join at the
  eleventh call). The live bench before and after, on the pull request.
