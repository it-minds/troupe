---
number: 780
title: "A reasoning effort reaches an Anthropic model in the form the model takes: adaptive thinking with an effort level from Claude Opus 4.7 on, a thinking budget before it. And a gateway's cache writes over the OpenAI wire are cache writes, priced as such"
date: 2026-10-05
status: accepted
issue: 396
paths:
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/llm/catalog.ex
  - apps/troupe_core/lib/troupe/llm/provider.ex
  - apps/troupe_core/lib/troupe/llm/providers/anthropic.ex
  - apps/troupe_core/lib/troupe/llm/providers/openai.ex
  - apps/troupe_core/lib/troupe/llm/request.ex
  - apps/troupe_core/test/support/prompt_cache_stand_in.ex
  - apps/troupe_core/test/troupe/agent/thinking_form_test.exs
  - apps/troupe_core/test/troupe/llm/thinking_test.exs
gist: "A reasoning effort reaches an Anthropic model in the form the model takes: adaptive thinking with an effort level from Claude Opus 4.7 on, a…"
---

Issue #396 and the first item of D65. The adapter sent `thinking: {type: "enabled",
budget_tokens: N}` for every effort (658), which Anthropic's newest models refuse
with a 400, so a `reasoning_effort` on one of them failed every call: on the chunk's
tip a request for `claude-opus-5-5` at `high` went out with `budget_tokens: 16384`.
- **What Anthropic takes**, as its API documentation had it when read on 2026-10-05
  (the Claude API reference, model tables of 2026-09-25): a budget is refused with a
  400 by Opus 4.7, 4.8, 5 and 5.5, Sonnet 5 and 5.5, Fable 5 and 5.1 and Mythos
  (`"thinking.type.enabled" is not supported for this model. Use
  "thinking.type.adaptive" and "output_config.effort" ...`); Opus 4.6 and Sonnet 4.6
  take both, the budget deprecated; Haiku 4.5 and everything older take only the
  budget. Adaptive thinking is `thinking: {type: "adaptive"}` with
  `output_config: {effort: ...}`, one of `low`, `medium`, `high`, `xhigh`, `max`
  (4.6 has no `xhigh`). From 4.7 on a thinking block streams empty unless the request
  asks for a summary. The documentation is not fetched by anything at run or test
  time.
- **Which form.** What the provider's own list says, else the model's name, else the
  kind of value. Anthropic's `GET /v1/models` lists `capabilities.thinking.types`
  with `supported` on each form: `enabled` means the budget, else `adaptive` the
  newer form, and the catalog keeps it (`Catalog.thinking`, `"thinking"` in
  `models.json`); `Config.thinking/2` finds it under the id a model is addressed by,
  then the id its provider lists it by, and the agent puts it on the request
  (`Request.thinking`). With no list, `Catalog.thinking/1` reads the name, found
  inside a gateway's renaming (`eu.anthropic.claude-opus-5`,
  `claude-sonnet-4-5@20250929`): the Claude 3 family and Opus, Sonnet and Haiku before
  4.7 take a budget; 4.7 and later, Fable and Mythos the newer form. A name that is
  none of those, a gateway's own alias, is sent the newer form for a word and a
  budget for a number, which is what the key's documentation already said a number
  is. A model that takes both keeps the budget: Opus 4.6 and Sonnet 4.6 go on as they
  did, and every model that gets the newer form has all five levels, so no level has
  to be moved down for one that lacks it.
- **Levels.** A word is Anthropic's level of the same name; `minimal`, which it has no
  level for, is `low`. A number is the lowest level whose budget below would hold it
  (4096 `low`, 8192 `medium`, 16384 `high`, 32768 `xhigh`), and more is `max`; under
  1024 it is nothing, as before. `max` is a word now too: the newer form's top level,
  and for a model that takes a budget the same 32768 as `xhigh`, the most the older
  models' output caps hold. Both forms raise `max_tokens` to the budget's size and
  4096 more, as 658 had it: adaptive thinking spends from the output cap just as a
  budget does. The newer form asks for `display: "summarized"`, so the newest models'
  thinking still streams as reasoning (658) instead of as empty blocks; it is billed
  the same.
- **A refusal.** A 400 to a request that carried thinking, whose message names
  `thinking.type`, `budget_tokens`, `adaptive`, `output_config` or `effort`, is
  `{:thinking_refused, sentence, detail}`, and the sentence names the setting:
  `house-model refused adaptive thinking at effort high, which reasoning_effort high
  asks for; for a model Troupe has no listing for, a number of tokens sends a thinking
  budget instead: set reasoning_effort in the model's models: entry to one, such as
  16384, or remove it to send no thinking`, then what the provider said. For a model
  the list or the name decided, it says to remove the effort. Not answered by sending
  the other form, as 658 does for the output cap's field: a level and a budget do not
  ask for the same thing, and which one was meant is the person's to say. Any other
  400 is as before, and Anthropic's error message is now read out of its `error`
  object rather than printed as a map.
- **Cache writes over the OpenAI wire.** LiteLLM, serving an Anthropic model it marks
  for caching, reports Anthropic's figures in two spellings: writes as
  `prompt_tokens_details.cache_creation_tokens` and `cache_creation_input_tokens`,
  reads as `cached_tokens` and `cache_read_input_tokens`, with all three input
  figures counted in `prompt_tokens` (its `calculate_usage`, the same in v1.55 and on
  main as of 2026-10-05). The reader took `cached_tokens` only, so a write was fresh
  input, priced at the input rate rather than the write rate a quarter above it, and
  the log showed no write at all. It now reads either spelling of each, takes both
  out of `prompt_tokens`, and a call is priced at the catalog's
  `cache_creation_input_token_cost`, or `models.prices.<model>.cache_write`, as an
  Anthropic call already was (689, 770). OpenAI's own API reports neither field.
- **Not in this:** a model that thinks with no `thinking` field (Opus 5.5, Fable,
  Sonnet 5.5) and no `reasoning_effort` set is sent nothing and its thinking blocks
  are not replayed, as before; Sonnet 5.5's `between_tools`; levels a future model
  lacks; the hour-long cache's own write rate.
- **Proof:** `Troupe.LLM.ThinkingTest`, against request bodies written out in full:
  Opus 5.5 at `high` is adaptive thinking at `high` with a cap of 20480, Haiku 4.5 at
  `medium` a budget of 8192 as before; eleven of the newest names (two of them a
  gateway's renaming) adaptive and ten older ones (dated, Bedrock's and Vertex's
  spellings) a budget; the levels and numbers mapped; `none`, `off` and 500 sending
  nothing; a model nothing describes; each refusal's sentence, and a 400 about
  something else left alone; Anthropic's listing parsed and kept through the cache
  file; the list over the name over the kind of value. `ProvidersTest`: a LiteLLM
  chunk's writes are `cache_write`, in either spelling. `PromptCacheTest`: the
  stand-in as a LiteLLM gateway that marks up to the last message, six calls each
  writing, each logged and priced at the write rate of a catalog parsed from a
  `/model_group/info` body. `Troupe.Agent.ThinkingFormTest`: an agent's call through
  a named provider of `type: anthropic` carries adaptive thinking at the configured
  effort for Opus 5.5, and a budget for a model the catalog says takes one. On the
  chunk's tip nine of these failed: the newest models were sent a budget, a refusal
  read as a map, and every write over the OpenAI wire was fresh input. And the
  installed daemon, with scratch homes, against a loopback stand-in that records each
  body and answers both model listings: over the protocol, `claude-opus-5-5` at `high`
  went out as adaptive thinking at `high`, `claude-haiku-4-5` at `medium` as a budget
  of 8192, a `house-model` at 12000 that the stand-in's list says takes adaptive
  thinking (the catalog refreshed itself after the first session) at `high`, and a
  LiteLLM-shaped answer logged 1500 written, 3000 read and 500 fresh, priced at 5450
  micro-dollars by the catalog's rates. The build installed before sent the first and
  third a budget, and logged the gateway's call as 2000 fresh and nothing written, at
  4700.
