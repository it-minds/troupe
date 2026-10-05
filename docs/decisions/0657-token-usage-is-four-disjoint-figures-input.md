---
number: 657
title: Token usage is four disjoint figures — `input_tokens`, `cache_read`, `cache_write`, `output_tokens` — the budget charges what was billed, and compaction and the context gauge measure the prompt's whole length
date: 2026-09-20
status: accepted
paths:
  - apps/troupe_core/lib/troupe/agent/headroom.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/budget.ex
  - apps/troupe_core/lib/troupe/llm/message.ex
  - apps/troupe_core/lib/troupe/llm/providers/anthropic.ex
  - apps/troupe_core/lib/troupe/llm/providers/openai.ex
  - apps/troupe_core/test/troupe/agent/usage_shape_test.exs
  - apps/troupe_core/test/troupe/llm/usage_test.exs
gist: Token usage is four disjoint figures — `input_tokens`, `cache_read`, `cache_write`, `output_tokens`
---

Anthropic's
`input_tokens` excludes what its prompt cache served and OpenAI's `prompt_tokens`
includes it, so read raw the same conversation counts differently depending on who
answered, and each is wrong in the direction that hurts. On an OpenAI-compatible
provider a long conversation re-reads its whole prompt every turn and nearly all of
it is a cache read billed at a tenth, so `max_input_tokens` would exhaust roughly
ten times early, on work the user was barely paying for; on Anthropic a warm 200k
conversation reads as a few hundred input tokens once the cache hits, so compaction
would never fire. Each adapter converts at the boundary — OpenAI's
`prompt_tokens_details.cached_tokens` comes back out of `prompt_tokens`;
Anthropic's `cache_read_input_tokens` and `cache_creation_input_tokens` are read
beside `input_tokens`, and every figure a `message_delta` reports replaces the
running total — so `input_tokens + cache_read + cache_write` is the prompt's length
whoever answered. `Budget.charge_usage/2` spends `Usage.billed_input/1` (fresh
input plus cache writes), and the agent's `last_input_tokens`, which
`needs_compaction?` and `Headroom`'s `context` read, is `Usage.total_input/1`. The
`llm_response` event carries all four keys, and `Usage.from_json/1` folds an event
written before them as a prompt nothing was cached of, which is what it was.
`Troupe.Session.Usage`, the ledger, reads `input_tokens`, the uncached figure,
because the cost it records comes from the gateway and not from the tokens; the
cache figures ride in the event for the day the ledger wants them.
