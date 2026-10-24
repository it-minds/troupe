# What changes in front of a prompt: the measurements (#465)

The numbers behind [what changes in front of a prompt](../developer/prompt-prefix.md),
kept as they were measured: against the stand-in, then live on Anthropic's API, before and
after the stable system prompt became the default (Decision 863) and the task list's tools
came from the first call (Decision 867). What the settings do, and what is left, is on
that page; these are the record of how it was decided.

## Offline numbers

The installed build's `troupe bench --live --scenario follow_up` against the stand-in
(`apps/troupe_core/test/support/fake_openai.exs`, served with `elixir`) as Claude Opus 5.5
on an enforced account: each answer follows an empty thinking block signed over its
conversation, a block sent back after that changed is refused (or dropped, with the beta),
and the cache is read where a mark wrote it. A token is four bytes of a block's JSON, so
read the counts and ratios, not the token figures. One run each, each against its own
stand-in so each starts cold, Windows, 2026-10-08. `follow_up` makes five model calls:
three in the first turn, two in the second, which brings in `docs/AGENTS.md`.

| | baseline | `drop_block` | `stable` | both |
|---|---:|---:|---:|---:|
| requests | 7 | 5 | 5 | 5 |
| refused, and sent again without thinking | 2 | 0 | 0 | 0 |
| thinking blocks dropped | 0 | 7 (3, then 4) | 0 | 0 |
| calls whose system prompt changed | 1 | 1 | 0 | 0 |
| turn contexts sent | 0 | 0 | 2 | 2 |
| tokens written to the cache, or fresh | 4,618 | 4,620 | 4,215 | 4,213 |
| tokens read from the cache | 13,581 | 13,584 | 14,951 | 14,946 |
| the second turn's first call: written / read | 904 / 2,830 | 905 / 2,830 | 414 / 3,704 | 413 / 3,703 |
| cost at Opus 5.5's prices | $0.0268 | $0.0269 | $0.0251 | $0.0251 |
| outcome and checks | held | held | held | held |

What they say:

- By default the second turn's two calls are each refused and sent again: seven requests
  for five answers. The resend reads only the tools from the cache (2,830), since the
  system prompt in front of the conversation changed.
- `drop_block` makes the five answers with five requests, and reads the cache no better:
  the dropped blocks change the prefix from the first of them. The 3 then 4 blocks are
  every block the session had, the turn's own included.
- `stable` changes nothing in front of what was sent: no refusal, no drop, and the second
  turn's first call reads all of the call before (3,704) and writes only the new turn with
  its instruction file (414). The first turn's prompt is 56 tokens larger (the
  `<turn_context>` wrapper), so the gain is in later turns: here 10% more read from the
  cache and 9% fewer tokens written or fresh over two turns.
- Both together is `stable`: with nothing stale, the beta has nothing to drop.
- The stand-in's thinking blocks are only a signature. A real model's carry its reasoning,
  billed as input when sent back and read from the cache after, so what the default and
  `drop_block` lose after a change, and `stable` keeps, is larger there, in tokens and in
  what the model goes on from.

`BenchLiveTest` runs the same three cases against the stand-in on every build.

## What was not confirmed without calling the API

From Anthropic's documentation as read on 2026-10-08, none of it tried against the API:

- that a refused block's 400 reads ``Invalid `signature` in `thinking` block`` (805 relies
  on it) and that `drop_block` drops rather than refuses, and drops every thinking block
  after the first stale one;
- that `input_transformations` comes on a stream's `message_start` with entries of type
  `thinking_dropped`;
- that `thinking: {type: "adaptive", block_binding: ...}` with no effort is taken by each
  of the three models and thinks as no field does (the documentation says the object is
  accepted beside `adaptive` and `enabled`, and that Sonnet 5.5 refuses it only beside its
  `between_tools`, which Troupe never sends);
- whether the live run's account is enforced: with the baseline, refusals mean it is;
  none, while `drop_block` drops blocks, means it is not. (The live run below says: not
  enforced.)

## Live numbers with the new defaults

The installed build of Decision 863, on Windows, 2026-10-11:
`troupe bench --live --scenario task_list,follow_up --repeat 5` on Claude Sonnet 5.5 and
Opus 5.5, on one account that is not enforced, priced as the earlier runs (Sonnet 5.5 $2
in, $10 out, $0.20 cache read, $2.50 cache write per million; Opus 5.5 $4, $20, $0.20,
$5). Three configurations: `stable` (the default), `stable` with `thinking_binding: error`
(an enforced account, asked for), and `per_turn` with `error` (0.12.0's prompt on an
enforced account). The 60 runs cost $1.53.

`task_list` on Sonnet 5.5, five runs, beside the 0.11.0 baseline from #465's measurement:

| | 0.11.0 baseline | `stable` | `stable` + `error` | `per_turn` + `error` |
|---|---:|---:|---:|---:|
| model calls | 30 | 30 | 30 | 30 |
| refused, and sent again without thinking | 0 | 0 | 0 | 20 |
| calls whose system prompt changed | 10 | 0 | 0 | 10 |
| tokens written to the cache | 17,200 | 15,397 ¹ | 11,269 | 20,666 ¹ |
| tokens read from the cache | 145,509 | 151,743 | 156,015 | 141,257 |
| output tokens | 3,622 | 3,655 | 3,708 | 5,858 |
| cost, median run | $0.0215 | $0.0192 | $0.0195 | $0.0259 |
| median wall clock | 9.5 s | 8.3 s | 8.8 s | 13.1 s |

¹ The configuration's first run wrote the tools to the cache from cold, about 4,000
tokens more than a warm run.

- **Nothing in front of what was sent changed** with `stable`, on either model or
  scenario: no system prompt change and, with `error`, no refusal in 40 runs.
- **`per_turn` + `error` is the enforced column**, from configuration: 20 refusals in
  `task_list` on both models, as the patched build's measurement had, and 60% more output
  on Sonnet as the model worked the number out again.
- **The diagnosis header came on every refusal** (26 on Sonnet, 24 on Opus), streamed,
  and the log kept it: `kind=system_changed; pattern=system_rerendered; sections=system;
  changed_validated=system.0; position=at` in `follow_up`, and `changed_validated=system.1`
  in `task_list`, the task list's block behind the cache mark.
- **The task list's tools (#590) did not show:** no call of these scenarios is a turn's
  eleventh, and `task_list` runs on `plan`, which has the list's tools from its first call.
  `long_turn` (below) is the scenario that shows it.
- Every run's outcome and checks held. The full tables, `follow_up` and Opus 5.5 among
  them, are on #465.

## Live numbers for the task list's tools (#590)

`long_turn` is one turn of thirteen calls on `build` with no task list: the first call
works a number out without a tool, so its thinking goes back on every later call, then
twelve files are read one after another. Before, the list's tools came at the eleventh
call; after, on a binding model, they are there from the first (Decision 867). Claude
Sonnet 5.5 on an account that is not enforced, with `thinking_binding: error`, three runs
each, the installed build before and after the change, Windows, 2026-10-11, at Sonnet
5.5's prices as above:

| | before | after |
|---|---:|---:|
| runs that succeeded | 3 of 3 | 3 of 3 |
| model calls | 39 | 39 |
| refused, and sent again without thinking | 9 | 0 |
| HTTP requests | 48 | 39 |
| calls whose tools changed | 3 | 0 |
| tokens written to the cache | 20,657 ¹ | 5,615 |
| tokens read from the cache | 235,102 | 263,938 |
| output tokens | 3,075 | 2,695 |
| cost, median run | $0.0353 | $0.0316 |
| median wall clock | 22.4 s | 21.1 s |

¹ The first run wrote the prompt from cold, 5,905 tokens on its first call; a warm run
wrote 3,330, 1,580 of them at the eleventh call, against about 1,870 after.

- **Every call from the eleventh was refused once**, three a run, and the API's header
  said why on each: `kind=tools_changed; pattern=tool_set_changed; sections=tools;
  changed_validated=tools; position=at`. After, none was, and the tools never changed.
- **The median run cost 10% less** and wrote 44% less to the cache on a warm run: the
  eleventh call no longer writes the whole prompt again.
- **No run wrote a list**: offered from the first call, Sonnet 5.5 never called
  `todo_write` in this turn.

What the list's tools cost on short work, where they used not to be offered: the four
standard-suite tasks on which `qwen3-235b` wrote a list whenever it had the tool (Decision
793), `fix_test`, `rename_symbol`, `implement_spec` and `follow_steps`, three runs each:

| | before | after |
|---|---:|---:|
| runs that succeeded | 12 of 12 | 12 of 12 |
| model calls | 40 | 39 |
| `todo_write` calls | 0 | 0 |
| tokens written to the cache | 17,534 | 17,812 |
| tokens read from the cache | 231,836 | 240,950 |
| output tokens | 4,573 | 4,542 |
| cost, the twelve runs | $0.1361 | $0.1383 |

The two tools' definitions are read from the cache on every call, about 234 tokens a call;
each task's median run cost $0.0003 more (2 to 3%), and Sonnet 5.5 wrote no list for any.
The 32 runs, two compaction probes among them, cost $0.65. To run them again:
`troupe bench --live --scenario long_turn --repeat 3`, and
`--scenario fix_test,rename_symbol,implement_spec,follow_steps`, each with
`$env:TROUPE_THINKING_BINDING = "error"`.

Not measured live: a compaction whose kept tail holds a thinking block. Sonnet 5.5 thought
on the first and last call of `long_turn` only, so in two runs with a window small enough
to compact (three compactions before, seven after) the first call's block was always in
what the summary replaced, and no call after a compaction was refused. The stand-in, which
binds as the documentation says, is the proof for the tail (`BoundThinkingTest`).

## Live numbers before the stable default

Claude Opus 5.5 on Anthropic's API, this branch's installed build, Windows, 2026-10-08.
Each configuration ran `follow_up` five times, at Opus 5.5's list prices ($4 in, $20 out,
$0.20 cache read, $5 cache write, per million tokens). The 20 runs cost $0.52. The smoke
suite ran afterwards, with and without `stable` (below).

| | baseline | `drop_block` | `stable` | both |
|---|---:|---:|---:|---:|
| model calls (five runs) | 25 | 25 | 25 | 25 |
| refused, and sent again without thinking | 0 | 0 | 0 | 0 |
| thinking blocks dropped | 0 | 4 (in 4 calls) | 0 | 0 |
| calls whose system prompt changed | 5 | 5 | 0 | 0 |
| turn contexts sent | 0 | 0 | 10 | 10 |
| tokens sent uncached (fresh, or written to the cache) | 18,140 | 13,843 | 9,882 | 9,892 |
| tokens read from the cache | 121,060 | 125,376 | 133,877 | 133,864 |
| the second turn's first call, uncached / read (mean) | 1,463 / 4,319 | 1,458 / 4,319 | 614 / 5,535 | 620 / 5,533 |
| output tokens | 1,716 | 1,800 | 1,793 | 1,828 |
| cost of the five runs | $0.149 | $0.130 | $0.112 | $0.113 |
| median wall clock | 12.2 s | 10.8 s | 10.8 s | 13.0 s |
| outcome and both checks held | 5 of 5 | 5 of 5 | 5 of 5 | 5 of 5 |

What they say:

- **The account was not enforced.** The baseline was never refused. `drop_block` dropped
  4 blocks, one call in each of four runs, blocks that reach the model without the field.
  On such an account, created before 2026-08-31, option 1 saves no requests and costs
  reasoning instead.
- **Option 2 kept the cache whole.** In the baseline the system prompt changed once every
  run, when the second turn's instruction file joined it; that turn's first call sent 1,463
  tokens uncached and read 4,319 from the cache. With `stable` it sent 614 and read 5,535.
  Over the five runs, `stable` sent 46% fewer uncached tokens and cost 25% less ($0.112
  against $0.149).
- **Instructions were followed in every run** of every configuration, the root's rule
  after `docs/AGENTS.md` joined included: moving the instruction files into
  `<turn_context>` did not make Opus 5.5 miss either. One scenario and five runs is a
  signal, not a measure of instruction following in general.
- **Both together behaved as `stable`.** Nothing went stale, so the beta had nothing to
  drop.
- **Not measured live:** an enforced account, where the baseline would be refused and sent
  again; Sonnet 5.5 and Fable 5.1; a session longer than two turns.

The smoke suite is four one-turn tasks with no instruction files: `write_file`, `fix_test`,
`delegate` and `recover`, run three times each, with and without `stable`, on the same model
and build. The two runs cost $0.44.

| | baseline | `stable` |
|---|---:|---:|
| runs that succeeded | 12 of 12 | 12 of 12 |
| model calls | 42 | 42 |
| calls whose system prompt changed | 0 | 0 |
| tokens sent uncached (fresh, or written to the cache) | 22,661 | 16,762 |
| tokens read from the cache | 173,396 | 179,446 |
| output tokens | 4,149 | 4,282 |
| cost | $0.231 | $0.205 |
| median wall clock | 6.2 s | 5.8 s |

With one turn and no instruction files the system prompt never changes, so the two send
almost the same thing. Every task still succeeded under `stable`, which sent 26% fewer
uncached tokens and cost 11% less, most of it in `write_file` ($0.045 against $0.024); the
other three were within a few tenths of a cent.

To run it again, in PowerShell, with `$m` the model as `troupe models` addresses it. The
baseline is the 0.12.0 default, `per_turn` by name from 0.13.0 on:

```powershell
$m = "anthropic/claude-opus-5-5"
$out = "$env:TEMP\troupe-465"; New-Item -ItemType Directory -Force $out | Out-Null
$env:TROUPE_THINKING_BINDING = $null; $env:TROUPE_SYSTEM_PROMPT = $null

# The baseline, then each option, then both: follow_up five times each.
$env:TROUPE_SYSTEM_PROMPT = "per_turn"
troupe bench --live --scenario follow_up --repeat 5 --model $m --yes --keep "$out\keep-baseline" --json "$out\baseline.json"
$env:TROUPE_THINKING_BINDING = "drop_block"
troupe bench --live --scenario follow_up --repeat 5 --model $m --yes --keep "$out\keep-drop_block" --json "$out\drop_block.json"
$env:TROUPE_THINKING_BINDING = $null; $env:TROUPE_SYSTEM_PROMPT = $null
troupe bench --live --scenario follow_up --repeat 5 --model $m --yes --keep "$out\keep-stable" --json "$out\stable.json"
$env:TROUPE_THINKING_BINDING = "drop_block"
troupe bench --live --scenario follow_up --repeat 5 --model $m --yes --keep "$out\keep-both" --json "$out\both.json"
$env:TROUPE_THINKING_BINDING = $null

# Whether a stable prompt moves tasks with no instruction files: smoke, with each.
$env:TROUPE_SYSTEM_PROMPT = "per_turn"
troupe bench --live --repeat 3 --model $m --yes --json "$out\smoke-baseline.json"
$env:TROUPE_SYSTEM_PROMPT = $null
troupe bench --live --repeat 3 --model $m --yes --json "$out\smoke-stable.json"
```

An enforced account's column, on any account: the same runs with
`$env:TROUPE_THINKING_BINDING = "error"`. Each run prints its cap before it starts. The
numbers, a row a configuration:

```powershell
foreach ($n in "baseline", "drop_block", "stable", "both", "smoke-baseline", "smoke-stable") {
  $s = (Get-Content "$out\$n.json" -Raw | ConvertFrom-Json).summary
  [pscustomobject]@{
    run = $n; succeeded = "$($s.succeeded) of $($s.runs)"; cost = $s.cost_micros
    input = $s.input_tokens; cached = $s.cached_tokens; output = $s.output_tokens
    wall = $s.median_wall_ms; system = $s.prefix.system_changes; tools = $s.prefix.tools_changes
    resent = $s.prefix.thinking_resent; dropped = $s.prefix.thinking_dropped
  }
} | Format-Table
```

Each report's `experiment` names the settings it ran with; each run's `prefix` and
`calls[]` (cache reads per call) are under `scenarios[].runs[]`, and `troupe bench`'s table
ends with the same `prompt prefix` row. From a checkout, `mix troupe.prefix
"$out\keep-baseline"` (and the others) counts the kept session logs one by one.
