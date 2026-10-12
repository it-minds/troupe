# What changes in front of a prompt (issue #465)

Anthropic's newest models (Claude Fable 5.1, Opus 5.5 and Sonnet 5.5) bind each thinking
block to the conversation it was made in: the model, the system prompt, the tools and
every message before it. A block sent back after any of those changed is refused with a
400 on an account created on or after 2026-08-31. Troupe changes that conversation between
turns, and since Decision 805 each such refusal costs a refused request and the same call
sent again without any thinking. The same edits make every provider that caches write the
conversation behind them to the cache again.

The issue names two ways out. Both were built behind settings (Decision 815) and measured
live, and the maintainer chose on 2026-10-11 (Decision 863):

- **Option 2, a stable system prompt, is the default.** What changes during a session
  reaches the model as turn context, appended to the conversation, and nothing rewrites
  the system prompt mid-session. `system_prompt: per_turn` is the old prompt, by name.
- **Option 1, Anthropic's beta, is an opt-in fallback** (`thinking_binding: drop_block`)
  for an account that refuses a stale block, on the prefix changes option 2 cannot remove:
  an `AI?` turn's `plan` prompt, a profile or model switch. The largest such change, the
  task list's tools offered at a turn's eleventh call (Decision 793), and the tail a
  compaction keeps are gone on a model that binds its thinking (#590, Decision 867), and
  so is a `/loop`'s `goal_complete`; an MCP tool that comes or goes waits for the next
  turn on every model (#606, Decision 871), and so does a skill file added or removed,
  while an agent restarted in the middle of a turn offers what the turn began with (#617,
  Decision 876).
- **`thinking_binding: error`** asks the API for the refusal an enforced account gets, on
  any account, so that refusal can be measured without a patched build (#591).

This page says what each does and costs, gives the offline numbers, answers the gateway
question, and gives the numbers from the live runs with the commands that produce them.

## What changes in front of a prompt

| What | When | Decision | With `stable` |
|---|---|---|---|
| the task list in the system prompt | the first call of a turn after the list changed | 792 | turn context |
| the instruction files and the brief in the system prompt | the first call of a turn after a file was edited, or after the turn before worked in a directory with its own `AGENTS.md` | 798 | turn context |
| the goal in the system prompt | the call after it was set or cleared | 678 | turn context |
| the `plan` prompt added to the profile's | an `AI?` watch turn | | changes |
| the tools | the call after the task list's tools are first offered: once there is a list, or after ten calls of a turn | 793 | the same on a model that binds its thinking: the list's tools from the first call (867); changes on others |
| `goal_complete` among the tools | the first call of a `/loop` turn, and of the turn after one | 679 | the same on a model that binds its thinking: offered on every call of the root agent, refused outside a loop (871); changes on others |
| an MCP server's tools, or those a person's client offers | the first call of the turn after a server came back with another list, a sign-in completed, or a person's tools came or went | 654, 741, 861 | changes, at a turn's first call and never in the middle of one (871) |
| the skills, in the `skill` tool and the system prompt | the first call of the turn after a skill file was added, removed or renamed | 700 | changes, at a turn's first call and never in the middle of one (876) |
| the tools and skills a turn held | an agent restarted in the middle of the turn | 871 | the same: what the turn's first call held is in the log (876) |
| the conversation | a compaction, which keeps a tail of it | 774 | changes; on a model that binds its thinking the tail goes without the blocks made in front of what the summary replaced, so no later call is refused (867); a scratchpad document is left out for a pointer there and nowhere else (878) |
| the turn context put before | an agent restarted, or a session resumed | 815 | the same: the blocks are in the log (863) |

On an account the check is enforced for, every call after one of these that carries a
block from before it is refused, and sent again with no thinking at all. Troupe's history
keeps those blocks, so the refusal repeats on every later call of the session until a
compaction: two requests a call, and no reasoning from before the change, nor any the
turn makes after it, reaches the model. On an account that is not enforced the blocks
reach the model as they are.

## The settings

| Setting | Values, the default first | For one shell, or one bench |
|---|---|---|
| `system_prompt` | `stable` (option 2); `per_turn`, the prompt as it was before 0.13.0 | `TROUPE_SYSTEM_PROMPT=per_turn` |
| `thinking_binding` | `default`, nothing sent; `drop_block` (option 1); `error`, the refusal asked for | `TROUPE_THINKING_BINDING=drop_block` |

Both may be set together. `system_prompt` from a file or the environment is read as it is
written: a person's `per_turn` stays `per_turn`, and a file that never set it is `stable`
from 0.13.0 on. With `per_turn` and `default`, no request changes from what 0.12.0 sent.

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

`thinking_binding: error` sends the same header and `block_binding:
{prefix_mismatch_behavior: "error"}`: the API refuses a stale block with the 400 an
enforced account gets without the beta, and Troupe answers it as it answers that one, by
sending the call once more without its thinking (Decision 805). On an account that is not
enforced, it is how the enforced column of a live bench is measured; on one that is, it
changes nothing but the header.

What it points at, and is not built: once a response says blocks were dropped, or a call
was refused, Troupe could stop sending the leading run of blocks from before the change.
The API allows taking out a leading run, oldest first, and the blocks made after it then
stay valid; with or without the beta that would keep the reasoning a turn makes after a
change.

## Option 2: `system_prompt: stable`, the default

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

- **The prefix still changes** where the system prompt was not the cause: a compaction,
  an `AI?` turn's `plan` prompt, an MCP tool that comes or goes (at the next turn, 871),
  and on a model that does not bind its thinking the tools when the task list's are first
  offered (793) and `goal_complete` with a loop's turns (679). On one that does, the
  list's tools and `goal_complete` are there from the first call and a compaction's tail
  keeps no thinking (867, 871).
  An agent restarted, or a session resumed, sends what it sent before: each block is on
  its call's `llm_request` as `turn_context_block` and folded back on replay (863).
- **Tokens.** A changed section is added to the conversation each time it changes, and
  stays there until a compaction: the task list once for each turn that began with a new
  one, the instruction files when a turn brings in a nested file or one was edited. With
  `per_turn` they are rewritten in place in the system prompt, which adds nothing but
  writes everything behind it to the cache again.
- **How well instructions are followed.** In the system prompt the instruction files speak
  with the operator's voice; in the turn they are text in the person's message, read last
  before the model answers. A model may weigh them less, or more, than it does now. The
  live bench's `follow_up` is what says: its outcome is the second turn's file under the
  rules of both instruction files, one sent with the first turn and one with the second,
  and its check the first turn's file under the root's rule. Its success rate with
  `stable` against `per_turn`, over five runs or more, is the measure, and `smoke` or
  `standard` with each says whether tasks without instruction files moved. If
  `stable` follows them less well, Anthropic's mid-conversation `role: "system"` message
  carries operator authority without editing the prefix, on every model of the three but
  not on Sonnet 5 and not on an OpenAI-compatible wire; it is not built.
- **Every wire.** It is how the prompt is assembled, so an OpenAI-compatible provider that
  caches by prefix gains the same.

## What the log says, and the counter

Per model call (PROTOCOL.md): `llm_request.system_changed` and `tools_changed` against the
agent's call before; `llm_request.turn_context` with `stable`, and `turn_context_block`, the
block it put, which a restart folds back; and on `llm_response`,
`thinking_resent: true` when the call was refused as bound to another conversation and
sent again (805's path, written nowhere before), `thinking_dropped`, the blocks the beta
dropped, and `prefix_mismatch`, what the API's `anthropic-thinking-prefix-mismatch` header
said of the edit (Decision 863).

That header is Anthropic's diagnosis, on a refusal or on a response that dropped blocks,
and unpublished: it may change or stop, and a proxy may not pass it on. Its value is
`key=value` pairs apart by `;`, such as `kind=system_changed; pattern=system_rerendered;
sections=system; changed_validated=system.0`. The event keeps only the pairs named `kind`,
`pattern`, `sections`, `changed_validated` and `position` whose value is a word, a path into
the request or a list of them, so nothing of the conversation reaches the log however the
header grows; a header that is one such word is kept as it is, and one with neither is
`unrecognised`. `pattern` is the shape of the edit (`system_rerendered`, `tool_set_changed`,
`compaction_summary`, `tail_kept` and others), and `changed_validated` where in the request
it begins.

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

## Live numbers with the new defaults

The installed build of Decision 863, on Windows, 2026-10-11:
`troupe bench --live --scenario task_list,follow_up --repeat 5` on Claude Sonnet 5.5 and
Opus 5.5, on one account that is not enforced, priced as the earlier runs were (Sonnet
5.5 $2 in, $10 out, $0.20 cache read, $2.50 cache write per million; Opus 5.5 $4, $20,
$0.20, $5). Three configurations: `stable` (the default), `stable` with
`thinking_binding: error` (an enforced account, asked for), and `per_turn` with `error`
(0.12.0's prompt on an enforced account). The 60 runs cost $1.53 in all.

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

- **Nothing in front of what was sent changed** with `stable`, on either model and in
  either scenario: no system prompt change and, with `error`, no refusal in 40 runs.
- **`per_turn` + `error` is the enforced column**, from configuration: 20 refusals in
  `task_list` on both models, as the patched build's measurement had, with 60% more output
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
call; after, on a model that binds its thinking, they are there from the first (Decision
867). Claude Sonnet 5.5 on one account that is not enforced, with `thinking_binding: error`
(an enforced account, asked for), three runs each, the installed build before and after
the change, on Windows, 2026-10-11, at Sonnet 5.5's prices as above:

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
tasks of the standard suite on which `qwen3-235b` wrote a list whenever it had the tool
(Decision 793), `fix_test`, `rename_symbol`, `implement_spec` and `follow_steps`, three runs
each:

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
The 32 runs, two compaction probes among them, cost $0.65. To run it again, with the
commands of the section above: `troupe bench --live --scenario long_turn --repeat 3`, and
`--scenario fix_test,rename_symbol,implement_spec,follow_steps`, each with
`$env:TROUPE_THINKING_BINDING = "error"`.

Not measured live: a compaction whose kept tail holds a thinking block. Sonnet 5.5 thought
on the first and the last call of `long_turn` only, so in two runs with a window small
enough to compact (three compactions before, seven after, none refused) the first call's
block was always in what the summary replaced; in those runs (three compactions before, seven
after) no call after a compaction was refused. The stand-in, which binds as the
documentation says, is the proof for the tail (`BoundThinkingTest`).

## What is left, and when (#606, #617)

On a model that binds its thinking (by its name, or `binds_thinking` in the config for a
name that hides it, Decision 871), these are all that still change what is in front of a
call's thinking:

- **An MCP tool that comes or goes**, on every model: a server that comes back with
  another list (an edited file, a server checked again), a sign-in that completes, a
  person's client that offers its tools or closes. The agent takes the MCP servers' and
  the clients' tools as a turn's first call begins and offers those for the rest of the
  turn, so the change is at the next turn's first call. A tool that went in the meantime
  stays in the list until then, and a call to it is an error result saying it went.
- **A skill added, removed or renamed**, on every model, where the session reads skills
  (the person's layers, the workspace's, a pod's bundle): the `skill` tool names every
  skill in its description and schema, and the system prompt lists them. The agent takes
  the skills with the MCP tools, so the change is at the next turn's first call too
  (Decision 876). A skill that went in the meantime stays listed until then, and a call
  to it is an error result saying it went.
- **A compaction**, whose summary replaces what came before; its tail goes without the
  thinking made in front of that (867), and a scratchpad document in it is left out for a
  pointer (878).
- **An `AI?` turn's `plan` prompt**, and **a profile or a model switched**.

What a turn's first call took is on its `llm_request` (`turn_hold`, Decision 876), whole
or by the digest of the hold the agent last wrote whole, and folded: an agent restarted in
the middle of a turn offers the tools and skills the turn began with, and one restarted
between turns takes them afresh, as the next turn would. Before, a restart in the middle
of a turn took them afresh, so a tool or a skill that came while the turn ran reached its
next call.

Not the system prompt (863), the task list's tools (867) or `/loop`'s `goal_complete`,
which such a model's root agent is offered on every call and refused outside a loop (871).
On a model that does not bind, the list's tools still come at a turn's eleventh call (793)
and `goal_complete` with a loop's turns (679): a cache write each, and nothing refused.

**What a change at the boundary costs on an account that enforces the binding.** Every
later call carries a block made under the tools before it, so each is refused once and sent
again without its thinking, for the rest of the session or until a compaction (805; D92 in
`defects.md` says what would end it). Against the stand-in as Claude Sonnet 5.5 with
`thinking_binding: error` (`StableToolsTest`): three turns of three, two and one calls, and
a person's tool offered while the first turn's first call ran.

| | tools taken on every call (0.13.0) | held to the turn (871) |
|---|---:|---:|
| calls whose tools changed | 1, the first turn's second | 1, the second turn's first |
| refused, and sent again without thinking | 5 | 3 |
| HTTP requests | 11 | 9 |

The hold saves the refusals of the rest of the turn a tool came in, and the model never
sees its tools change under a turn's reasoning. It does not save the turns after: on an
enforced account a tool that comes or goes still costs a refusal on every later call.

`loop_turn`, a live scenario by name, is a `/loop` turn of one iteration and then a
person's turn in the same session. Against the same stand-in with `error`
(`BenchLiveTest`), three calls each: with `goal_complete` offered on the loop's turn alone,
as a model that does not bind still has it (the stand-in binds every model's thinking),
the person's turn changed the tools and each of its three calls was refused once, nine
requests for six calls; offered on every call, six requests and nothing refused.

Live, on Claude Sonnet 5.5 with `thinking_binding: error`, the installed build of
Decision 871, three runs of `loop_turn` each, on Windows, 2026-10-11, at Sonnet 5.5's prices
as above. `goal_complete` on every call is Sonnet 5.5 as its name says it binds; on the
loop's turn alone is the same model through a provider whose entry says
`binds_thinking: false`, which is how Decision 679 offers it on a model that does not bind:

| | on the loop's turn alone (679) | on every call (871) |
|---|---:|---:|
| runs that succeeded | 3 of 3 | 3 of 3 |
| model calls | 22 | 21 |
| refused, and sent again without thinking | 9 | 0 |
| HTTP requests | 31 | 21 |
| calls whose tools changed | 3 | 0 |
| tokens sent uncached (fresh, or written to the cache) | 21,343 | 12,164 |
| tokens read from the cache | 129,371 | 144,072 |
| output tokens | 2,396 | 2,568 |
| cost, the three runs | $0.1032 | $0.0849 |
| median run | $0.0258 | $0.0237 |

- **Every call of the person's turn was refused once** where `goal_complete` went with the
  loop, three a run, each with the API's `kind=tools_changed; pattern=tool_set_changed;
  sections=tools; changed_validated=tools; position=at`. Offered on every call, none was,
  and the tools never changed.
- **The three runs cost 18% less**, and sent 43% fewer tokens uncached: the person's turn no
  longer writes the whole prompt to the cache again.
- The outcome and both checks held in all six runs. The six runs cost $0.19. To run them
  again: `$env:TROUPE_THINKING_BINDING = "error"`, then
  `troupe bench --live --scenario loop_turn --repeat 3 --model claude-sonnet-5-5`, and the
  same with `--model <provider>/claude-sonnet-5-5` for a provider whose `models:` entry for
  it says `binds_thinking: false`.

## A compaction and the scratchpad (#616)

A document `show` puts on the scratchpad is in the conversation as the call's arguments,
and nothing replaces it between compactions (Decision 870), so it is sent again on every
later call. A compaction, which changes the prefix anyway, leaves it out (Decision 878):

- **What it keeps, and what its summariser reads,** has in each shown document's place one
  line naming it, its title, version and size and the call that reads it back:
  `read_file(path: "scratch:/<name>")`, read-only, the only file tool that reaches the
  scratchpad. A call the model has not replied after yet, the one a compaction in the
  middle of a turn comes after, keeps its words until the next compaction.
- **Its summary lists the scratchpad** after it, every document and its latest version, so
  a document is known by name after any number of compactions.
- **It is logged** with the conversation in `compacted`, so a restart sends the same prefix,
  and on a model that binds its thinking the tail still goes without its blocks (867).

Live, on Claude Sonnet 5.5, `scratchpad_session` and `scratchpad_session_without`: five
turns that write the migration plan, revise it, write a checklist, ask about a step and
add one, under a window of their own (a compaction at 11,200 tokens). Tokens fresh / read
from the cache / output; Decision 878 has the runs on the builds before.

| | with the scratchpad, one run | without, three runs |
|---|---:|---:|
| compactions | 6 | 3 each |
| from the run's first compaction | $0.3111; 66,853 / 57,813 / 17,831 | $0.1562 to $0.1861 |
| the fourth and fifth turns, both after a compaction | $0.1842; 34,140 / 29,034 / 11,377 | $0.1497 to $0.1754 |

No call after a compaction carried a document's words, and the agent read the plan back
when a turn needed it. But this scenario does not show the session costing no more: under
its small window the session with the scratchpad compacted after nearly every call (each
of its turns makes two, and each read-back of the 14.5 KB plan crosses the line again), and
each compaction writes the prompt to the cache again. A window where compactions are rare
against the calls between them, and a revision that does not read the whole document back
(#472's `patch`), are what the measure still needs.

## Live numbers

Claude Opus 5.5 on Anthropic's API, with this branch's installed build, on Windows,
2026-10-08. Each configuration ran `follow_up` five times. The bench's config carried Opus
5.5's list prices: $4 in, $20 out, $0.20 for a cache read and $5 for a cache write, per
million tokens. The 20 runs cost $0.52 in all. The smoke suite ran afterwards, with and
without `stable` (below).

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
  - a session longer than two turns.

The smoke suite has four one-turn tasks with no instruction files: `write_file`,
`fix_test`, `delegate` and `recover`. It ran three times each, with and without `stable`,
on the same model and build. The two runs cost $0.44 together.

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

With one turn and no instruction files, the system prompt never changes, so the two
configurations send almost the same thing. Every task still succeeded under `stable`,
and it sent 26% fewer uncached tokens and cost 11% less. Most of that difference is in
`write_file` ($0.045 against $0.024); the other three tasks cost within a few tenths of
a cent of each other.

To run it again, in PowerShell, where `$m` is the model as `troupe models` addresses it.
The table's baseline is the 0.12.0 default, which from 0.13.0 on is `per_turn` by name:

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
`$env:TROUPE_THINKING_BINDING = "error"`.

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
