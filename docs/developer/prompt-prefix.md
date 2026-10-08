# What changes in front of a prompt (issue #465)

Anthropic's newest models (Claude Fable 5.1, Opus 5.5 and Sonnet 5.5) bind each thinking
block to the conversation it was made in: the model, the system prompt, the tools and
every message before it. A block sent back after any of those changed is refused with a
400 on an account created on or after 2026-08-31. Troupe changes that conversation between
turns, and since Decision 805 each such refusal costs a refused request and the same call
sent again without any thinking. The same edits make every provider that caches write the
conversation behind them to the cache again.

The issue names two ways out and asks for numbers before one is chosen. Both are built,
each behind a setting that is off unless set (Decision 815), so a live bench can run each
and the log of any session can say how often it would have mattered. This page says what
each does and costs, gives the offline numbers, answers the gateway question, and gives
the numbers from a live run on Claude Opus 5.5 with the commands that produce them.

## What changes today

| What | When | Decision |
|---|---|---|
| the task list in the system prompt | the first call of a turn after the list changed | 792 |
| the instruction files and the brief in the system prompt | the first call of a turn after a file was edited, or after the turn before worked in a directory with its own `AGENTS.md` | 798 |
| the goal in the system prompt | the call after it was set or cleared | 678 |
| the `plan` prompt added to the profile's | an `AI?` watch turn | |
| the tools | the call after the task list's tools are first offered: once there is a list, or after ten calls of a turn | 793 |
| the conversation | a compaction, which keeps a tail of it | 774 |

On an account the check is enforced for, every call after one of these that carries a
block from before it is refused, and sent again with no thinking at all. Troupe's history
keeps those blocks, so the refusal repeats on every later call of the session until a
compaction: two requests a call, and no reasoning from before the change, nor any the
turn makes after it, reaches the model. On an account that is not enforced the blocks
reach the model as they are.

## Turning each on

| Option | Setting | For one shell, or one bench |
|---|---|---|
| 1. Anthropic's thinking-binding beta | `thinking_binding: drop_block` | `TROUPE_THINKING_BINDING=drop_block` |
| 2. A stable system prompt | `system_prompt: stable` | `TROUPE_SYSTEM_PROMPT=stable` |

Both may be on together. Off (`default`, `per_turn`), no request changes: the provider
tests, the prompt tests and `mix troupe.bench` give what they gave before.

## Option 1: `drop_block`

A request that hands thinking back sends `anthropic-beta:
thinking-binding-controls-2026-08-01` and, in its `thinking` field,
`block_binding: {prefix_mismatch_behavior: "drop_block"}`: beside the adaptive or budget
form an effort asks for, or alone with `type: adaptive` when no effort is set (what a
model that thinks unasked does with no field). The API then drops the first block whose
conversation changed, and every thinking block after it, instead of refusing, and says
which in the response's `input_transformations`. A request that hands nothing back sends
neither.

What it costs:

- **No refused request**, and no second round trip: one request a call where today an
  enforced account makes two.
- **No reasoning is kept that today's resend loses.** The drop is for that request only.
  Troupe goes on sending the stale blocks, so every later call drops them again, and with
  them every block made after them, the turn's own included: the stand-in's second turn
  dropped 3 blocks and then 4.
- **It turns the check on for an account that is not enforced.** For an account created
  before 2026-08-31, setting the field at all opts the request into the check, so blocks
  that reach the model today are dropped. Only an enforced account gains.
- **The cache** is read up to the first dropped block, as after today's resend.
- **Anthropic's wire only.** A provider of `type: openai`, a LiteLLM gateway's
  `/chat/completions` among them, sends no thinking blocks back at all (its adapter hands
  back only its own provider's `reasoning_content`), so there is nothing to bind there.

What it points at, and is not built: once a response says blocks were dropped, or a call
was refused, Troupe could stop sending the leading run of blocks from before the change.
The API allows taking out a leading run, oldest first, and the blocks made after it then
stay valid; with or without the beta that would keep the reasoning a turn makes after a
change.

## Option 2: `system_prompt: stable`

The system prompt leaves out the instruction files and the brief, the goal and the task
list, and is the same on every call of the session. Each of those goes, as a section of a
`<turn_context>` block, after what the conversation's last user message holds, on the call
where it differs from the copy the conversation already carries: with the person's input
as a turn begins, after a tool's results when a goal or a compaction comes in the middle of
one. The block stays where it was put, so each request is the one before with something
added, which is what keeps a kept block valid and the cached conversation readable. A
section that emptied says so. The log's `llm_request.turn_context` names the sections a
call carried.

What it costs:

- **The prefix still changes** where the system prompt was not the cause: the tools when
  the task list's are first offered (793), a compaction, an `AI?` turn's `plan` prompt,
  and an agent restarted in the middle of a session, whose blocks are kept in the agent and
  not the log, so its next call goes without them once and puts the sections again.
- **Tokens.** A changed section is added to the conversation each time it changes, and
  stays there until a compaction: the task list once for each turn that began with a new
  one, the instruction files when a turn brings in a nested file or one was edited. Today
  they are rewritten in place in the system prompt, which adds nothing but writes
  everything behind it to the cache again.
- **How well instructions are followed.** In the system prompt the instruction files speak
  with the operator's voice; in the turn they are text in the person's message, read last
  before the model answers. A model may weigh them less, or more, than it does now. The
  live bench's `follow_up` is what says: its outcome is the second turn's file under the
  rules of both instruction files, one sent with the first turn and one with the second,
  and its check the first turn's file under the root's rule. Its success rate with
  `stable` against without, over five runs or more, is the measure, and `smoke` or
  `standard` with and without says whether tasks without instruction files moved. If
  `stable` follows them less well, Anthropic's mid-conversation `role: "system"` message
  carries operator authority without editing the prefix, on every model of the three but
  not on Sonnet 5 and not on an OpenAI-compatible wire; it is not built.
- **Every wire.** It is how the prompt is assembled, so an OpenAI-compatible provider that
  caches by prefix gains the same.

## What the log says, and the counter

Per model call (PROTOCOL.md): `llm_request.system_changed` and `tools_changed` against the
agent's call before; `llm_request.turn_context` with `stable`; and on `llm_response`,
`thinking_resent: true` when the call was refused as bound to another conversation and
sent again (805's path, written nowhere before), and `thinking_dropped`, the blocks the beta
dropped.

`Troupe.Bench.Prefix.count/1` adds them up. A live bench run carries it as `prefix`, the
report's `summary.prefix` adds the runs up, and the table prints a `prompt prefix` row.
Over session logs:

```sh
mix troupe.prefix                      # the state directory's sessions
mix troupe.prefix PATH...              # a session's events.jsonl, or directories of them
mix troupe.prefix --json PATH...
```

A log written before these fields has its system prompt and tools changes judged by
`prompt_bytes`' sizes (Decision 769), counted as `inferred`; that misses an edit that
keeps the size, so it is a floor. No log written before 0.9.1 says a call was sent again.
Pointed at a person's own sessions, it says how often their prompts changed in front of
what had been sent: the "how often today" the issue asks for.

## Offline numbers

The installed build's `troupe bench --live --scenario follow_up` against the stand-in
(`apps/troupe_core/test/support/fake_openai.exs`, served with `elixir`) as Claude Opus 5.5
on an enforced account: each answer comes after an empty thinking block signed over its
conversation, a block sent back after that changed is refused (or dropped, with the beta),
and the prompt cache is read where a mark wrote it. A token is four bytes of a block's
JSON, so the token figures are the stand-in's; the counts and the ratios are what to read.
One run each, each against a stand-in of its own so each starts with a cold cache,
Windows, 2026-10-08. `follow_up` makes five model calls: three in the first turn, two in
the second, which begins with `docs/AGENTS.md` among the instruction files.

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
  for five answers. The resend reads only the tools from the cache (2,830): the system
  prompt in front of the conversation changed.
- `drop_block` makes the same five answers with five requests, and reads the cache no
  better: the blocks it drops change the prefix from the first of them. The 3 then 4
  blocks are every block the session had, the turn's own included.
- `stable` changes nothing in front of what was sent: no refusal, no drop, and the second
  turn's first call reads all of the call before (3,704) and writes only the new turn
  with its instruction file (414). The first turn's prompt is 56 tokens larger, the
  `<turn_context>` wrapper, so its gain is in later turns: here 10% more read from the
  cache and 9% fewer tokens written or fresh over two turns.
- Both together is `stable`: with nothing stale, the beta has nothing to drop.
- The stand-in's thinking blocks are a signature and nothing else. A real model's carry
  its reasoning, billed as input when sent back and read from the cache after; what the
  default and `drop_block` lose on every call after a change, and `stable` keeps, is
  larger there than here, in tokens and in what the model goes on from.

`BenchLiveTest` runs the same three cases against the stand-in on every build.

## The gateway question

Does a gateway in front of Anthropic pass the beta header and the new field on? For
LiteLLM, from its documentation and source as read on 2026-10-08, not tried against one:

- **`/v1/messages`**, LiteLLM's Anthropic-shaped endpoint, which a Troupe provider of
  `type: anthropic` with the gateway's URL speaks. The request-headers page says
  `anthropic-beta` "will always forward the header to the underlying model" on that
  endpoint ([docs.litellm.ai/docs/proxy/request_headers](https://docs.litellm.ai/docs/proxy/request_headers)),
  and the source's `_get_forwardable_headers` in `litellm/proxy/litellm_pre_call_utils.py`
  forwards `anthropic-beta` beside the `x-` headers. The Anthropic provider page says the
  `/v1/messages` route passes `thinking` "through unchanged"
  ([docs.litellm.ai/docs/providers/anthropic](https://docs.litellm.ai/docs/providers/anthropic)),
  so `thinking.block_binding` should reach Anthropic as sent. Both options work there.
- **`/chat/completions`**, which a Troupe provider of `type: openai` speaks, the usual way
  to a LiteLLM gateway: `anthropic-beta` is forwarded only for a model configured with
  `forward_client_headers_to_llm_api` (same page). Troupe's OpenAI-compatible adapter sends
  neither the header nor the field, and no Anthropic thinking blocks, so option 1 does not
  apply there; option 2 does, and helps that gateway's prompt cache.
- **Behind the gateway**, the controls are offered on Anthropic's API, its platform on
  AWS, Amazon Bedrock (as the `anthropic_beta` body field rather than a header) and Google
  Vertex AI; Microsoft Foundry is unconfirmed (Anthropic's documentation). A gateway that
  routes to Bedrock has to carry the beta into the body; whether LiteLLM does was not
  checked.

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
- whether the account the live run uses is enforced: with the baseline, refusals mean it
  is; none, while `drop_block` drops blocks, means it is not. (The live run below answers
  it: not enforced.)

## Live numbers

Claude Opus 5.5 on Anthropic's API, with this branch's installed build, on Windows,
2026-10-08. Each configuration ran `follow_up` five times. The bench's config carried Opus
5.5's list prices: $4 in, $20 out, $0.20 for a cache read and $5 for a cache write, per
million tokens. The 20 runs cost $0.52 in all. The smoke suite, with and without
`stable`, was not run: each of those two runs had a cap of $17.76, and that did not fit
the run's $30 limit.

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
  4 blocks, one call in each of four runs, and without the field those blocks reach the
  model. On an account like this, created before 2026-08-31, option 1 saves no requests.
  It costs reasoning instead.
- **Option 2 kept the cache whole.** In the baseline the system prompt changed once in
  every run: the second turn's instruction file joined it. That turn's first call then
  sent 1,463 tokens uncached and read 4,319 from the cache. With `stable` it sent 614 and
  read 5,535. Over the five runs, `stable` sent 46% fewer uncached tokens and cost 25%
  less ($0.112 against $0.149).
- **Instructions were followed in every run.** `follow_up`'s checks held in every run of
  every configuration, including the root's rule after `docs/AGENTS.md` joined. Moving
  the instruction files into `<turn_context>` did not make Opus 5.5 miss either file in
  this scenario. That is one scenario and five runs: a signal, not a measure of
  instruction following in general.
- **Both together behaved as `stable`.** Nothing went stale, so the beta had nothing to
  drop.
- **Not measured live:**
  - an enforced account, where the baseline would be refused and sent again;
  - Sonnet 5.5 and Fable 5.1;
  - tasks with no instruction files (the smoke suite);
  - a session longer than two turns.

To run it again, in PowerShell, where `$m` is the model as `troupe models` addresses it:

```powershell
$m = "anthropic/claude-opus-5-5"
$out = "$env:TEMP\troupe-465"; New-Item -ItemType Directory -Force $out | Out-Null
Remove-Item Env:\TROUPE_THINKING_BINDING, Env:\TROUPE_SYSTEM_PROMPT -ErrorAction SilentlyContinue

# The baseline, then each option, then both: follow_up five times each.
troupe bench --live --scenario follow_up --repeat 5 --model $m --yes --keep "$out\keep-baseline" --json "$out\baseline.json"
$env:TROUPE_THINKING_BINDING = "drop_block"
troupe bench --live --scenario follow_up --repeat 5 --model $m --yes --keep "$out\keep-drop_block" --json "$out\drop_block.json"
Remove-Item Env:\TROUPE_THINKING_BINDING
$env:TROUPE_SYSTEM_PROMPT = "stable"
troupe bench --live --scenario follow_up --repeat 5 --model $m --yes --keep "$out\keep-stable" --json "$out\stable.json"
$env:TROUPE_THINKING_BINDING = "drop_block"
troupe bench --live --scenario follow_up --repeat 5 --model $m --yes --keep "$out\keep-both" --json "$out\both.json"
Remove-Item Env:\TROUPE_THINKING_BINDING, Env:\TROUPE_SYSTEM_PROMPT

# Whether a stable prompt moves tasks with no instruction files: smoke, with and without.
troupe bench --live --repeat 3 --model $m --yes --json "$out\smoke-baseline.json"
$env:TROUPE_SYSTEM_PROMPT = "stable"
troupe bench --live --repeat 3 --model $m --yes --json "$out\smoke-stable.json"
Remove-Item Env:\TROUPE_SYSTEM_PROMPT
```

Each run prints its cap before it starts. Reading the numbers, a row a configuration:

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

`experiment` on each report says which settings it ran with; each run's own `prefix` and
`calls[]` (cache reads per call) are under `scenarios[].runs[]`, and the table `troupe bench`
prints ends with the same `prompt prefix` row. `mix troupe.prefix "$out\keep-baseline"`
(and the others) from a checkout counts the kept session logs one by one.
