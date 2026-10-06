---
number: 89
title: A model's own reasoning is conversation state, not a live display effect, and it goes back to the provider that produced it
date: 2026-09-17
status: accepted
paths:
  - apps/troupe_core/lib/troupe/llm/message.ex
  - clients/tui/lib/troupe/codec.ex
gist: A model's own reasoning is conversation state, not a live display effect, and it goes back to the provider that produced it
---

Both adapters streamed thinking to the UI and then dropped it: `reasoning_content` was read off the OpenAI-compatible delta and forwarded as a tagged `llm_delta` without ever entering `acc`, and Anthropic's `thinking_delta` did the same while `signature_delta` was not handled at all — so neither the text nor its signature reached `response.content`, the `assistant_message` event, or the next request. That is a latent 400 on the *second* request of any tool-using conversation with a reasoning model, which is the normal case: DeepSeek's thinking mode is all-or-nothing (once one assistant message carried `reasoning_content`, one that omits it fails the whole request), and Anthropic rejects a tool-use turn whose thinking it cannot verify. `LLM.Message` gains a fourth block — `%{type: :reasoning, provider, text, signature, redacted}` — so it persists and replays like any other, and because `text/1` and `tool_uses/1` filter on their own types the UI, the summaries and the compaction prompt never see it. It is **provider-bound**, which is the part that cannot be skipped: a session can switch profiles mid-branch, and Anthropic's signature means nothing to DeepSeek while DeepSeek's prose has no signature Anthropic would accept, so each adapter replays `reasoning_of(blocks, :its_own)` and drops the rest. The two providers want it in different *places*, so this is not one encoder: Anthropic takes `thinking`/`redacted_thinking` content blocks ahead of the text, and only when the request itself enables thinking (a thinking block on a request without it is rejected, so `replayable/2` drops them when the effort resolves to no budget); an OpenAI-compatible provider takes `reasoning_content` as a sibling of `content` on the assistant message, not a block at all. `provider` joins `@enum_keys` in `Troupe.Codec`, without which the atom comes back as a string after a restart and every replayed block silently stops matching — the same bug again, one session resume later.
