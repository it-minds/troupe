---
number: 793
title: The `build` agent writes a task list only for work of more than five steps, so a small task takes no model calls for one, and the harness does not fold a `todo_write` that comes alone into the next call.
date: 2026-10-05
status: accepted
issue: 428
paths:
  - apps/troupe_core/priv/agents/build.md
  - apps/troupe_core/priv/agents/implementer.md
  - apps/troupe_core/lib/troupe/tools/todo.ex
symbols:
  - Troupe.Tools.TodoWrite.description/0
gist: A task list is for more than five steps, said as a number; "a few" and "call todo_write first" had qwen3-235b list every three-step task.
---

Found by the live bench on `qwen3-235b` (issue #428), and measured again before this
change by `troupe bench --live --suite standard --repeat 3 --model qwen3-235b` on the
installed 0.8.3-beta, whose task-list words are this chunk's: 26 of 30 runs succeeded in
179 model calls, and 42 of those calls were a `todo_write`. All three `follow_steps` runs
did the work (outcome and checks held) and stopped on the run's 12-call cap with a call
pending, four of their twelve calls the task list.

- **One call to a response.** Each of the 179 responses held at most one tool call, so not
  one `todo_write` went with the call doing the work, as Decision 777 asked. On a model
  that answers this way a list of n items costs about n + 1 calls, each sending the whole
  conversation again, whatever the words say about responses.
- **Who wrote a list.** Every run of `fix_test`, `rename_symbol`, `implement_spec` and
  `follow_steps`, twelve of thirty: tasks of two to four steps, each made into a list of
  up to five items ("investigate", "locate", "verify"; one `implement_spec` run listed a
  single item), most of them written before the first file was read. The `build` agent said "for a task of more than a few steps,
  call `todo_write` first with the whole plan", and the model read three steps as more
  than a few. The tool's description said "a task of two or three needs none", and the
  model wrote a list for every task of three all the same: the system prompt is what it
  followed.
- **A number, in the system prompt.** `build.md` now says a task list is for work of more
  than five steps, and that for five or fewer the work is done without one; "first" is
  gone. The tool's description says the same and why, and `implementer.md` the same of a
  workflow step's parts. Five because the longest list the model made of any of the
  suite's tasks had five items (`fix_test`, a read, a fix and a test run): a bar a padded
  list of a small task still falls under. Above it, the work runs long enough that the
  list earns its calls: it keeps the plan in front of the model however long the
  conversation gets, and it is what a person watches the work by.
- **Not folded by the harness.** By the time the harness reads a response holding only a
  `todo_write`, its call is spent, and the work it did not do needs the next call anyway.
  The harness could stop counting it, which hides a call that was paid for and sent the
  conversation again, and the bench's `tool_calls` would still list it; or rewrite the
  conversation afterwards to put it beside the next call, so that what was sent is not
  what the log replays and the prompt cache is written again from that message on.
  Neither saves a call. Offering `todo_write` only once a turn has run long would change
  the tool definitions mid-turn, and they are the start of every cached prompt.
- **Not changed:** `plan`, whose list is its answer, and `workflow`, whose list is the
  workflow, one item a step, each update going with a delegation. Nothing is enforced: a
  model may still write a list for a small task, and the live bench says whether the
  number was enough.
- **Proof:** `Troupe.Agent.TaskListCallsTest` runs `follow_steps` through the bench's
  runner under a live run's cap, against a stand-in that answers as the model did: one
  tool call to a response, a list whenever the system prompt asks for one for a task of
  three steps (reading "a few" as two), updated after each step, and the three reads it
  checked the work with. On the chunk's tip that run made twelve calls, four of them
  `todo_write`, and was cut off by the cap with a call pending, as the live runs were;
  now it makes nine and ends by itself. The offline bench within every budget (on Linux
  the system prompt 1,399 bytes from 1,377, the tool definitions 12,732 from 12,723). The
  live bench before and after, on the pull request.
