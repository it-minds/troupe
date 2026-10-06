---
number: 659
title: "A reply is looked at before it is acted on: a cut reply is asked again once, a cut tool call is answered rather than run, an empty reply is nudged once, a refusal ends the agent as refused, a prompt the provider refused as too long is compacted once and sent again, and a model error is a sentence somebody can act on"
date: 2026-09-20
status: accepted
paths:
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/llm/provider.ex
  - apps/troupe_core/lib/troupe/llm/providers/anthropic.ex
  - apps/troupe_core/lib/troupe/llm/providers/openai.ex
  - apps/troupe_core/test/troupe/agent/limits_test.exs
  - apps/troupe_core/test/troupe/llm/provider_errors_test.exs
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/gui/packages/client/src/transcript.ts
  - clients/tui/lib/troupe/remote/translate.ex
gist: "A reply is looked at before it is acted on: a cut reply is asked again once, a cut tool call is answered rather than run, an empty reply is nudged…"
---

Acting
on `content` and `tool_calls` alone ends a turn the output cap cut in half as
finished — with half a sentence, or with nothing when a reasoning model spent its
allowance thinking — runs a tool on arguments cut mid-JSON, finishes a subagent
with an empty summary, and treats a refusal as a finish; and an opaque error makes
a blown context window, which is recoverable, read like a typo in a model name. So
`handle_response/2` looks at the reply first. A `:max_tokens` stop with no tool
call gets one more request with a note that says what happened and asks for smaller
steps; the second time the agent ends `output_truncated` with what there was. A
`:max_tokens` stop with tool calls goes on, because every `tool_use` owes a
`tool_result` or the next request is refused, and a call cut mid-argument is
answered with an error naming the cause and not run. A reply with no text and no
tool call gets the same one nudge and then ends `empty_reply`. A `:refusal` stop
ends the agent `refused`. Each is a durable `truncated` event, and the note is a
`user_input` from source `harness`, which is what it is and what lets a replay
rebuild the conversation the model saw; a subagent that ends any of these ways
hands its parent what there was, labelled partial, as a budget stop does. On the
error side `Provider.classify/1` names what a failure was — a context overflow by
the prose both providers use for it, rejected credentials, an unknown model, a rate
limit the backoff outlasted — and `describe_error/1` says it in a sentence, which
is what `llm_error.reason` carries. Only the overflow changes control flow: compact
once (the `compacted` event says `reason: context_overflow`) and send the turn
again, since the failed request added nothing to the conversation; a second
overflow, or a conversation too short to compact, fails with a line that says what
to do. A 429 gets more attempts than anything else and waits what `retry-after`
said, up to two minutes, because a rate limit is a wait and not a failure. The two
guards are not replayed: a restart forgets them and grants the retry again, which
errs towards finishing.
