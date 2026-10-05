---
number: 773
title: "`troupe bench --live` runs small tasks against the person's own model, under a cap it says before it starts, and keeps a history `--compare` reads"
date: 2026-10-04
status: accepted
issue: 390
paths:
  - apps/troupe_core/lib/troupe/bench.ex
  - apps/troupe_core/lib/troupe/bench/history.ex
  - apps/troupe_core/lib/troupe/bench/live.ex
  - apps/troupe_core/lib/troupe/bench/live_scenarios.ex
  - apps/troupe_core/lib/troupe/bench/scenario.ex
  - apps/troupe_core/lib/troupe/llm/provider.ex
  - apps/troupe_core/lib/troupe/reaper.ex
  - apps/troupe_core/test/support/fake_openai.exs
  - apps/troupe_core/test/troupe/bench_live_test.exs
  - clients/tui/lib/troupe/cli/bench.ex
  - docs/developer/bench.md
gist: "`troupe bench --live` runs small tasks against the person's own model, under a cap it says before it starts, and keeps a history `--compare` reads"
---

Issue #390, its local
live mode, on Decision 772's runner, scenario format and report; the nightly's wiring
and `troupe doctor --bench` stay open. The offline suite says what the harness does
with a scripted model; what a turn costs on a person's own gateway and model, and
whether the work gets done there, only a real model can say.
- **Tasks a script checks, not the offline scenarios.** `Troupe.Bench.LiveScenarios`:
  write a file with given content; fix a failing test without touching it (`elixir
  calc_test.exs` exits 0); delegate a question to `explore` and write its answer; read
  a file that is never there and fall back to a default. Each has an outcome
  (Decision 772's `{:file, ...}` or `{:command, ...}`) and a check that the work was
  done the way the task is about (it delegated; the test is as it was; the read
  failed). The offline scenarios stay offline: their drives and measures read the
  scripted model's requests, their budgets are the script's, and thirty reads a turn
  against a real model is the expensive way to learn what the offline suite already
  says. A scenario whose outcome is a command not on the `PATH` is left out before
  anything is spent, and the plan says so.
- **A file's outcome is its text.** `{:file, path, content}` now compares with line
  endings and trailing whitespace aside: a model asked for one line may or may not end
  it with a newline, and on Windows may write `\r\n`. The offline `replay` outcome holds
  as before.
- **A command outcome runs on the person's `PATH`.** The VM puts its own runtime's
  `bin` first on the `PATH` its children get; in a release (the installed `troupe`,
  `troupe-daemon`) that runtime has no boot file of its own, so `elixir calc_test.exs`
  started on it and died at boot (`cannot get bootfile ...start.boot`), and the first
  installed run failed every `fix_test` the model had fixed. In a release the outcome
  command gets the `PATH` without that directory (`Scenario.command_path/2`).
- **The person's provider, in memory.** `plan/1` resolves the person's configuration and
  copies where a model call goes (provider, URL, key, named providers, windows, prices,
  the catalog) into each run's config overrides, nothing else of theirs; `--model`
  picks another model, addressed as `troupe` addresses one, which is also how another
  provider is picked, so there is no `--provider`. The key is never written to a file
  (a session's config is not logged), never printed, and `inspect/1` of a plan leaves
  it out. A model whose key cannot be read is refused before anything starts.
- **A cap, said first, and asked about.** Each run's limits are `scripts/live-check`'s
  (12 model calls, 200,000 tokens sent, 24,000 received, 240 s), well above what any of
  the tasks needs and far below the defaults. The cap is those limits at the model's
  price (the catalog, else `models.prices`; the input at the dearer of the input and
  cache-write prices, since the budget counts both) times the runs, which is the
  issue's "budget x scenarios x repeats"; a model nothing prices has its cap in tokens.
  It is printed on standard error, and nothing runs without a `y` at a terminal or
  `--yes`; with no terminal to ask in, nothing runs (TUI Decision 141). While a run
  goes, the harness holds it to its limits and the runner stops it at its share of the
  cap, counted from each call's `gateway.cost_micros`, which also covers the cache
  reads the budget leaves out, so a run passes its share by at most the call in flight.
- **Each run isolated, and stopped whatever ends it.** A run is the offline suite's
  kind: its own workspace, config and state directories with the environment naming
  them, and a session of the harness this binary carries, with every tool allowed and a
  budget that stops rather than asks. Not a daemon of its own: in this VM the session's
  tree is what `scripts/live-check`'s daemon is there for, everything the run started,
  and `stop_session/1` takes it all down when the root agent's turn ends, the run
  reaches its share of the cap, or its wall clock passes by a quarter more (at most
  30 s), which catches a call that hangs between the harness's own checks. A daemon for
  each run would measure a VM booting, and could be another build than the one the bench
  ships in. Every tool allowed includes the shell, in a scratch directory that is not
  a sandbox; the plan says so, and the user page says to run it as one would such a
  session.
- **Measured as it happens.** The runner subscribes to the session and stamps each event
  as it arrives: a call's latency is its `llm_request` to its `llm_response`, its time
  to first token the first `llm_delta` between them (an agent's calls are one after
  another, so they pair up by agent), a tool call's time its `tool_call_started` to its
  `tool_call_completed`, by agent and id, since a provider that gives no ids gets the
  same `call_0` in every agent. Usage and cost are the log's. Retries happen inside the
  provider's call and never reach the log, so `Troupe.LLM.Provider` now says each as
  `[:troupe, :llm, :retry]` telemetry, which the runner counts for its run. What a
  call's prompt was made of is its `llm_request.prompt_bytes` (Decision 769), the
  offline suite's measure, and a compaction's summary is a call too, from the
  `compacted` that carries it, so its cost counts against the run's share of the cap.
- **One report, with `mode: "live"`.** Schema 1 (Decision 772) with the live fields
  filled, and added: the report's `model`, `repeat`, `cap_micros`, `started_at` and
  `skipped`; a run's `error` (why it did not end by itself), `checks` and `succeeded`
  (no error, the outcome held, every check held); a call's `agent`, `cached_tokens` and
  `cost_micros`. A scenario's metrics are taken over its runs and held to no budget:
  the success rate, median and worst cost, and the medians of the wall clock, a call's
  latency and time to first token, the calls and the tokens each way; a model's
  variance is not a regression. A scenario passes when every run succeeded, and
  `troupe bench --live` exits 0 then, 1 otherwise, 2 when it ran nothing.
- **History and `--compare`.** Each run is appended to `<state>/bench/results.jsonl` as
  it ends (so Ctrl-C keeps what ran): its record with `schema`, `bench` (when the bench
  started, which groups its runs), `version`, `scenario` and `run`. `troupe bench
  --compare` puts the last bench beside each scenario's last runs in an earlier one;
  `--compare <version|model>` beside that version's or model's last runs. The file is
  the person's, beside their sessions, and holds what runs did and cost, never what
  they were sent.
- **`--repeat N`, default 1.** One run of each is the cheapest answer to "does it work
  here and what does it cost"; to compare, three or more. The issue's open question
  (3 or 5) is the nightly's.
- **The nightly, later.** It never runs for a pull request. The nightly should run it
  after `scripts/live-check`, with the model and prices the `live` job already has
  (`TROUPE_NIGHTLY_MODEL`, `qwen3-235b` by default), `--repeat 3 --yes --json`, its
  table in the run's summary, and the history carried from night to night (an Actions
  cache keyed by the branch) so `--compare` shows a trend break. That wiring is a
  change to `live.yml` of its own.
- **Proof:** `Troupe.BenchLiveTest`, against a stand-in for an OpenAI-compatible
  endpoint on a loopback port (`test/support/fake_openai.exs`, streamed scripted
  answers with usage and delays, a `500` first when asked): the plan's cap and its
  words, the key in none of them; no price, a cap in tokens; no key, refused; a
  missing program, left out; four scenarios twice with every live field filled and the
  delegation timed across two agents with the same call ids; a retry counted; a run
  past its wall clock stopped; a run past its share of the cap stopped; the history
  and `--compare` by last, version and model; a file's text; a release's runtime out
  of a command's `PATH`; a compaction's summary as a call with its prompt and cost.
  The TUI's `bench_cli_test.exs`, which failed on #397's tip with `troupe bench
  --live: not yet`; and the installed `troupe bench --live --repeat 2 --json` against
  the stand-in, on the pull request.
