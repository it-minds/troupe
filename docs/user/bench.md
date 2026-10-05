# What a task costs on your setup

`troupe bench --live` runs tasks against your own provider and model, each with an
outcome a script checks afterwards, and says whether they got done, what each one cost,
and how long each model call and each tool call took. It is how you find out whether your
setup works and what a turn costs on it before you find out from the bill, and how you
compare two models, or two versions of Troupe, on the same work. It never runs in CI, and
nothing runs until you have seen the most it can spend and said yes.

There are two suites. `smoke`, four small tasks, is what runs unless you say otherwise:
the cheapest answer to "does it work here, and what does it cost". `standard` adds six
that look more like work, and is the one to compare models or builds with.

`troupe bench` without `--live` is the offline suite, which costs nothing and is what CI
holds every change to ([the bench](../developer/bench.md)).

## Running it

```
troupe bench --live                          # the smoke suite, each task once, your default model
troupe bench --live --suite standard --repeat 3   # ten tasks, three runs each: a score worth comparing
troupe bench --live --scenario fix_test,large_log # only these
troupe bench --live --model gateway/model-b  # another model you have set up
troupe bench --live --keep runs              # keep each run's workspace and session log in runs/
troupe bench --live --yes --json live.json --md live.md
troupe bench --compare                       # the last bench against the one before it
```

It needs a model set up (`troupe config`); without one, or with a key it cannot read, it
says so and runs nothing. Three tasks check their outcome with `elixir`, and are left out,
with a line saying so, on a machine that does not have it on the `PATH`.

| task | suite | what it asks | what is checked |
|---|---|---|---|
| `write_file` | smoke | write `hello.txt` with one given line | the file holds that line |
| `fix_test` | smoke | make a failing test pass without changing the test | `elixir calc_test.exs` exits 0, and the test file is as it was |
| `delegate` | smoke | hand a question to an `explore` subagent, write its answer to a file | the file holds the answer, and the agent delegated rather than read |
| `recover` | smoke | read a settings file that is not there, fall back to a default | the file holds the default, and the read failed |
| `rename_symbol` | standard | rename a function in its module and everywhere it is called, in two other files | `elixir shop_test.exs` exits 0, the old name is in no file, the test is as it was |
| `implement_spec` | standard | write a Roman numeral encoder from its documentation | `elixir roman_test.exs` exits 0, and the test is as it was |
| `large_log` | standard | count the lines of a 480 kB log with a given level and code | the count is right; neither the level nor the code alone gives it |
| `precise_edit` | standard | change one setting in a 1,560-line file, where another section has the same line | the file is exactly as wanted, and was edited rather than written whole |
| `follow_steps` | standard | do the three steps a file in the workspace lists | each step's file holds what it should |
| `answer_only` | standard | answer a sum without using a tool | the answer is right, and no tool was called |

`answer_only` is the least a turn can cost on your setup: one model call, which still
carries the system prompt and every tool's definition. `large_log` is the most a careless
one can: a model that reads the log rather than searching it sends the read with every
call after, which the run's largest tool result shows.

## What it may spend

Before anything starts it prints what it will do, and the most it can spend:

```
troupe bench --live: 4 scenarios, 1 run each, against openai/model-a.
Each run has a scratch directory and a session of its own, with every tool allowed, the shell among them, and may make 12 model calls, send 200,000 tokens and receive 24,000, in 240 s.
At $3.00/$15 a million tokens, a run costs at most $0.96, so this costs at most $3.84 in all.
Each run is added to /home/you/.local/state/troupe/bench/results.jsonl.
Spend up to $3.84 on openai/model-a? [y/N]
```

The cap is a run's limits at the model's price, times the runs. The limits are fixed, and
are those of the nightly's own checks against a real model: far above what any of the four
tasks needs, far below a session's defaults. The price is the one Troupe prices every call
at: the provider's catalog, else `models.prices` in your config. A model nothing prices
has its cap in tokens instead, and the question says there is no price to hold it to; set
`models.prices` for it ([configuration](configuration.md)) to have it in money.

It asks at a terminal, and any answer but `y` or `yes` runs nothing. With no terminal to
ask in, from a script or a pipe, it runs nothing unless you pass `--yes`, which says yes
beforehand. While it runs, each run is held to its limits by the harness, and the
bench stops it when it reaches its share of the cap or has gone on past its wall clock, so
a run can pass its share by at most the one model call in flight when it was reached.

Every tool is allowed in a run, so that no task waits for an approval nobody is there to
give. The run's directory is a scratch one, but that is not a sandbox: a model can run a
command that reaches outside it, as it can in any session where you approve everything. Run
it as you would such a session.

## What it reads, and what it keeps

From your configuration it takes where a model call goes and nothing else: the provider,
its URL and key, your models and their prices. Each run has its own config and state
directories, so your agents, skills, instruction files and sessions are not in it, and
nothing it does lands among them. The key is handed to each run in memory; it is never
written down or printed.

Every run is added, as it ends, to a history in your state directory:
`~/.local/state/troupe/bench/results.jsonl` (`$XDG_STATE_HOME/troupe/...` where that is
set), `%LOCALAPPDATA%\troupe\bench\results.jsonl` on Windows. A line is what one run did
and cost, with the version and the model, never what it was sent.

## Reading the table

```
| scenario | measure | value | |
| --- | --- | ---: | --- |
| write_file | runs that succeeded | 1.0 |  |
| write_file | median cost | $0.0043 |  |
| write_file | worst cost | $0.0051 |  |
| write_file | median wall clock | 3120 ms |  |
| write_file | median model call | 1405 ms |  |
| write_file | median time to first token | 610 ms |  |
...
| delegate | the root agent called delegate (3 of 3) | yes | ok |
| delegate | outcome: answer.txt holds what was asked for | 3 of 3 | ok |

troupe bench 0.8.2-beta, live against openai/model-a: 4 scenarios, 3 runs each, every run succeeded.
```

A run **succeeded** when it ended by itself, its outcome held, and every check held. A
run whose last allowed model call was its answer ended by itself; one stopped with a tool
call still to make did not. The measures are taken over a task's runs: the share that
succeeded and its 95% interval, the median and worst cost, the cost per success, and the
medians of the wall clock, of a model call from request to its last token, of the time to
its first token, of the model calls, of the tokens each way and of each run's largest tool
result. None is held to a budget: what a model does varies from run to run, and that is
not a regression. Under the table every run is added up:

```
| 10 scenarios together | |
| --- | ---: |
| runs that succeeded | 27 of 30, 0.9 (95% interval 0.744 to 0.965) |
| cost | $0.6120 in all, $0.0204 a run, $0.0227 a success |
| tokens | 412880 in, 0 cached, 6120 out; 15519 a success |
| model calls | 142 |
| wall clock | 312000 ms in all, the median run 4100 ms |
```

The interval is where the success rate probably lies: three runs that all succeeded put it
only above 0.43, thirty above 0.88. The cost per success is everything the runs cost, the
failed ones too, over the ones that succeeded: the price of getting the work done once.
A line under it says which tasks failed, and how; standard error has a line for each run
as it ends.

`troupe bench --live` exits 0 when every run succeeded, 1 when one did not, and 2 when it
ran nothing.

One run of each task is the cheapest answer to "does it work here, and what does it cost".
To compare, run each three times or more: a success rate of one run is a coin toss.

## The report

`--json FILE` writes the report, the same schema `troupe bench` writes, with `"mode":
"live"`; `--json` alone prints it instead of the table. Each run has its own record: the
outcome, the stop reason, the turns, model calls, input, cached and output tokens, the cost,
the wall clock, the provider's retries, compactions, approvals, each tool by name with its
calls, failures and time, each tool call in order with its time, the size of its result
and whether that was cut, and each model call with its agent, what its prompt was made
of, its tokens, cost, latency and time to first token. The report's `summary` adds every
run up. [The bench](../developer/bench.md#the-report-schema-1) has every field.
`--md FILE` writes the table to a file as well.

`--keep DIR` leaves each run's workspace and state directory under
`DIR/<when the bench started>/<task>-<run>`, the session log (`events.jsonl`) among them,
to see what a run did. Nothing is kept without it, since a run's log holds what it was
sent.

## Comparing

`troupe bench --compare` puts the last bench beside, for each task it ran, that task's last
runs before it:

```
| scenario | measure | then | now | change |
| --- | --- | ---: | ---: | ---: |
| write_file | runs | 3, 0.8.1-beta, openai/model-a | 3, 0.8.2-beta, openai/model-a |  |
| write_file | runs that succeeded | 1.0 | 1.0 | 0.0 |
| write_file | median cost | $0.0061 | $0.0043 | -30% |
...
```

`--compare VERSION` and `--compare MODEL` put it beside the last runs of that version, or of
that model, instead. So two models are compared on the same work with:

```
troupe bench --live --suite standard --repeat 3 --model gateway/model-a
troupe bench --live --suite standard --repeat 3 --model gateway/model-b --compare gateway/model-a
```

When the two benches share more than one task, `all` rows under the table set them
together side by side: the share that succeeded, the cost per success and per run, the
median run's wall clock and the tokens per success. The cheaper model is the one that
costs less per success, not per run.
