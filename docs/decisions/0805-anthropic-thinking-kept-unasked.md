---
number: 805
title: Anthropic's newest models think whether or not they are asked to, so their thinking goes back to them within a turn as it does when an effort turns it on; and a provider error the retries outlast, or one inside a stream, is said in the provider's words, trimmed and without the key
date: 2026-10-06
status: accepted
issue: 427
paths:
  - apps/troupe_core/lib/troupe/llm/providers/anthropic.ex
  - apps/troupe_core/lib/troupe/llm/providers/openai.ex
  - apps/troupe_core/lib/troupe/llm/provider.ex
  - apps/troupe_core/lib/troupe/llm/catalog.ex
symbols:
  - Troupe.LLM.Catalog.thinks_unasked?/1
  - Troupe.LLM.Provider.with_retries/2
gist: A model that thinks unasked (Opus and Sonnet 5+, Fable, Mythos) gets its thinking blocks back with no effort set, not thinking turned off
---

With no `reasoning_effort` the Anthropic adapter sends no `thinking` field (780), and it
handed a thinking block back only when the request turned thinking on (658). Anthropic's
newest models think with no `thinking` field at all, so for them every thinking block was
dropped: on the chunk's tip, the second call of a tool-use turn to `claude-opus-5-5` went
out with the first call's `tool_use` and none of the thinking that led to it.
- **Which: keep the blocks, never turn thinking off.** Turning it off is not on offer for
  most of these models (a 400 on Opus 5.5, Fable and Mythos, a form of its own on
  Sonnet 5.5), and where it is, on Opus 5, the guide names what it costs: tool calls that
  never run. Keeping the blocks is what keeps the model's quality: within a tool-use turn
  each call goes on from the reasoning the last one ended with rather than starting
  over. That is what the maintainer leaned to, and what an effort already got (658, 780).
- **Which model thinks unasked** is read from its name, as 780 reads the form:
  `Catalog.thinks_unasked?/1` says yes to Opus and Sonnet from 5 on, Fable and Mythos,
  inside a gateway's renaming too (`eu.anthropic.claude-opus-5`). The model list has no
  field for it: `capabilities.thinking.types` says which forms a model takes, and Opus
  4.8 takes adaptive thinking without using it unasked. The adapter hands Anthropic's
  blocks back when the request turns thinking on, as before, or when the model thinks
  unasked; the request is otherwise as it was: no `thinking` field, no `output_config`,
  the model's own default effort. An effort of `none` or `off` sends nothing either, so
  a model that thinks anyway gets its thinking back the same way.
- **A block the conversation no longer vouches for.** Troupe's prompt changes between
  turns (the task list as each turn begins, 792; the instruction files and brief read as
  it begins, 798; the goal) and compaction rewrites the history, so on an account the
  check is enforced for, a block from before such a change is refused. That 400 is
  answered by sending the call once more with no thinking in it, the API's own way on and
  what every one of these requests was before this decision; a second refusal is the
  turn's error, in the provider's words. With an effort configured it is the same. The
  cost is one refused call and the earlier reasoning, where without it the turn failed.
- **A failure the retries outlast says what the provider said.** `with_retries` carried
  only the status, so a 5xx or a 429 past its retries read `gave up after retrying:
  {:http_status, 503}`. Both adapters now give the retry the status with the provider's
  message, read and cleaned as an error response's is (791), `{:http_status, status,
  detail}`; `describe_error` says the last one as it would have been said unretried
  (`gave up after retrying: the provider answered 529 (Overloaded)`), and a rate limit
  the backoff outlasted names what the provider said about it. A transport failure is
  said as before.
- **An error inside an Anthropic stream** (`{:api_error, message}`, an `error` event after
  a 200) is trimmed and has the key masked, as an error response's message is since 791.
