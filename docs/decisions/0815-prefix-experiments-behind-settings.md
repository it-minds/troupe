---
number: 815
title: "Issue #465's two ways out are settings, both off unless set, so a live bench can measure them before one is chosen; and every model call's log says what changed in front of what the agent had sent and what became of the thinking it handed back"
date: 2026-10-08
status: accepted
issue: 465
paths:
  - apps/troupe_core/lib/troupe/llm/providers/anthropic.ex
  - apps/troupe_core/lib/troupe/llm/request.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/config/schema.ex
  - apps/troupe_core/lib/troupe/config/layers.ex
  - apps/troupe_core/lib/troupe/bench.ex
  - apps/troupe_core/lib/troupe/bench/prefix.ex
  - apps/troupe_core/lib/troupe/bench/live.ex
  - apps/troupe_core/lib/troupe/bench/live_scenarios.ex
  - apps/troupe_core/lib/troupe/bench/scenario.ex
  - apps/troupe_core/lib/mix/tasks/troupe.prefix.ex
  - apps/troupe_core/test/support/fake_openai.exs
  - apps/troupe_core/test/troupe/agent/stable_prompt_test.exs
  - apps/troupe_core/test/troupe/bench_live_test.exs
  - apps/troupe_core/test/troupe/bench/prefix_test.exs
  - apps/troupe_core/test/troupe/llm/thinking_test.exs
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - docs/developer/prompt-prefix.md
symbols:
  - Troupe.Bench.Prefix.count/1
gist: "Both of issue 465's options stay off by default; a stable system prompt only ever appends to the conversation; llm_request and llm_response carry the counts"
---

Issue #465, the measurement its last comment asks for before the maintainer decides.
Anthropic's newest models bind a thinking block to the conversation it was made in, and
Troupe changes that conversation between turns: the task list (792), the instruction
files and the brief (798) and the goal (678) are in the top-level system prompt, and a
compaction rewrites the history. Since Decision 805 such a block, refused, costs one
refused request and a resend without any thinking. The two ways out, and what each needs
answered, are in [docs/developer/prompt-prefix.md](../developer/prompt-prefix.md), with
the offline numbers and the commands for the live ones.

- **Settings, not a choice.** `thinking_binding: default | drop_block` and
  `system_prompt: per_turn | stable`, flat keys any layer may set, each with an
  environment variable (`TROUPE_THINKING_BINDING`, `TROUPE_SYSTEM_PROMPT`) so a bench is
  run with one on without anyone's file being changed. Enums rather than booleans
  because the environment layer takes strings. Off, nothing a request carries moves: the
  provider tests, the prompt tests and the offline bench are as they were.
- **`drop_block`** (option 1) sends `anthropic-beta: thinking-binding-controls-2026-08-01`
  and `thinking.block_binding.prefix_mismatch_behavior: "drop_block"` on a request that
  hands thinking back (805's `keep_thinking?`), and nothing on one that does not. With no
  effort the thinking field it needs is `{type: "adaptive"}` and the binding, which is
  what a model that thinks unasked does with no field; with an effort the binding goes
  beside the adaptive or budget form 780 sends. The shape is Anthropic's documentation's
  as read on 2026-10-08; nothing here was sent to the real API. The response's
  `input_transformations` entries of type `thinking_dropped` are counted.
- **`stable`** (option 2) leaves the instruction files and brief, the goal and the task
  list out of the system prompt (and `system_tail` empty), and puts each in a
  `<turn_context>` block appended to the conversation's last user message when it
  differs from the copy the conversation already carries: the person's input as a turn
  begins, after a tool's results when a compaction or a goal comes in the middle of one
  (the shape Anthropic documents for a per-turn reminder without the `clear_at` beta).
  The block stays where it was put on every later call, so a request is always the one
  before with something added. A section is sent again only when it changed, and one
  that emptied says so; a compaction empties what was sent, and the sections go again
  after it. Not chosen: a block on the newest message that moves (an edit, 770 and 792);
  Anthropic's mid-conversation `role: "system"` message (not on Sonnet 5, and Troupe's
  OpenAI-compatible wire has no such thing); every section on every turn (the
  instruction files again each turn). Not folded: the blocks live in the agent's state,
  not the log, so an agent restarted sends its next call without them, one edit of the
  conversation, and puts the sections again then. That, a `turn_mode: question` turn's
  plan prompt, and Decision 793's tools offered once there is a list are the prefix
  changes this does not remove. Where instructions sit is also how a model weighs them;
  the live bench's `follow_up` is what says whether they are still followed.
- **What the log says.** `llm_request` carries `system_changed` and `tools_changed`
  against the agent's call before (digests in the state, so absent on an agent's first
  call and the first after a restart) and `turn_context`, the sections a stable prompt
  sent with the call. `llm_response` carries `thinking_resent: true` when the call was
  refused as bound to another conversation and sent again (805's path, until now in no
  log), and `thinking_dropped`, the blocks the beta dropped; both absent when nothing
  happened. Optional fields, no new event, nothing folded: the fold's witness and every
  fixture hash stand.
- **The counter.** `Troupe.Bench.Prefix.count/1` adds those up per session; a log
  written before them has its changes judged by `prompt_bytes`' system and tools sizes
  (769), a floor, and says how many were. Every live run's record carries it as `prefix`,
  the report's summary adds it up and the table prints it, and `mix troupe.prefix PATH...`
  counts a directory of session logs.
- **The live bench** carries the two settings from the person's configuration or the
  environment into each run and says them (`experiment` on the report and each history
  line), and a scenario may have `follow_ups`, each typed once the turn before ended by
  itself. `follow_up`, in no suite, is two turns where the first brings `docs/AGENTS.md`
  into the second's instruction files (798), and whose outcome is the second turn's file
  under both files' rules.
- **The stand-in** (`fake_openai.exs`) answers Anthropic's `/v1/messages` too: the same
  scripts, each answer after an empty thinking block signed over the model, the tools as
  a set, the system prompt, every message before it without thinking or cache marks, and
  the block before it; it refuses a block whose conversation changed with Anthropic's
  400, or with the beta and `drop_block` drops it and every thinking block after it and
  says so; and it keeps a prompt cache by marks. Served with `elixir`, an installed
  `troupe` is pointed at it as `type: anthropic`.
- **Proof:** `ThinkingTest` (no header and no `block_binding` whatever the model and
  effort unless asked for; asked for, the header and the field beside each form, none on
  a request that hands nothing back; dropped blocks and a resend on the response),
  `StablePromptTest` (by default the list a turn left changes the system prompt the next
  turn begins with and the log says so; stable, one system prompt for the session, the
  instruction files with the first turn and the list with the second, each request the
  one before with something added; a goal set between turns goes with the next), and
  `BenchLiveTest`'s `follow_up` against the stand-in as Claude Opus 5.5: by default the
  second turn's two calls each refused once and sent again (two resends, one system
  prompt change), with `drop_block` none refused and 3 then 4 blocks dropped, stable no
  change, no refusal, no drop and more read from the cache; `mix troupe.prefix` over the
  kept log says what the run's record says. On the chunk's tip five of these failed: no
  header with the setting, no response fields, the system prompt changed between turns
  with `stable` set, and no log fields. The installed build ran `troupe bench --live
  --scenario follow_up` against the served stand-in with each setting.
