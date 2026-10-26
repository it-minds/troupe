# The bench

`troupe bench` measures the harness against budgets kept in this repository: how many
model calls a turn makes, what each prompt is made of and how it grows, where a tool result
is cut, when compaction comes, what a cancel leaves running, and whether the log is the
session (issue #390, Decision 772); and, for each other tool `troupe onboard` brings in,
whether that tool's instructions reach a session's prompt once onboarded, and what they
take of it (issue #516, Decision 834). It is about the harness's shape, not about what a
model answers.

The suite is offline. Each scenario runs against a scripted model, so it costs nothing,
needs no network, and gives the same numbers every time: two runs of one build write the
same JSON, byte for byte. CI fails when a number goes past its budget, so a change that
makes every turn more expensive is caught by its pull request, not by whoever gets the
bill.

`troupe bench --live` is the other tier: small tasks (four by default) against the person's
own model, under a spending cap it states before it starts, with a history to compare runs
with (Decision 773; [the live bench](#the-live-bench) below, and
[what a task costs](../user/bench.md) for the person running it). It never runs in CI.

## Running it

| where | command | what it gives |
|---|---|---|
| an installed `troupe` | `troupe bench`, `troupe bench --json [FILE]` | the table, or the JSON report; exit 1 past a budget |
| an installed `troupe` | `troupe bench --live [--repeat N] [--model M]`, `troupe bench --compare [REF]` | [the live bench](#the-live-bench) |
| an installed `troupe` | `troupe doctor --bench [--json]` | doctor's checks, then a line a scenario, passed or what failed, and one for the whole with the time it took (Decision 821) |
| a checkout | `mix troupe.bench [--json PATH]` | the table on standard output, the JSON in `PATH`; exit 1 past a budget |
| this machine's CI | `scripts/ci` | the step *bench within its budgets* |
| CI | the `lint` job of `ci.yml` | the table in the run's summary, the JSON as the `bench` artifact |

The suite takes a few seconds, and says how many under the table. `mix troupe.bench`
starts only `troupe_core`, so it runs from the umbrella's root with no database.

Each scenario runs in its own workspace, config and state directories under a new
temporary one, removed afterwards; while it runs `TROUPE_CONFIG_HOME` and
`TROUPE_STATE_HOME` name them and opencode's two files name none, so nothing of the person
running it (config, keys, agents, skills, instruction files, sessions) reaches the prompt
being measured. One that onboards also has a home directory of its own, given to
onboarding for `~`, so none of the person's own files (`~/.claude/CLAUDE.md`) is read. The
session is the harness's own, in the same VM; `troupe bench` never asks the machine's
daemon, which could be another version.

## Reading the table

```
| scenario | measure | value | budget | |
| --- | --- | ---: | ---: | --- |
| tool_calls | model calls in the turn | 31 calls | 31 | ok |
| tool_calls | largest prompt | 28376 bytes | 31500 | ok |
| tool_calls | growth per tool round trip | 484 bytes | 550 | ok |
...
| replay | outcome: hello.txt holds what was asked for | yes |  | ok |
| onboard_claude_code | instructions in the first prompt | 519 bytes | 570 | ok |
...

troupe bench 0.15.0-beta, offline: 10 scenarios, every measure within its budget.
```

A row is a measure (a number, held to its budget when it has one) or a check (yes or no).
A budget is a **maximum**. A failed run ends `FAILED` and names each failure as
`scenario/measure`. A scenario that did not run says why in its first row.

The numbers are the same on every run of one build on one machine. Between machines they
can differ by a few hundred bytes, since the system prompt names the platform and the
`shell` tool names the host and the shell it found, among others, and the budgets are set
above both.

| scenario | what it shows |
|---|---|
| `tool_calls` | one turn of thirty `read_file` calls: thirty-one model calls, the system prompt and tool definitions each prompt starts with, the largest prompt, the growth per tool round trip, the input tokens over the turn (#389's number), the events the turn logs; and that the prompt and `show`'s description say the scratchpad is for a document asked for or an answer past about 80 lines, and that the turn's short answer left it empty (Decision 895) |
| `cut_output` | a `grep` result over `tool_output_limit`'s default is cut, kept, and read back with `read_output`; the cut result's size as the next prompt carries it |
| `compaction` | in a window of 16,000 tokens, compaction fires once the prompt reaches `compact_at`'s default share of it, never before, and within one round trip after; how much smaller the next prompt is |
| `cancel` | a cancel during a model call ends the call's task, no call is made afterwards, the agent rests and answers the next input |
| `replay` | the log on disk folds as the running log does, its hashes chain, a client replaying from the start sees each event once, a resumed agent has the conversation it had; and the file it was asked to write holds what was asked for |
| `prefix_change` | thirteen calls of one turn on a model that binds its thinking to the system prompt and tools it was made under (D92): the task list's tools come at the eleventh call, and a call handing back a block made before that is refused and sent again without thinking. Refused once for the one change, not on every call after it, since the conversation lets the blocks from before the change go at that call; and a resumed agent has the conversation it had |
| `onboard_claude_code`, `onboard_opencode`, `onboard_cursor`, `onboard_copilot` | a repository with one other tool's files only, `troupe onboard`'s plan accepted whole, a new `AGENTS.md` included; then a note written under the house rule the tool's files carry, which the scripted model follows only when it finds it in its prompt. What the instructions took of the first prompt (for opencode, the onboarded agent's prompt, which the session starts on), the files onboarding wrote, and the tool's files it left out; a fixture whose onboarding writes nothing, or loses the rule, fails |
| `memory_stale_anchor` | a repository whose memory holds a command anchored on `mix.exs`, checked by a librarian, and the `check` alias changed since (#248, Decision 838): the first prompt marks the command "may no longer be true" and names `recall` for the other facts, and the scripted model asks `recall`, which answers it with the same status, only when it finds the mark. What the brief took of the first prompt |

**What a token is here.** The scripted model counts four bytes of the prompt as a token,
rounded up, and reports that as the call's input. It is not a tokeniser; it is what makes
compaction and the context gauge fire where they would against a model, and the same every
run. A prompt's bytes are counted as the event log writes it: the system prompt, the tool
definitions as JSON, and each message as `Message.to_json/1` gives it, with the scratch
workspace's path written as `<workspace>` so the directory a run happens in costs nothing.

## Moving a budget

The budgets are one file, `apps/troupe_core/priv/bench/budgets.json`, compiled into the
harness, so an installed `troupe bench` holds itself to what CI did:

```json
{
  "tool_calls": { "model_calls": 31, "largest_prompt_bytes": 31500, "...": 0 },
  "cancel": { "calls_after_cancel": 0, "tasks_left_running": 0 }
}
```

Moving one is a reviewed change, in the pull request that moved the number:

1. Run `mix troupe.bench` on the base and on the change, and put both rows in the pull
   request with the reason the number moved.
2. Edit the number. Where exactness is the point (calls per turn, nothing left running) the
   budget is the value itself; otherwise it is the measured value with about a tenth of
   headroom, rounded, so noise from a neighbouring change does not fail it and a real
   regression does.
3. A change that makes a number smaller should lower its budget too, so the improvement
   stays: this is how #389's slices are kept.
4. Where the reason is not the number itself, say it in the file: the top-level `$comment`
   object holds a note per `scenario.measure`, and keys starting with `$` are not scenarios.

A budget for a measure a scenario that ran does not take fails the run, so a renamed measure
cannot leave a budget holding nothing; a budget under a scenario name that no longer exists
is not read at all, and goes when the scenario does.

## The report: schema 1

The JSON is one object, keys sorted, so two runs diff line by line. Fields are added within
schema 1 and never renamed or removed; a change that has to is schema 2.

| field | |
|---|---|
| `schema` | `1` |
| `suite` | `"troupe bench"` |
| `mode` | `"offline"`, or `"live"` for a run against a real model ([below](#the-live-report)) |
| `version` | the Troupe version that ran it |
| `passed` | every scenario passed |
| `scenarios[]` | in suite order: `name`, `title`, `passed`, `error` (why it did not run, else `null`), `outcome`, `runs`, `metrics`, `checks` |
| `outcome` | `{what, passed}` for a scenario that declares one, else `null` |
| `metrics[]` | `{name, label, unit, value, budget, passed}`; `budget` is `null` for a measure with none |
| `checks[]` | `{name, label, passed}` |
| `runs[]` | one per run of the scenario (offline, one) |

A run is the record the issue's second tier asks of every run, filled from the session's
log and the model's calls:

| field | offline |
|---|---|
| `model` | `fake/fake-model` |
| `outcome` | the scenario's outcome for this run: `true`, `false`, or `null` for none |
| `stop_reason` | the root's last answer's |
| `turns`, `model_calls`, `compactions`, `approvals` | counted |
| `input_tokens`, `output_tokens` | summed over the calls; `cached_tokens` is `0` |
| `cost_micros` | `null`: nothing priced the scripted model |
| `wall_ms` | `null`: an offline run has no clock, so two runs stay the same |
| `retries` | `null`: a provider retries inside its own call and the log does not record it |
| `tools[]` | `{name, calls, failures, ms}`; `ms` is `null` |
| `calls[]` | every model call, the summariser's included: `summariser`, `prompt_bytes`, `system_bytes`, `tool_definition_bytes`, `conversation_bytes`, `tool_result_bytes`, `input_tokens`, `output_tokens`, and `latency_ms` and `first_token_ms`, `null` |

The fields that are `null` offline are the ones a run against a real model fills.

## Scenarios

A scenario is a `Troupe.Bench.Scenario` in `Troupe.Bench.Scenarios`:

| field | |
|---|---|
| `name`, `title` | the key in the report and in `budgets.json`, and one line saying what it shows |
| `prompt` | what is typed, once, as a person's input |
| `files` | the workspace before the run, `%{path => content}` |
| `config` | settings beside the bench's own (the scripted model, every tool allowed, no brief) |
| `script` | the scripted model's steps: `{:text, t}`, `{:tools, [{name, input}]}`, `{:delay, ms, step}`, `{:bound, step}` (the step after a thinking block bound to the request's system prompt and tools, answered as sent again without thinking where the request hands back one bound to others), or a function of the request that answers one (how `cut_output` passes on the id the cut result named); a request with no tools is the summariser's and gets a summary |
| `outcome` | what a script can check afterwards, whoever answered: `{:file, path, content}`, the file's text, line endings and trailing whitespace aside, or `{:command, argv}`, run in the workspace, passing on exit 0 (a test passing), and in a release without the VM's own runtime first on its `PATH`, where an `elixir` would start on it and find no boot file; or `nil` |
| `drive` | `nil` to type the prompt and wait for the turn to end, or a function that does something else (cancel half way) |
| `follow_ups` | prompts typed one after another, each once the turn before has ended by itself |
| `loop` | `nil`, or a goal: the run sets it and runs a `/loop` of one iteration (Decision 871) |
| `prepare` | `nil`, or a function run once the workspace has its files and before the session starts, given the run's `workspace`, `home`, `config_dir` and `state_dir`, answering the marks the measure reads (`ctx.marks`): how the onboarding scenarios run `troupe onboard` first |
| `agent` | the agent the session starts on; `nil` for the default |
| `measure` | a function of the run answering `{metrics, checks}`: `{name, label, unit, value}` and `{name, label, passed?}` |

To add one: write it, add it to `all/0`, give its measures budgets, run `mix troupe.bench
--json a.json` twice and check the two files are the same. A number that differs between
runs (a time, a temporary path, a counter) is a measure that cannot be budgeted; leave it
out or make it fixed.

## The live bench

`troupe bench --live` (Decision 773, TUI Decision 141) runs `Troupe.Bench.LiveScenarios`
against the person's own provider and model: small tasks a model has to do itself, each
with an outcome a script checks, so what a run shows is whether the work got done on that
setup and what it cost. The offline scenarios stay offline: their drives and measures read
the scripted model's requests, and their budgets are the script's.

| scenario | asks | outcome | check |
|---|---|---|---|
| `write_file` | write `hello.txt` with one given line | the file holds it | |
| `fix_test` | make `calc_test.exs` pass by fixing `calc.exs` | `elixir calc_test.exs` exits 0 | the test file is as it was |
| `delegate` | delegate the question to `explore`, write its answer to `answer.txt` | the file holds the answer | the root agent called `delegate` |
| `recover` | read `settings/port.txt`, which is never there, and fall back to a default | `port.txt` holds the default | `read_file` failed |
| `rename_symbol` | rename `Shop.Cart.line_total/1` to `subtotal/1` in its module and two callers' files | `elixir shop_test.exs` exits 0 | `line_total` is in no file of `lib/`; the test is as it was |
| `implement_spec` | write `Roman.encode/1` from its `@doc` | `elixir roman_test.exs` exits 0 | the test is as it was |
| `large_log` | count the `ERROR` lines with code `E1042` in a 480 kB log (`service_log/0`) | `answer.txt` holds 53 | |
| `precise_edit` | change `[database]`'s `max_connections` in a 1,560-line file (`settings_conf/1`) where `[cache]` has the same line | the file is `settings_conf(250)` | no `write_file` of it |
| `follow_steps` | the three steps of `TASK.md` | `out/done.txt` lists the two files | each step's file holds what it should |
| `answer_only` | a sum, with no tool | | the reply has 391; no tool was called |
| `follow_up` | two turns: write step 1 of `docs/plan.txt`, then step 2 under `docs/` | `docs/next.txt` holds step 2 under `AGENTS.md`'s and `docs/AGENTS.md`'s rules | `out/first.txt` keeps the root's rule; both turns were taken |
| `task_list` | three turns on `plan`: write a three-item list, one with a number worked out without a tool, then read a file and mark items done, twice | | all three turns were taken; the list ends with its three items completed; the last reply names `b.txt` and 440 |

Six more run only when named, each for a measurement [prompt-prefix.md](prompt-prefix.md)
describes: `long_turn` (one turn of thirteen calls, Decision 867), `loop_turn` (a `/loop`
turn and then a person's, Decision 871), and `scratchpad`, `scratchpad_without`,
`scratchpad_session` and `scratchpad_session_without` (a migration plan, and a session of
eight turns, with the scratchpad and without it, Decisions 870 and 895; see "The
scratchpad's cost" below).

Three more, by name too, are issue #554's comparison of `build` with `orchestrate`
(Decision 888): `fix_test_orchestrate`, `rename_symbol_orchestrate` and
`follow_steps_orchestrate` are those tasks as their pairs have them, prompt, files,
outcome and checks, with `orchestrate` as the session's agent and a check that the root
called `delegate`. The run's cost, calls and tokens are its whole tree's, the subagents'
included, and a call's `agent` says whose it was (`root`, `root/implementer#1`). A run has
600 s of wall clock rather than 240, since its subagents run one after another, each on a
share of the root's. Run each beside its pair:
`troupe bench --live --scenario fix_test,fix_test_orchestrate --repeat 3`.

The first four are the `smoke` suite, the default; the next six with them are `standard`
(Decision 775). `follow_up` and `task_list` are in neither and run when named. Both are
issue #465's ([prompt-prefix.md](prompt-prefix.md) says how each is run with that issue's
settings): `follow_up`'s second turn begins with an instruction file the first brought in
(Decision 815); `task_list`, on the `plan` agent, which always has the list's tools, has
each turn after the first begin with the task list the turn before left (Decision 792; in
the system prompt with `system_prompt: per_turn`, with the turn by default, Decision 863).
A scenario's `follow_ups` are typed one after another, each once the turn before has ended
by itself, under the run's one deadline and cap. `LiveScenarios.select/2` takes a suite or
a list of names from either, and answers them in report order; `--suite` and `--scenario`
reach it through `plan/1`'s `:suite` and `:only`. A task added to `standard` needs a script
in `fake_openai.exs`, so the suite's own test can run it, and a test that it fails when
nothing is done.

**Before anything starts**, `Troupe.Bench.plan/1` reads the person's configuration and
takes from it where a model call goes (provider, URL, key, named providers, windows,
prices, the catalog) and the settings that shape one (the small and expensive models, the
auth, the call timeout, the thinking binding and the system prompt); `--model` picks another than the default. It refuses
a model whose key it cannot read, and leaves out a scenario whose outcome is a command not
on the `PATH`. The cap is a run's limits (`scripts/live-check`'s: 12 model calls, 200,000
tokens sent, 24,000 received, 240 s) at the model's price, the input at the dearer of its
input and cache-write prices, times the runs; a model nothing prices has its cap in tokens.
`troupe bench --live` prints it on standard error and runs nothing until the person answers
`y` at a terminal, or passed `--yes`; with no terminal to ask in it runs nothing.

**Each run** is isolated as an offline scenario is ([running it](#running-it)). The
person's provider settings reach it as config overrides, in memory: the key is in no file,
no log and no output, and `inspect/1` of a plan leaves it out. Every tool is allowed, a budget stops
rather than asks, and there is no brief. The runner watches the session's events and stops
the session when the root agent's turn ends, when the run's cost reaches its share of the
cap, or a quarter of its wall clock (at most 30 s) after the wall clock, whichever is
first; a run that did not end by itself says why in its `error`. A run that ended with
`agent_done` for its budget but whose root's last reply ended the turn (`end_turn`) ended
by itself: the stopping budget is checked again as a turn ends, so the last allowed call
answering ends the agent that way too (issue #405, Decision 775). With `--keep DIR`
(`:keep`) the run's directories are left under `DIR/<bench start>/<scenario>-<n>`
rather than removed.

**What a run records** comes from the session as it happens: a model call's latency is its
`llm_request` to its `llm_response`, its time to first token the first `llm_delta` between
them, a tool call's time its `tool_call_started` to its `tool_call_completed`, each taken
as the event arrives; usage and cost are the log's (`gateway.cost_micros`, which the
harness prices from the catalog or `models.prices` when the gateway does not), and what a
call's prompt was made of is its `llm_request.prompt_bytes` (Decision 769), the measure the
offline suite takes of a request. A compaction's summary is a call too, carried by the
`compacted` that takes its answer, with no times since no event announced it. Retries
happen inside the provider's call and never reach the log, so the provider says each one as
telemetry, `[:troupe, :llm, :retry]`, which the runner counts.

**The history** is `<state>/bench/results.jsonl` (`Troupe.Bench.History`), a line a run,
appended as each run ends: the run's record with `schema`, `bench` (when the bench
started, which groups its runs), `version`, `scenario` and `run`. `troupe bench --compare`
puts the last bench beside each scenario's last runs in an earlier one, or, with a version
or a model, the last runs of that one, measure by measure, and, when more than one
scenario is in both, `all` rows over those (`Live.overall/1`: measures per run and per
success, so benches of different `--repeat` compare).

### The live report

Schema 1, with `"mode": "live"`, and these added:

| where | field | |
|---|---|---|
| the report | `model`, `repeat`, `cap_micros`, `started_at`, `skipped[]` | what ran against what, how often, under what cap; the scenarios left out, `{name, why}` |
| the report | `live_suite`, `kept_in` | `smoke`, `standard`, or `only` for scenarios named; where `--keep` left the runs, else `null` (Decision 775) |
| the report, a history line | `experiment` | issue #465's two settings the runs had, `thinking_binding` and `system_prompt`, from the person's configuration or `TROUPE_THINKING_BINDING` and `TROUPE_SYSTEM_PROMPT` (Decisions 815 and 863) |
| a run, the `summary` | `prefix` | `Troupe.Bench.Prefix.count/1` of the run's log, added up in the summary: `model_calls`, `system_changes`, `tools_changes`, `inferred`, `thinking_resent`, `thinking_dropped`, `calls_dropping`, `turn_contexts` ([prompt-prefix.md](prompt-prefix.md)) |
| the report | `summary` | every run together: `scenarios`, `runs`, `succeeded`, `success_rate`, `success_low`, `success_high` (the 95% Wilson interval), `cost_micros`, `cost_per_run_micros`, `cost_per_success_micros`, `model_calls`, `input_tokens`, `cached_tokens`, `output_tokens`, `tokens_per_success`, `wall_ms`, `median_wall_ms` |
| a scenario | `metrics[]` | taken over its runs, with no budget: `success_rate` with `success_low` and `success_high`, `median_cost`, `worst_cost` and `cost_per_success` (in dollars), and the medians `median_wall_ms`, `median_call_ms`, `median_first_token_ms`, `median_model_calls`, `median_input_tokens`, `median_cached_tokens`, `median_output_tokens`, `median_largest_tool_result` (bytes) |
| a scenario | `outcome.held` | how many runs it held in; `passed` is every one |
| a scenario | `checks[]` | each held in every run; the label says in how many |
| a scenario | `error` | which runs did not end by themselves, and why |
| a run | `error`, `checks[]`, `succeeded` | why it did not end by itself; its own checks; no error, the outcome held and every check held |
| a run | `since_compaction` | what the run spent from its first compaction on, the summary's call included: `model_calls`, `input_tokens`, `cached_tokens`, `output_tokens`, `cost_micros`; `null` for a run that never compacted (Decision 895) |
| a run | `tool_calls[]`, `largest_tool_result_bytes` | each tool call as it ended, `{agent, name, ok, ms, result_bytes, cut}`: the bytes of the result the model was given (a blob resolved), and whether it says part was left out; never its input or output (issue #406) |
| a call | `agent`, `cached_tokens`, `cost_micros` | which agent made it (`root`, `root/<subagent>`), and its cache reads and cost |

The run's fields that are `null` offline are filled: `cost_micros` (`null` when nothing
priced a call), `wall_ms`, `retries`, each tool's `ms`, each call's `latency_ms` and
`first_token_ms`. `input_tokens` counts what was billed in full (fresh input and cache
writes) and `cached_tokens` the cache reads. A call's prompt breakdown (`prompt_bytes`,
`system_bytes`, `tool_definition_bytes`, `conversation_bytes`, `tool_result_bytes`) is
the log's, so a live call and an offline one are measured alike.

### Testing it

Nothing calls a real model. `apps/troupe_core/test/support/fake_openai.exs` is a stand-in
for an OpenAI-compatible endpoint on a loopback port: it streams scripted answers, the
first chunk after one delay and the rest after another, with usage, and can answer `500`
first so the provider retries. Its scripts answer each live scenario the way it asks, by a
phrase of the conversation's user messages, so every run succeeds. `bench_live_test.exs`
runs the plan, the runs, the limits and the history against it, and the TUI's
`bench_cli_test.exs` the command line, with a config file naming it. It needs only OTP and
Elixir's `JSON`, so `elixir -r apps/troupe_core/test/support/fake_openai.exs -e
"Troupe.Test.FakeOpenAI.serve(port: 18080)"` runs one for an installed `troupe` to be
pointed at. On the same port it answers Anthropic's `/v1/messages` as the newest models do
(Decision 815): each answer after an empty thinking block signed over the conversation it
was made in, a 400 for a block sent back after that changed, or with the thinking-binding
beta and `drop_block` the block dropped, and a prompt cache read where a mark wrote it; a
provider of `type: anthropic` with its URL is one.

### The scratchpad's cost

Issue #616 asks whether a long session that writes and revises documents costs no more
with the scratchpad than without it, from its first compaction on. `scratchpad_session`
and `scratchpad_session_without` are that session: eight turns that write a migration plan
and a checklist, revise each, ask about them, and ask for the whole plan or checklist
again after each revision, on `build` with the scratchpad and on `build` with `show` and
`patch` denied and their sentence taken out. Their window is 24,000 tokens at
`compact_at` 0.75, four times the session's first prompt, whatever the model's own is.
A run's `since_compaction` is the measure; `--keep` leaves the logs to look into:

```
troupe bench --live --scenario scratchpad_session,scratchpad_session_without --repeat 3 --model claude-sonnet-5-5
```

On the 0.17.0-beta build with `patch` (Decision 895), Claude Sonnet 5.5 with its summaries
on Claude Haiku 4.5, two runs each, which is what a $3 cap paid for: a run costs up to its
$0.74 share, and the runs with the scratchpad came close to it. Tokens are fresh (sent
uncached or written to the cache) / read from the cache / output.

| | with the scratchpad | without |
|---|---:|---:|
| runs whose checks held | 2 of 2 | 2 of 2 |
| the agent's model calls; compactions | 21, 26; 7, 5 | 10, 9; 2, 5 |
| the whole run | $0.6574, $0.7557 | $0.4343, $0.5670 |
| its tokens | 123,630 / 225,821 / 38,825; 111,187 / 300,279 / 47,827 | 53,624 / 93,911 / 31,134; 96,833 / 68,208 / 39,305 |
| from the first compaction | $0.4789, $0.4938 | $0.2641, $0.3891 |
| the seventh and eighth turns | $0.1338, $0.2719 | $0.1106, $0.1661 |

The second run with the scratchpad reached its cap in its last turn, after its last plan
was written. **The session with the scratchpad cost more**, a third to a half more over the
run, and why is in the logs:

- **More calls, so more compactions.** Each revision is a `show` or `patch` call and then
  a reply, and after each compaction the agent reads a document back before it can patch
  it or answer about it (six and seven reads a run). Every call's prompt counts against
  the threshold, so the session compacts in the middle of a turn, more often, and each
  compaction writes the prompt to the cache again: the agent wrote 97,420 and 84,804
  tokens to the cache against 43,906 and 74,421.
- **Patches did not save output here.** The agent's output was 29,680 tokens against
  28,073 and 29,670 (the second run's 43,635 holds two cut replies). A revision of many
  places was a dozen patches: one turn's thirteen took 6,169 output tokens, where the whole
  revised plan as a reply took 5,465 and 6,590.
- **"Give the whole plan again" was shown whole again** in four revisions of eight. Two of
  those shows were cut at 8,192 output tokens ($0.19 of the second run): one went on in
  parts as the answer to the cut call says, one asked again whole and fit.
- **The window is still small for this session.** The session without the scratchpad
  compacted after nearly every turn too in its second run: its tail after a compaction
  holds two whole plans. A window where a compaction is rare against the calls after it,
  the one place the pointers save money, needs a session several times as long as this,
  which a $3 cap does not pay for three times each.

From these runs the maintainer decided that the scratchpad is not where an answer goes by
default: an agent uses it only when the person asks for a document or the answer would
run past about 80 lines, and answers in the reply otherwise (Decision 895). No live run
has measured that wording yet; the offline `tool_calls` turn checks that it reaches the
model.

## What is not here yet

- **The nightly.** The live bench is on demand. Decision 773 says how the nightly should
  run it; wiring it in is a change to `.github/workflows/live.yml` of its own.
- **Lifecycle across a daemon restart**, dormancy, and the budget's own question: scenarios
  #390 named and did not build.
- **A benchmark of models at scale.** The `standard` suite's ten tasks compare one build or
  model with another on the same work; they do not rank models as hundreds of tasks from
  real repositories do, and the bench runs only this harness, so another harness on the
  same model is not in the comparison.
