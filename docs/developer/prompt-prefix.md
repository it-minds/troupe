# What changes in front of a prompt (issue #465)

Anthropic's newest models (Claude Fable 5.1, Opus 5.5 and Sonnet 5.5) bind each thinking
block to the conversation it was made in: the model, the system prompt, the tools and
every message before it. On an account created on or after 2026-08-31, a block sent back
after any of those changed is refused with a 400. Troupe changes that conversation between
turns, and since Decision 805 each refusal costs a refused request and the same call sent
again without thinking. The same edits make every caching provider write the conversation
behind them to the cache again.

The issue names two ways out. Both were built behind settings (Decision 815) and measured
live, and the maintainer chose on 2026-10-11 (Decision 863):

- **Option 2, a stable system prompt, is the default.** What changes during a session
  reaches the model as turn context appended to the conversation; the system prompt
  changes mid-session only for a skill file added, removed or renamed (at the next turn,
  Decision 876) and a profile or model switch. `system_prompt: per_turn` is the old prompt.
- **Option 1, Anthropic's beta, is an opt-in fallback** (`thinking_binding: drop_block`)
  for an account that refuses a stale block, on the prefix changes option 2 cannot remove
  ([what is left](#what-is-left-and-when-606-617)).
- **`thinking_binding: error`** asks the API for an enforced account's refusal on any
  account, so it can be measured without a patched build (#591).

Below: what each does and costs, and the gateway question. The numbers, offline and
live, with the commands that produce them, are in this page's git history as they were
measured (`git log -p -- docs/developer/prompt-prefix.md`); each section below says when.

## What changes in front of a prompt

| What | When | Decision | With `stable` |
|---|---|---|---|
| the task list in the system prompt | the first call of a turn after the list changed | 792 | turn context |
| the instruction files and the brief in the system prompt | the first call of a turn after a file was edited, or after the turn before worked in a directory with its own `AGENTS.md` | 798 | turn context |
| the goal in the system prompt | the call after it was set or cleared | 678 | turn context |
| the tools | the call after the task list's tools are first offered: once there is a list, or after ten calls of a turn | 793 | the same on a model that binds its thinking: the list's tools from the first call (867); changes on others |
| `goal_complete` among the tools | the first call of a `/loop` turn, and of the turn after one | 679 | the same on a model that binds its thinking: offered on every call of the root agent, refused outside a loop (871); changes on others |
| an MCP server's tools, or those a person's client offers | the first call of the turn after a server came back with another list, a sign-in completed, or a person's tools came or went | 654, 741, 861 | changes, at a turn's first call and never in the middle of one (871) |
| the skills, in the `skill` tool and the system prompt | the first call of the turn after a skill file was added, removed or renamed | 700 | changes, at a turn's first call and never in the middle of one (876) |
| the tools and skills a turn held | an agent restarted in the middle of the turn | 871 | the same: what the turn's first call held is in the log (876) |
| the conversation | a compaction, which keeps a tail of it | 774 | changes; on a model that binds its thinking the tail goes without the blocks made in front of what the summary replaced, so no later call is refused (867); a scratchpad document is left out for a pointer there and nowhere else (878) |
| the turn context put before | an agent restarted, or a session resumed | 815 | the same: the blocks are in the log (863) |

On an enforced account, every call after one of these that carries a block from before it
is refused and sent again with no thinking. Troupe's history keeps those blocks, so the
refusal repeats on every later call until a compaction: two requests a call, and no
reasoning from before the change, nor any the turn makes after it, reaches the model. On an
account that is not enforced the blocks reach the model as they are.

## The settings

| Setting | Values, the default first | For one shell, or one bench |
|---|---|---|
| `system_prompt` | `stable` (option 2); `per_turn`, the prompt as it was before 0.13.0 | `TROUPE_SYSTEM_PROMPT=per_turn` |
| `thinking_binding` | `default`, nothing sent; `drop_block` (option 1); `error`, the refusal asked for | `TROUPE_THINKING_BINDING=drop_block` |

Both may be set together. A file that never set `system_prompt` is `stable` from 0.13.0 on;
one that says `per_turn` keeps it. With `per_turn` and `default` the system prompt is what
0.12.0 sent; the changes the table's last column names by decision (867, 871, 876, 878)
apply whatever these say.

## Option 1: `drop_block`

A request that hands thinking back sends `anthropic-beta:
thinking-binding-controls-2026-08-01` and, in its `thinking` field,
`block_binding: {prefix_mismatch_behavior: "drop_block"}`: beside the adaptive or budget
form an effort asks for, or alone with `type: adaptive` when no effort is set (what a
model that thinks unasked does with no field). Instead of refusing, the API drops the first
block whose conversation changed and every thinking block after it, and says which in the
response's `input_transformations`. A request that hands nothing back sends neither.

What it costs:

- **No refused request**, and no second round trip: one request a call where an enforced
  account otherwise makes two.
- **No reasoning is kept that the resend loses.** The drop is for that request only.
  Troupe goes on sending the stale blocks, so every later call drops them again, and every
  block made after them, the turn's own included: the stand-in's second turn dropped 3
  blocks and then 4.
- **It turns the check on for an account that is not enforced.** On an account created
  before 2026-08-31, setting the field opts the request into the check, so blocks that
  would reach the model are dropped. Only an enforced account gains.
- **The cache** is read up to the first dropped block, as after the resend.
- **Anthropic's wire only.** A provider of `type: openai`, a LiteLLM gateway's
  `/chat/completions` among them, sends no thinking blocks back (its adapter hands back only
  its own provider's `reasoning_content`), so there is nothing to bind.

`thinking_binding: error` sends the same header and `block_binding:
{prefix_mismatch_behavior: "error"}`: the API refuses a stale block with an enforced
account's 400, and Troupe answers it the same way, by sending the call once more without
its thinking (Decision 805). On an account that is not enforced, it is how a live bench
measures the enforced column; on one that is, it changes nothing but the header.

Not built: once a response says blocks were dropped, or a call was refused, Troupe could
stop sending the leading run of blocks from before the change. The API allows taking out a
leading run, oldest first, and the blocks after it stay valid; with or without the beta,
that would keep the reasoning a turn makes after a change.

## Option 2: `system_prompt: stable`, the default

The system prompt leaves out the instruction files and the brief, the goal and the task
list, and is the same on every call of the session but for its skills section (876). Each
of the others goes, as a section of a `<turn_context>` block after what the conversation's
last user message holds, on the call where it differs from the copy the conversation
already carries: with the person's input as a turn begins, after a tool's results when a
goal or a compaction comes mid-turn. The block stays where it was put, so each request is
the one before with something added, which keeps a kept block valid and the cached
conversation readable. A section that emptied says so. The log's
`llm_request.turn_context` names the sections a call carried.

What it costs:

- **The prefix still changes** where the system prompt was not the cause: the rows of the
  table above that `stable` leaves as they were. An agent restarted, or a session resumed,
  sends what it sent before: each block is on its call's `llm_request` as
  `turn_context_block` and folded back on replay (863).
- **Tokens.** A changed section is added to the conversation each time it changes and
  stays there until a compaction: the task list once for each turn that began with a new
  one, the instruction files when a turn brings in a nested file or one was edited. With
  `per_turn` they are rewritten in place in the system prompt, which adds nothing but
  writes everything behind it to the cache again.
- **How well instructions are followed.** In the system prompt the instruction files speak
  with the operator's voice; in the turn they are text in the person's message, read last.
  A model may weigh them less, or more. The live bench's `follow_up` says which: its
  outcome is the second turn's file under the rules of both instruction files (one sent
  with each turn), its check the first turn's file under the root's rule. Its success rate
  with `stable` against `per_turn`, over five runs or more, is the measure; `smoke` or
  `standard` with each says whether tasks without instruction files moved. If `stable`
  follows them less well, Anthropic's mid-conversation `role: "system"` message carries
  operator authority without editing the prefix, on the three models but not Sonnet 5 nor
  an OpenAI-compatible wire; it is not built.
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

That header is Anthropic's diagnosis, on a refusal or a response that dropped blocks, and
unpublished: it may change or stop, and a proxy may not pass it on. Its value is
`key=value` pairs separated by `;`, such as `kind=system_changed; pattern=system_rerendered;
sections=system; changed_validated=system.0`. The event keeps only the pairs `kind`,
`pattern`, `sections`, `changed_validated` and `position` whose value is a word, a path into
the request or a list of them, so nothing of the conversation reaches the log however the
header grows; a header that is one such word is kept as it is, and one with neither is
`unrecognised`. `pattern` is the shape of the edit (`system_rerendered`, `tool_set_changed`,
`compaction_summary`, `tail_kept` and others), `changed_validated` where in the request it
begins.

`Troupe.Bench.Prefix.count/1` adds them up: a live bench run carries it as `prefix`, the
report's `summary.prefix` sums the runs, and the table prints a `prompt prefix` row. Over
session logs:

```sh
mix troupe.prefix                      # the state directory's sessions
mix troupe.prefix PATH...              # a session's events.jsonl, or directories of them
mix troupe.prefix --json PATH...
```

In a log written before these fields, system prompt and tools changes are judged by
`prompt_bytes`' sizes (Decision 769) and counted as `inferred`, a floor, since an edit that
keeps the size is missed. No log before 0.9.1 says a call was sent again. Pointed at a
person's own sessions, it says how often their prompts changed in front of what had been
sent: the issue's "how often today".

## Offline numbers

`follow_up` against the stand-in as Opus 5.5 on an enforced account, with each
option and both, 2026-10-08, in this page's git history.

## The gateway question

Does a gateway in front of Anthropic pass the beta header and the new field on? For
LiteLLM, from its documentation and source as read on 2026-10-08, not tried:

- **`/v1/messages`**, LiteLLM's Anthropic-shaped endpoint, which a Troupe provider of
  `type: anthropic` with the gateway's URL speaks. The request-headers page says it
  always forwards `anthropic-beta` to the underlying model on that endpoint
  ([docs.litellm.ai/docs/proxy/request_headers](https://docs.litellm.ai/docs/proxy/request_headers)),
  and `_get_forwardable_headers` in `litellm/proxy/litellm_pre_call_utils.py` forwards it
  beside the `x-` headers. The Anthropic provider page says that route passes `thinking`
  through unchanged
  ([docs.litellm.ai/docs/providers/anthropic](https://docs.litellm.ai/docs/providers/anthropic)),
  so `thinking.block_binding` should reach Anthropic as sent. Both options work there.
- **`/chat/completions`**, which a Troupe provider of `type: openai` speaks, the usual way
  to a LiteLLM gateway: `anthropic-beta` is forwarded only for a model configured with
  `forward_client_headers_to_llm_api` (same page). Troupe's OpenAI-compatible adapter sends
  neither the header nor the field, nor Anthropic thinking blocks, so option 1 does not
  apply; option 2 does, and helps that gateway's prompt cache.
- **Behind the gateway**, the controls are offered on Anthropic's API, its platform on
  AWS, Amazon Bedrock (as the `anthropic_beta` body field, not a header) and Google Vertex
  AI; Microsoft Foundry is unconfirmed (Anthropic's documentation). A gateway routing to
  Bedrock has to carry the beta into the body; whether LiteLLM does was not checked.

## What was not confirmed without calling the API

What was read in Anthropic's documentation on 2026-10-08 and not tried against the
API is in this page's git history.

## Live numbers with the new defaults

`task_list` and `follow_up` on Sonnet 5.5 and Opus 5.5 with the stable default, asked
for an enforced account's refusal and not, 2026-10-11, in this page's git history.

## Live numbers for the task list's tools (#590)

`long_turn`, and four standard tasks, before and after the list's tools came from the
first call on a binding model (Decision 867), 2026-10-11, in this page's git history.

## What is left, and when (#606, #617)

On a model that binds its thinking (by its name, or `binds_thinking` in the config for a
name that hides it, Decision 871), only these still change what is in front of a call's
thinking:

- **An MCP tool that comes or goes**, on every model: a server back with another list (an
  edited file, a server checked again), a sign-in that completes, a person's client that
  offers its tools or closes. The agent takes the MCP servers' and clients' tools as a
  turn's first call begins and offers those for the rest of the turn, so the change lands
  at the next turn's first call. A tool that went meanwhile stays listed until then, and a
  call to it is an error result saying it went.
- **A skill added, removed or renamed**, on every model, where the session reads skills
  (the person's layers, the workspace's, a pod's bundle): the `skill` tool names every
  skill in its description and schema, and the system prompt lists them. Skills are taken
  with the MCP tools, so this too lands at the next turn's first call (Decision 876), and a
  skill that went meanwhile is handled the same way.
- **A compaction**, whose summary replaces what came before; its tail goes without the
  thinking made in front of that (867), and a scratchpad document in it is left out for a
  pointer (878).
- **A profile or a model switched.** An `AI?` comment no longer changes a running
  session's prefix: it starts a branch session of its own on `answer`, with `plan`'s tools
  from its first call (Decision 844).

What a turn's first call took is on its `llm_request` (`turn_hold`, Decision 876), whole
or by the digest of the hold the agent last wrote whole, and folded: an agent restarted
mid-turn offers the tools and skills the turn began with, and one restarted between turns
takes them afresh, as the next turn would. Before, a mid-turn restart took them afresh, so
a tool or skill that came while the turn ran reached its next call.

The system prompt (863), the task list's tools (867) and `/loop`'s `goal_complete` (offered
to such a model's root agent on every call, refused outside a loop, 871) no longer change.
On a model that does not bind, the list's tools still come at a turn's eleventh call (793)
and `goal_complete` with a loop's turns (679): a cache write each, nothing refused.

**What a change at the boundary costs on an enforcing account.** Every later call carries a
block made under the tools before it, so each is refused once and sent again without its
thinking, for the rest of the session or until a compaction (805; D92 in `defects.md` says
what would end it). Against the stand-in as Claude Sonnet 5.5 with `thinking_binding: error`
(`StableToolsTest`): three turns of three, two and one calls, and a person's tool offered
while the first turn's first call ran.

| | tools taken on every call (0.13.0) | held to the turn (871) |
|---|---:|---:|
| calls whose tools changed | 1, the first turn's second | 1, the second turn's first |
| refused, and sent again without thinking | 5 | 3 |
| HTTP requests | 11 | 9 |

The hold saves the refusals of the rest of the turn a tool came in, and the model never
sees its tools change under a turn's reasoning. It does not save the turns after: on an
enforced account a tool that comes or goes still costs a refusal on every later call.

`loop_turn`, a live scenario by name, is a `/loop` turn of one iteration, then a person's
turn in the same session. Against the same stand-in with `error` (`BenchLiveTest`), three
calls each: with `goal_complete` offered on the loop's turn alone, as a non-binding model
still has it (the stand-in binds every model's thinking), the person's turn changed the
tools and each of its three calls was refused once, nine requests for six calls; offered on
every call, six requests and nothing refused.

Live, on Claude Sonnet 5.5 with `thinking_binding: error`, the installed build of Decision
871, three runs of `loop_turn` each, Windows, 2026-10-11, at Sonnet 5.5's prices as above.
"On every call" is Sonnet 5.5, which binds by its name; "on the loop's turn alone" is the
same model through a provider whose entry says `binds_thinking: false`, which is how
Decision 679 offers it on a model that does not bind:

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
- **The three runs cost 18% less** and sent 43% fewer tokens uncached: the person's turn no
  longer writes the whole prompt to the cache again.
- The outcome and both checks held in all six runs, which cost $0.19. To run them again:
  `$env:TROUPE_THINKING_BINDING = "error"`, then
  `troupe bench --live --scenario loop_turn --repeat 3 --model claude-sonnet-5-5`, and the
  same with `--model <provider>/claude-sonnet-5-5` for a provider whose `models:` entry for
  it says `binds_thinking: false`.

## A compaction and the scratchpad (#616)

A document `show` puts on the scratchpad is in the conversation as the call's arguments,
and nothing replaces it between compactions (Decision 870), so it is sent again on every
later call. A compaction, which changes the prefix anyway, leaves it out (Decision 878):

- **What it keeps, and what its summariser reads,** has one line in each shown document's
  place: its name, title, version and size, and the call that reads it back,
  `read_file(path: "scratch:/<name>")` (read-only, the only file tool that reaches the
  scratchpad). A call the model has not yet replied after, the one a mid-turn compaction
  comes after, keeps its words until the next compaction.
- **Its summary lists the scratchpad** after it, every document and its latest version, so
  a document is known by name after any number of compactions.
- **It is logged** with the conversation in `compacted`, so a restart sends the same
  prefix, and on a binding model the tail still goes without its blocks (867).

Live, on Claude Sonnet 5.5, `scratchpad_session` and `scratchpad_session_without` as they
were then (they are now eight turns under a 24,000-token window, and
[bench.md](bench.md#the-scratchpads-cost) has those runs): five turns that write the
migration plan, revise it, write a checklist, ask about a step and add one, under a window
of their own (a compaction at 11,200 tokens). Tokens fresh / read from
the cache / output; Decision 878 has the runs on the builds before.

| | with the scratchpad, one run | without, three runs |
|---|---:|---:|
| compactions | 6 | 3 each |
| from the run's first compaction | $0.3111; 66,853 / 57,813 / 17,831 | $0.1562 to $0.1861 |
| the fourth and fifth turns, both after a compaction | $0.1842; 34,140 / 29,034 / 11,377 | $0.1497 to $0.1754 |

No call after a compaction carried a document's words, and the agent read the plan back
when a turn needed it. But this scenario does not show the session costing no more: under
its small window the session with the scratchpad compacted after nearly every call (each
turn makes two, and each read-back of the 14.5 KB plan crosses the line again), and each
compaction writes the prompt to the cache again. The measure still needs a window where
compactions are rare against the calls between them, and a revision that does not read the
whole document back (a `patch`, which #472 did not build).

## Live numbers before the stable default

`follow_up` and the smoke suite on Opus 5.5 with each option, and the PowerShell that
runs them again, 2026-10-08, in this page's git history.
