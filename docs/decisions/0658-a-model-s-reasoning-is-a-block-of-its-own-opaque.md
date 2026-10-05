---
number: 658
title: A model's reasoning is a block of its own — opaque, provider-bound, replayed verbatim to the provider that made it and to no other — and a reasoning model gets the output cap it asks for
date: 2026-09-20
status: accepted
paths:
  - apps/troupe_core/lib/troupe/llm/message.ex
  - apps/troupe_core/lib/troupe/llm/providers/anthropic.ex
  - apps/troupe_core/lib/troupe/llm/providers/openai.ex
  - apps/troupe_core/lib/troupe/llm/request.ex
  - apps/troupe_core/test/troupe/agent/reasoning_shape_test.exs
  - apps/troupe_core/test/troupe/llm/reasoning_test.exs
  - clients/gui/packages/client/src/transcript.ts
  - clients/gui/packages/client/test/transcript.test.ts
gist: A model's reasoning is a block of its own — opaque, provider-bound, replayed verbatim to the provider that made it and to no other
---

Both providers demand it back. DeepSeek's thinking
mode is all-or-nothing: once one assistant message in the history carried
reasoning, one that omits it fails the whole request with a 400, which refused the
second request of every tool-using conversation. Anthropic signs its thinking
blocks and demands them back on a tool-use turn. `Troupe.LLM.Reasoning` is a fourth
content block (`provider`, `text`, `signature`, `redacted`), captured off both
streams — `reasoning_content` or `reasoning` as a sibling of `content`; `thinking`,
`signature_delta` and `redacted_thinking` as blocks — logged in
`llm_response.message` like any block, and handed back only by the adapter whose
provider produced it: OpenAI as `reasoning_content` on the assistant message,
Anthropic as `thinking` / `redacted_thinking` blocks and only when the request has
thinking enabled, since a thinking block is illegal otherwise. `Message.text/1` and
`tool_uses/1` never see it, so a parent's summary and a client's prose do not fill
with thinking; a `reasoning` block from a provider this build has no adapter for
replays as `:unknown` and is carried, never sent. Live, it is `llm_delta` `kind:
"reasoning"`, which the TUI folds and ACP takes as `agent_thought_chunk`. The cap:
a model's `reasoning_effort` (from its `models:` entry, through `Config.target/2`
onto the request) makes the OpenAI adapter send `max_completion_tokens` and
`reasoning_effort` in place of `max_tokens`, which a reasoning model rejects; a 400
that names the other field is answered once by sending the request again with it,
so nobody has to configure what the provider will say. Anthropic takes a budget
rather than a level, so the level becomes `thinking.budget_tokens` (`minimal` 1k …
`xhigh` 32k, or a number) and `max_tokens` is raised to hold it rather than the
request failing. The effort is a per-model setting; an agent's `Definition` has no
field for it until a profile wants to think harder than its model's default.
