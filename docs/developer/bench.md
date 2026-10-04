# The bench

`troupe bench` measures the harness against budgets kept in this repository: how many
model calls a turn makes, what each prompt is made of and how it grows, where a tool result
is cut, when compaction comes, what a cancel leaves running, and whether the log is the
session (issue #390, Decision 772). It is about the harness's shape, not about what a model
answers.

The suite is offline. Each scenario runs against a scripted model, so it costs nothing,
needs no network, and gives the same numbers every time: the JSON of two runs of one build
is the same, byte for byte. CI fails when a number goes past its budget, so a change that
makes every turn more expensive is caught by the pull request that makes it, not by the
person who gets the bill.

## Running it

| where | command | what it gives |
|---|---|---|
| an installed `troupe` | `troupe bench`, `troupe bench --json` | the table, or the JSON report; exit 1 past a budget |
| a checkout | `mix troupe.bench [--json PATH]` | the table on standard output, the JSON in `PATH`; exit 1 past a budget |
| this machine's CI | `scripts/ci` | the step *bench within its budgets* |
| CI | the `lint` job of `ci.yml` | the table in the run's summary, the JSON as the `bench` artifact |

The suite takes a few seconds, and says how many under the table. `mix troupe.bench`
starts only `troupe_core`, so it runs from the umbrella's root with no database.

Each scenario runs in its own directories (workspace, config, state) under a new temporary
one, removed afterwards, and while it runs `TROUPE_CONFIG_HOME` and `TROUPE_STATE_HOME`
name them and opencode's two files name none: nothing of the person running it (their
config, keys, agents, skills, instruction files, sessions) reaches the prompt being
measured. The session is the harness's own, in the same VM; `troupe bench` never asks the
machine's daemon, which could be another version.

## Reading the table

```
| scenario | measure | value | budget | |
| --- | --- | ---: | ---: | --- |
| tool_calls | model calls in the turn | 31 calls | 31 | ok |
| tool_calls | largest prompt | 28376 bytes | 31000 | ok |
| tool_calls | growth per tool round trip | 484 bytes | 550 | ok |
...
| replay | outcome: hello.txt holds what was asked for | yes |  | ok |

troupe bench 0.8.1-beta, offline: 5 scenarios, every measure within its budget.
```

A row is a measure (a number, held to its budget when it has one) or a check (yes or no).
A budget is a **maximum**. A failed run ends `FAILED` and names each failure as
`scenario/measure`. A scenario that did not run says why in its first row.

The numbers are the same on every run of one build on one machine. Between machines they
can differ by a few hundred bytes, since the system prompt names the platform and the
`shell` tool names the host and the shell it found, among others (the tool definitions
were 11,814 bytes on Windows and 12,390 on Linux), and the budgets are set above both.

| scenario | what it shows |
|---|---|
| `tool_calls` | one turn of thirty `read_file` calls: thirty-one model calls, the system prompt and tool definitions each prompt starts with, the largest prompt, the growth per tool round trip, the input tokens over the turn (#389's number), the events the turn logs |
| `cut_output` | a `grep` result over `tool_output_limit`'s default is cut, kept, and read back with `read_output`; the cut result's size as the next prompt carries it |
| `compaction` | in a window of 16,000 tokens, compaction fires once the prompt reaches `compact_at`'s default share of it, never before, and within one round trip after; how much smaller the next prompt is |
| `cancel` | a cancel during a model call ends the call's task, no call is made afterwards, the agent rests and answers the next input |
| `replay` | the log on disk folds as the running log does, its hashes chain, a client replaying from the start sees each event once, a resumed agent has the conversation it had; and the file it was asked to write holds what was asked for |

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
  "tool_calls": { "model_calls": 31, "largest_prompt_bytes": 31000, "...": 0 },
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

A budget for a measure no scenario takes fails the run, so a renamed measure cannot leave a
budget holding nothing.

## The report: schema 1

The JSON is one object, keys sorted, so two runs diff line by line. Fields are added within
schema 1 and never renamed or removed; a change that has to is schema 2.

| field | |
|---|---|
| `schema` | `1` |
| `suite` | `"troupe bench"` |
| `mode` | `"offline"`; `"live"` is reserved for a run against a real model |
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
| `script` | the scripted model's steps: `{:text, t}`, `{:tools, [{name, input}]}`, `{:delay, ms, step}`, or a function of the request that answers one (how `cut_output` passes on the id the cut result named); a request with no tools is the summariser's and gets a summary |
| `outcome` | what a script can check afterwards, whoever answered: `{:file, path, content}`, or `{:command, argv}`, run in the workspace, passing on exit 0 (a test passing); or `nil` |
| `drive` | `nil` to type the prompt and wait for the turn to end, or a function that does something else (cancel half way) |
| `measure` | a function of the run answering `{metrics, checks}`: `{name, label, unit, value}` and `{name, label, passed?}` |

To add one: write it, add it to `all/0`, give its measures budgets, run `mix troupe.bench
--json a.json` twice and check the two files are the same. A number that differs between
runs (a time, a temporary path, a counter) is a measure that cannot be budgeted; leave it
out or make it fixed.

## What is not here yet

- **The live mode.** `troupe bench --live` is reserved and refuses. The live runner will
  run the same scenarios against the person's own provider, with no script, `--repeat N`
  times under a printed spending cap, into the same report with `mode: "live"` and the
  `null` fields filled, and keep a local history to compare runs with. It adds a runner,
  not a format.
- **The per-call prompt breakdown from the log.** Offline, the bench measures each request
  the model is handed. When the event log records what each prompt was made of (#389's
  first slice), a live run reads the same `calls[]` fields from there.
- **Lifecycle across a daemon restart**, dormancy, and the budget's own question: issue
  #390's other scenarios.
