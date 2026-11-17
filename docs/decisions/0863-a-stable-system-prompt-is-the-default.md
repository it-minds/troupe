---
number: 863
title: "A session's system prompt is the same on every call by default, and what changes during it reaches the model as turn context, logged and folded so a restart sends the same prefix; `per_turn` is the old prompt by name, `thinking_binding: drop_block` an opt-in fallback, `error` the refusal asked for, and the API's mismatch header is kept on `llm_response` in its own words"
date: 2026-10-11
status: accepted
issue: 465
supersedes: [815]
paths:
  - apps/troupe_core/lib/troupe/config/schema.ex
  - apps/troupe_core/lib/troupe/llm/request.ex
  - apps/troupe_core/lib/troupe/llm/providers/anthropic.ex
gist: "system_prompt defaults to stable (per_turn by name, read as written); turn context logged on llm_request and folded; drop_block opt-in, error asks for the 400; prefix_mismatch in the API's words"
---

Issue #465, decided by the maintainer on 2026-10-11 from the measurement on the issue
(Sonnet 5.5, five runs a cell, an enforced account emulated): option 2 is the default, and
Anthropic's beta stays an opt-in fallback. This takes back the part of Decision 815 that
kept both options off by default; the rest of 815 (how each works, what the log says, the
counter, the stand-in) stands.

- **The default.** `system_prompt` is `stable` unless a layer sets it. The system prompt
  is the profile's words, the environment and the skills, and nothing a session changes;
  the instruction files and the brief, the goal and the task list go with the turn.
- **The turn context is in the log, and folded.** 815 kept the blocks in the agent alone,
  so an agent restarted, or a session `troupe resume` woke, sent its next call without
  them. That was not one edit: every thinking block made after them was bound to a prefix
  that held them, so on an account that enforces the check every later call was refused
  and sent again without its thinking, until a compaction. With option 2 the default that
  is every resumed session. Each block put is now on its call's `llm_request`, as
  `turn_context_block`: `at` (the message it goes after), `text` (the block as sent) and
  `sent` (each section's `sha256:` digest, which is all `State.context_sent` keeps now).
  Not chosen: logging only the sections and rendering the block again on replay, which a
  later build's wording would turn into a different prefix. A log written before 0.13.0
  has no blocks, and its agents send their next call without them once, as before.
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
  stable prompt cannot remove: a compaction, an `AI?` turn's `plan` prompt; and, until
  #590, the task list's tools.
- **What it costs.** What 815 measured for option 2 holds for every session now: the first
  turn's prompt carries the `<turn_context>` wrapper; a changed section is added to the
  conversation rather than rewritten in place; and the instruction files are read as part
  of the person's message rather than the system prompt.
