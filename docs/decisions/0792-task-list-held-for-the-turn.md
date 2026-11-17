---
number: 792
title: The task list in the system prompt is the one the turn began with, so a rewrite within the turn leaves the cached conversation alone, and the todo_write result says the list from then on.
date: 2026-10-05
status: accepted
issue: 389
paths:
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/llm/request.ex
gist: The prompt's task list stays as the turn's input or last compaction left it; rendered per call, every rewrite writes the cached conversation again.
---

- **The list as the turn began.** The agent keeps the list its prompt shows apart from
  the list itself (`State.prompt_todos`): `todos` as they stood when the turn's input was
  taken, or when a compaction last rewrote the conversation, and the same on every call
  until one of those happens again. An input is anything `accept_input/5` takes: a
  person's message, a watch, a loop's iteration, a TUI edit of the list, a subagent's task
  or the one that wakes it. `todo_write` still replaces `todos` at once, and its result
  still says the whole list (`Task list updated:` and the items), so the last list in any
  request is the list as it is now. The section says so in a line before its items: the
  list when this turn began, and the latest `todo_write` result since, if there is one,
  is the list now. `todo_read` reads `todos`, as before.
- **Why not the list sent last.** D65 named two ways; the other was to send the current
  list after the last cache mark, as a block the adapter appends to the newest user
  message. That block is gone from the message on the next request, which is an edit of
  history, and a user block that is not a tool result in the middle of a tool loop is
  what Anthropic reads as a new turn: the thinking replayed behind it is dropped, and the
  cache with it (770 declined it for this). It would also be written once per wire.
  Holding the list touches neither adapter, and on the OpenAI-compatible wire it is the
  only one of the two that keeps a prefix cache at all.
- **What it costs.** Once the turn has rewritten its list, a request carries two: the
  system prompt's, as the turn began, and the newest result's, and the line says which is
  the list now. And a list the turn before changed is new in the system prompt at the
  next turn's first call, which reads the tools and the system prompt and writes the
  conversation again: once a turn, not once a rewrite. A compaction refreshes the list at
  no cost of its own, since the conversation behind the system prompt is new anyway and
  the call that wrote the list may be in the summary.
- **Replay.** `prompt_todos` is folded: a `user_input` sets it, except a note from the
  harness (`source: harness`), which is written in the middle of a turn and left it alone
  live; a `compacted` sets it. An agent restarted in the middle of a turn sends the list
  its turn began with, as it would have without the restart. No event and no field is
  new, and the fold's witness does not move.
- **Counted where it was.** `system_tail` is still the list, so `Spend.prompt_bytes/2`
  counts it in `system` (769) as before. The offline bench's `measure/2` counts
  `request.system` only (D65); no scenario writes a list, and no budget moves.
