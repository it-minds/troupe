---
number: 772
title: "`troupe bench` measures the harness offline against budgets kept in one file, and CI fails past one"
date: 2026-10-04
status: accepted
issue: 390
paths:
  - .github/workflows/ci.yml
  - PROTOCOL.md
  - apps/troupe_core/lib/mix/tasks/troupe.bench.ex
  - apps/troupe_core/lib/troupe/agent/spend.ex
  - apps/troupe_core/lib/troupe/bench.ex
  - apps/troupe_core/lib/troupe/bench/history.ex
  - apps/troupe_core/lib/troupe/bench/live.ex
  - apps/troupe_core/lib/troupe/bench/model.ex
  - apps/troupe_core/lib/troupe/bench/runner.ex
  - apps/troupe_core/lib/troupe/bench/scenario.ex
  - apps/troupe_core/lib/troupe/bench/scenarios.ex
  - apps/troupe_core/test/troupe/bench_test.exs
  - clients/tui/lib/troupe/cli/bench.ex
  - clients/tui/test/troupe/bench_cli_test.exs
  - docs/developer/bench.md
  - scripts/ci
gist: "`troupe bench` measures the harness offline against budgets kept in one file, and CI fails past one"
---

Issue #390, its first tier; the live tier and `troupe doctor --bench`
stay open. The harness's cost curve (#389) was found by a person reading a bill:
nothing in the repository said how many model calls a turn makes or what each one
sends, so nothing could notice when that got worse.
- **Shape, not answers.** Five scenarios (`Troupe.Bench.Scenarios`): one turn of thirty
  tool calls (calls per turn, the system prompt and tool definitions, the largest
  prompt, growth per round trip, input tokens over the turn, events logged), a tool
  result over the limit cut and read back with `read_output`, compaction at the
  configured share of the window (never before, within one round trip after), a
  cancel during a model call (its task ends, no call follows, the agent rests and
  answers again), and the log against the session (the file folds as the running log
  does, hashes chain, a replay from the start sees each event once, a resumed agent
  has its conversation). Whether a model's answer is good is #114's question.
- **A scripted model that counts.** `Troupe.Bench.Model` answers the `fake` provider
  as `Troupe.LLM.Fake` does, so the session runs the code a real one does, and
  reports four bytes of the prompt as a token: the fake's flat 100 would never fire
  compaction where a model's count would. Prompts are measured as the log writes them,
  the scratch workspace's path written `<workspace>`, and tool calls are numbered
  from one, so the JSON of two runs of one build is identical.
- **Budgets in one file, compiled in.** `apps/troupe_core/priv/bench/budgets.json`, a
  maximum per scenario and measure, one file to review rather than one beside each
  scenario; compiled into the harness, so an installed `troupe bench` holds itself
  to what CI did. A budget naming a measure nothing takes fails. Moving one is a
  change to that file, with both numbers in the pull request
  (`docs/developer/bench.md`).
- **This build's harness, in this VM, isolated.** Each scenario has its own
  workspace, config and state directories, and while it runs `TROUPE_CONFIG_HOME`
  and `TROUPE_STATE_HOME` name them and opencode's files name none, so nothing of the
  person's reaches the prompt being measured. The session is the harness's own in
  the same VM rather than the machine's daemon, which could be another version and
  would answer for itself; a daemon per scenario would measure a VM booting.
- **One report for both tiers.** Schema 1, JSON with sorted keys and a Markdown
  table from it. Each scenario has `metrics` (value, budget, passed), `checks`, an
  `outcome` a script checks whoever answered (a file's content, or a command exiting
  0), and `runs[]`, each the record the live tier asks for: model, outcome, stop
  reason, turns, model calls, input, cached and output tokens, cost, wall clock,
  retries, compactions, approvals, tools by name with failures and time, and every
  call's prompt breakdown with its latency and first token. Offline, what needs a
  clock, a price or a provider's own retries is `null`. `troupe bench --live` is
  reserved and refuses: the live runner adds a runner, not a format.
- **Where it runs.** `troupe bench [--json]` (TUI Decision 140), `mix troupe.bench
  [--json PATH]` from a checkout, a step of `scripts/ci`, and CI's `lint` job, which
  puts the table in the run's summary and keeps the JSON. A few seconds.
- **Reads the requests, not yet the log's breakdown.** Offline the bench measures each
  request the model is handed. When #389's first slice records each call's prompt
  breakdown and each turn's sum in the log, a live run reads the same `calls[]` from
  there.
- **Proof:** `Troupe.BenchTest` (the suite passes on this build's numbers; a budget
  lowered under a measure fails the run and the table names it; a budget for a
  measure nobody takes fails; two runs write the same JSON; the report's fields are
  schema 1's; both kinds of outcome), the TUI's `bench_cli_test.exs`, failing on the
  chunk's tip with `unknown arguments: bench`, and the installed `troupe bench`, on
  the pull request.
