---
number: 775
title: "`troupe bench --live` is a benchmark: a `standard` suite of ten tasks beside the four-task `smoke`, each run's tool calls in its record, a score with its interval and a cost per success, and a run's directories kept on request"
date: 2026-10-04
status: accepted
issue: 390
paths:
  - apps/troupe_core/lib/troupe/bench.ex
  - apps/troupe_core/lib/troupe/bench/history.ex
  - apps/troupe_core/lib/troupe/bench/live.ex
  - apps/troupe_core/lib/troupe/bench/live_scenarios.ex
  - apps/troupe_core/lib/troupe/bench/scenario.ex
  - apps/troupe_core/test/support/fake_openai.exs
  - apps/troupe_core/test/troupe/bench_live_test.exs
  - docs/developer/bench.md
gist: "`troupe bench --live` is a benchmark: a `standard` suite of ten tasks beside the four-task `smoke`, each run's tool calls in its record, a score…"
---

Issue #390's second
tier, and issues #405 and #406, found in the first live bench against `qwen3-235b`
(Decision 773's four tasks, three runs each). That bench said whether the setup
worked; it could not say whether the harness is good at work, nor where a dear run's
money went: one `fix_test` run cost five times another, and nothing in the report
said why.
- **Two suites.** `smoke` is Decision 773's four and stays the default, so the
  cheapest answer to "does it work here" costs what it did and its history compares
  with the runs before this. `standard` adds six tasks that look more like work, each
  with an outcome a script checks and, where the way it is done is the point, a check:
  `rename_symbol` (a function renamed in its module and in its callers in two other
  files; `elixir shop_test.exs` passes and the old name is in no file),
  `implement_spec` (a Roman numeral encoder written from its documentation; the test
  passes, unchanged), `large_log` (a count in a 480 kB log, more than one read returns,
  whose level and code each count the wrong lines; the number is right), `precise_edit`
  (one setting of a 1,560-line file changed where a second section has the same line;
  the file is exactly as wanted, and was edited, not written whole), `follow_steps`
  (three steps read from a file in the workspace; each step's file holds what it
  should) and `answer_only` (a question that needs no tool; the answer is right and
  no tool was called, which is the least a turn can cost: one call carrying the system
  prompt and every tool's definition). `--suite NAME` picks one, `--scenario a,b`
  names scenarios whatever their suite. Ten tasks are still not a quality benchmark
  of a model; they are enough to compare one harness build, or one model, with
  another on the same work, which is what the bench is for.
- **A score, not only a rate.** A scenario's measures add the success rate's 95%
  Wilson interval (`success_low`, `success_high`), the cost per success (everything
  its runs cost, over the runs that succeeded, which is how two models compare, per
  issue #390) and the median of each run's largest tool result. The report adds
  `summary`: runs and successes with the interval, cost in all, per run and per
  success, tokens and model calls in all, tokens per success, and wall clock. Three
  runs that all succeeded put a model's rate only above 0.43, so the table says so
  rather than "1.0". `--compare` adds `all` rows over the scenarios both benches ran:
  success rate, cost per success and per run, the median run's wall clock and tokens
  per success, which hold whatever the number of runs.
- **Each tool call in the record (#406).** `tool_calls[]`: agent, tool, time, whether
  it succeeded, the bytes of its result as the model was given it (a result the log
  keeps as a blob is resolved and measured), and `cut`, whether the result says part
  of it was left out. Never its input or its output, as the history has never held
  what a run was sent. `largest_tool_result_bytes` beside it. The run that cost five
  times another would have said: one `shell` call, 60 kB, cut.
- **`--keep DIR` (#406).** Each run's workspace and state directory, its session log
  among them, are left under `DIR/<when the bench started>/<scenario>-<n>` instead of
  removed, so a person can read what a run did. A directory of the bench's own, so a
  second bench never seeds a workspace with what the first left. Off by default: the
  log holds what the run was sent.
- **A run that answered on its last allowed call ended by itself (#405).** A live
  run's budget stops rather than asks (773), and such a budget is checked again when
  a turn ends (`to_idle_or_done/1`), so a turn that answered with its twelfth call of
  twelve ended the agent as `agent_done` with `budget_exhausted`, and the bench
  reported "the run's budget stopped it". The bench now reads the root's last reply:
  one that ended the turn (`end_turn`) is a run that ended by itself, and one cut off
  with a tool call pending is still the budget's. The harness is unchanged: on the
  plane, a contract budget spent is a finished session either way, and logging a
  `turn_ended` before the `agent_done` is a change of the log's meaning for every
  reader, not the bench's to make.
- **`suite` stays the report's name.** Schema 1's `suite` is `"troupe bench"`; the
  set that ran is `live_suite` (`smoke`, `standard`, or `only` for scenarios named).
  Fields are added, none renamed (772).
- **Proof:** `Troupe.BenchLiveTest`: the suites, a scenario by name, an unknown suite
  or scenario refused before anything is asked of the provider; the `standard` suite
  against the stand-in, every outcome and check holding, the log searched rather than
  read whole, `answer_only` in one call with no tool, the summary and its interval;
  the six new tasks failing when the stand-in touches nothing; a run whose last
  allowed call ends the turn succeeding, which failed on the chunk's tip with "the
  run's budget stopped it (max_turns)", and one cut off with a call pending not; a
  read cut at the limit in `tool_calls` as a blob measured whole, and `--keep`
  leaving the workspace and the session log; the interval's values; `--compare`'s
  `all` rows. The TUI's `bench_cli_test.exs` (TUI Decision 142). And the installed
  `troupe bench --live --suite standard --repeat 2 --keep --json` against the
  stand-in, on the pull request.
