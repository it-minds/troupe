---
number: 863
title: "A session's system prompt is the same on every call by default, and what changes during it reaches the model as turn context; `per_turn` is the old prompt by name, `thinking_binding: drop_block` an opt-in fallback, `error` the refusal asked for, and the API's mismatch header is kept on `llm_response` in its own words"
date: 2026-10-11
status: accepted
issue: 465
supersedes: [815]
paths:
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/config/schema.ex
  - apps/troupe_core/lib/troupe/config/layers.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/llm/providers/anthropic.ex
  - apps/troupe_core/lib/troupe/llm/request.ex
  - apps/troupe_core/lib/troupe/bench/live.ex
  - apps/troupe_core/lib/troupe/bench/model.ex
  - apps/troupe_core/lib/troupe/bench/onboarding.ex
  - apps/troupe_core/lib/troupe/bench/memory.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_core/test/support/fake_openai.exs
  - apps/troupe_core/test/support/fake_transport.ex
  - apps/troupe_core/test/troupe/agent/stable_prompt_test.exs
  - apps/troupe_core/test/troupe/llm/thinking_test.exs
  - apps/troupe_core/test/troupe/bench_live_test.exs
  - docs/developer/prompt-prefix.md
gist: "system_prompt defaults to stable (per_turn by name, read as written); drop_block stays opt-in, error asks for the 400; llm_response.prefix_mismatch keeps only the header's own words"
---

Issue #465, decided by the maintainer on 2026-10-11 from the measurement on the issue
(Sonnet 5.5, five runs a cell, an enforced account emulated): option 2 is the default, and
Anthropic's beta stays an opt-in fallback. And issue #591, the two gaps the measurement
found: no setting asked for the refusal an enforced account gets, and the API's word on
why a block was stale was dropped. This takes back the part of Decision 815 that kept
both options off by default; the rest of 815 (how each works, what the log says, the
counter, the stand-in) stands.

- **The default.** `system_prompt` is `stable` unless a layer sets it. The system prompt
  is the profile's words, the environment and the skills, and nothing a session changes;
  the instruction files and the brief, the goal and the task list go with the turn.
- **The turn context, as built (815), for whoever builds on it.** As each model call
  begins, `start_turn/1` runs `attach_turn_context/1`. It renders the three sections
  (`instructions`, `goal`, `task_list`) as the system prompt would have had them and
  compares each with the copy the conversation already carries (`State.context_sent`).
  The ones that differ, an emptied one saying so, become one `<turn_context>` text block,
  recorded in `State.turn_context` under the index of the conversation's last user
  message: the person's input as a turn begins, a tool's results in the middle of one.
  `with_turn_context/2` appends each recorded block to its message on every later request,
  so a request is always the one before with something added. Nothing moves a block or
  takes one out, except a compaction, which empties both maps; the sections then go again
  with the conversation that is left. The blocks are not in the log: an agent restarted
  sends its next call without them, once, and puts the sections again as they are then.
  `llm_request.turn_context` names the sections a call carried. What the turn context
  cannot carry is anything outside the messages: the tools (Decision 793's task-list tools
  at a turn's eleventh call, #590), a profile's prompt (an `AI?` turn's `plan`, a profile
  switch), the model.
- **The old value keeps its name, and a setting is read as written.** `per_turn` is the
  prompt as it was before 0.13.0, chosen by name in any layer or with
  `TROUPE_SYSTEM_PROMPT=per_turn`. A `per_turn` already in a file stays `per_turn`; a file
  that never set the key is `stable`. Nothing ever wrote the key into a file on a person's
  behalf (`troupe setup` writes only what was chosen, Decision 817, and neither client
  offers it), so one that is there was chosen. Not chosen: renaming the old value
  (`legacy`), which would turn a valid file into a warning and the old prompt; reading a
  written `per_turn` as `stable`, which overrides a choice.
- **`drop_block` stays opt-in.** On an account that is not enforced it drops blocks that
  reach the model today, and the measurement's model made up for the lost reasoning with
  42% more output; with a stable system prompt nothing in front of the blocks changed, so
  it had nothing to drop. It is the fallback for an enforced account on the changes a
  stable prompt cannot remove: a compaction, an `AI?` turn's `plan` prompt, an agent
  restarted; and, until #590, the task list's tools.
- **`thinking_binding: error`** (#591) sends the beta header and `block_binding:
  {prefix_mismatch_behavior: "error"}` on the same requests `drop_block` binds (those to a
  model whose thinking goes back, Decision 805). The API refuses a stale block with the
  400 an enforced account gets without the beta, and 805's resend answers it, so on any
  account it is that account's column of a live bench, reproducible without a patched
  build. A third value of the same key rather than a setting of its own, because the
  three are one field's three values on the wire.
- **The mismatch header** (#591). On a refusal, and on a response the beta dropped blocks
  from, Anthropic may send `anthropic-thinking-prefix-mismatch: kind=...; pattern=...;
  sections=...; changed_validated=...; position=...`. It is unpublished, and Anthropic's
  own guidance is to use it if present and never depend on it. The response keeps it as
  `prefix_mismatch`, a string on `llm_response`, beside `thinking_resent` and
  `thinking_dropped`; on a refusal it is carried to the response of the call sent again.
  Kept are only the pairs named `kind`, `pattern`, `sections`, `changed_validated` and
  `position` whose value is a word, a path into the request or a list of them (`[A-Za-z0-9_.,-]`,
  at most 64 characters), so nothing of the conversation reaches the log whatever a later
  version of the header carries (an `item`, a quotation, free text). A header
  that is one such word is kept as it is, and one with neither is `unrecognised`, so its
  presence is still counted. Not kept: the header of a refusal whose resend failed too,
  which ends the turn as an `llm_error` in the provider's words (805). Not chosen: a map
  field (one string reads like the header and greps alike); the raw value (what a header
  may carry is not ours to vouch for).
- **What reads the prompt follows it.** The offline bench's onboarding and memory measures
  find the instruction files and the brief in the turn context as well as the system
  prompt, so their budgets mean what they meant. The tests whose subject is what reaches
  the model (the goal, the brief, the task list after a switch or a TUI edit) read the
  request's words wherever they are (`SessionCase.prompt_text/1`); those whose subject is
  the per-turn system prompt itself (Decisions 792, 798 and 769's `brief` bytes) say
  `per_turn`. `llm_request.prompt_bytes.brief` is 0 with `stable`: the brief is in the
  conversation's bytes (815).
- **What it costs.** What 815 measured for option 2 holds for every session now: the first
  turn's prompt carries the `<turn_context>` wrapper; a changed section is added to the
  conversation rather than rewritten in place; and the instruction files are read as part
  of the person's message rather than the system prompt. The live runs (on #465 and in
  prompt-prefix.md) followed the instruction files in every run on Sonnet 5.5 and Opus
  5.5, five runs a cell: a signal, not a measure of instruction following in general.
- **Proof.** `StablePromptTest`: a fresh config's four calls over two turns carry one
  system prompt, the instruction files with the first turn and the list with the second;
  `per_turn` changes it at the second turn. `PromptCacheTest`, against the stand-in that
  caches as Anthropic does: by default the next input's first call reads all of the call
  before it, where `per_turn` reads only what is in front of the list. `ConfigTest`: no
  file is `stable`, a file's
  `per_turn` and `error` are read as written, with no warning. `ThinkingTest`: `error`
  sends the header and the field, the refusal is answered by the call without thinking,
  which binds nothing; the header on a refusal and on a drop is kept cut to its words,
  `item` and a quotation left out, one with no words `unrecognised`, none absent.
  `BenchLiveTest`, against the stand-in as Claude Opus 5.5 on an enforced account: a fresh
  config's `follow_up` and `task_list` change nothing in front of what was sent and are
  never refused; `error` with `per_turn` is refused twice in `follow_up` and each
  `llm_response` of the two says `kind=system_changed; pattern=system_rerendered;
  sections=system; changed_validated=system.0`; `error` with the default is never refused.
  On the chunk's tip four of these failed: the second turn's system prompt held the list,
  the config read `per_turn` and refused `error`, `error` sent no header, and no response
  had the field.
