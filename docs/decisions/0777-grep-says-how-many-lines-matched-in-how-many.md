---
number: 777
title: "`grep` says how many lines matched in how many files before it lists them, and a task-list update goes with the call that does the work, not as a turn of its own"
date: 2026-10-04
status: accepted
paths:
  - apps/troupe_core/lib/troupe/tools/grep.ex
  - apps/troupe_core/test/troupe/tools/file_tools_test.exs
gist: "`grep` says how many lines matched in how many files before it lists them, and a task-list update goes with the call that does the work, not as a…"
---

Found by the two standard live benches after Decision 776, against `qwen3-235b`: 23
and 24 of 30 runs succeeded, and the failures left were these two and a model's
claim to have written a file it never wrote.
- **The count.** `large_log` failed six runs in six: `grep` answered all 53 matching
  lines, and the model, asked how many there were, counted them as 60 every time. A
  model counting a long list by eye counts it wrong, and none of the six thought to
  run `grep -c`. The answer now starts `53 matching lines in 1 file:`, before the
  lines, where a result cut at `tool_output_limit` still has it. The built-in scan
  counts every match and shows the first 200 (`250 matching lines in 1 file; the
  first 200 follow:`); ripgrep stops each file at 200, so a file that reached that
  says there may be more. The cost is one line a search.
- **The task list.** `todo_write` was 32 of the bench's 168 model calls, and five of
  the twelve in each `rename_symbol` run that ran out of calls with the work done
  (outcome and checks held). The tool's description and the `build` agent said to
  write a list for anything of more than two steps and mark each item as it starts
  and ends; a model that does each mark as a call of its own spends a whole round
  trip, the whole conversation sent again, on every one. Now a list is for work of
  more than a few steps, and each update goes in the same response as the tool call
  that does the work (`todo_write`, `build.md`, `implementer.md`, `workflow.md`).
  `build.md` says it in a line, since its text is the system prompt the bench holds
  to 1,500 bytes; the reason is in the tool's description. Nothing is enforced: a response may still hold a `todo_write` alone, and the live
  bench says whether the words were enough. `plan` keeps writing its plan into the
  list, which is what it is for.
- **Not changed:** the 12-call limit of a live run, which is what made the overhead
  a failure rather than a cost; a model that cannot finish a rename in twelve calls
  is a measure worth keeping. And `recover`'s run that said it wrote `port.txt`
  without calling `write_file`: the bench's outcome caught it, as it should.
- **Proof:** `FileToolsTest`: three lines in two files counted, 250 in one counted and
  200 shown by the built-in scan, the cap said by ripgrep, the earlier tests' answers
  with their count, both with `rg` on the `PATH` and without. The offline bench within
  every budget (on Linux the system prompt 1,377 bytes, the tool definitions 12,723,
  `cut_output`'s cut result one line longer). The live bench's numbers
  before and after are the person's to take, on the pull request.
