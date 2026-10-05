---
number: 770
title: "An agent's own model calls ask Anthropic to cache the prompt, with four marks: the last tool, the system prompt without its task list, and the last two user messages. An OpenAI-compatible provider caches by itself, and what either reports reaches the log"
date: 2026-10-04
status: accepted
issue: 389
paths:
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/spend.ex
  - apps/troupe_core/lib/troupe/llm/providers/anthropic.ex
  - apps/troupe_core/lib/troupe/llm/providers/openai.ex
  - apps/troupe_core/test/support/prompt_cache_stand_in.ex
  - apps/troupe_core/test/troupe/agent/prompt_cache_test.exs
gist: "An agent's own model calls ask Anthropic to cache the prompt, with four marks: the last tool, the system prompt without its task list, and the last…"
---

Issue #389, slice 2. Every model call of a turn sends the whole conversation
again, and Anthropic's prompt cache is opt-in: a request with no `cache_control` mark
caches nothing, so every resend was billed as fresh input. On the chunk's tip a
thirty-call turn against a stand-in that caches only what is marked read nothing on
any call.
- **Where the marks go.** Anthropic renders tools, then system, then messages; a mark
  caches everything up to it, and a later request that repeats a marked prefix reads
  it at a fraction of the input price (a tenth on most models) and pays a premium to
  write what is new (a quarter more, for the five-minute cache). Four marks at most.
  The last tool's keeps the tool definitions cached when the system prompt changes (an
  instruction file edited, a `remember`, a goal set). The system prompt's caches the
  tools and the system prompt together. The newest user message's last block writes
  the whole conversation for the next call, and the user message before it is where
  the previous call put its mark: Anthropic looks back at most twenty blocks from a
  mark for an earlier entry, and with a mark on that very block the previous call's
  cache is read however much came in between.
- **The task list goes behind the system prompt's mark.** `todo_write` rewrites the
  list within a turn, and the list was the system prompt's last section, so every
  rewrite changed the prefix in front of that mark. It is now the request's
  `system_tail`: still the end of the system prompt and rendered fresh for each
  request, as 678 has it, sent to Anthropic as a second system block after the mark
  and to an OpenAI-compatible provider joined to the system message exactly as before
  (`Request.system_text/1`). What this does not settle: the conversation's marks come
  after the whole system prompt, so the call after a rewrite reads the tools and the
  system prompt and writes the conversation again instead of reading it. Putting the
  list after the conversation was not taken. A block added to the last user message
  and gone from it on the next request is an edit of history, which on the newest
  models invalidates the replayed thinking behind it and the cache with it; keeping
  every copy is the message in the conversation 678 declined. Holding the list still
  for a turn, or a system message in the conversation where the model takes one, is
  left for a later slice, measured first.
- **Who asks.** `Request.cache` is false unless set, and the agent's own requests set
  it. A one-off does not, the compaction summary among them: a cache write costs more
  than plain input, and nothing would read it back.
- **The cache's life.** Anthropic's default of five minutes, which each read renews,
  and a turn's calls come well inside it. The hour-long cache costs twice the input
  price to write and is not asked for. Nothing here is configurable. A prompt shorter
  than the model's minimum (512 to 4096 tokens, by model) is not cached, silently.
- **What a provider reports.** Anthropic's `cache_read_input_tokens` and
  `cache_creation_input_tokens` were already read beside `input_tokens` (657), and an
  OpenAI-compatible provider's `prompt_tokens_details.cached_tokens` out of
  `prompt_tokens`; both reach `llm_response.usage`, and a call priced here is priced at
  the cache rates of the catalog or `models.prices` where they are set (689). OpenAI
  caches a long enough prompt without being asked and reports what it served. A
  LiteLLM or self-hosted gateway behind `provider: openai` caches whatever it and the
  model behind it do, which may be nothing, and `cache_read` says which; no marks go
  on that wire. `docs/user/configuration.md` says this per provider.
- **Proof:** `Troupe.Agent.PromptCacheTest`. A thirty-call turn against a loopback
  stand-in that caches what is marked as Anthropic does reads the cache on every call
  after the first: all of the previous call's prompt where the task list was
  unchanged, and the tools and the system prompt, the same each time, after the list
  was rewritten. The log holds the stand-in's figures, and each call is priced at the
  cache rates. On the tip every read was zero. The same stand-in as an
  OpenAI-compatible server caches unasked, and its `cached_tokens` lands as
  `cache_read` and out of `input_tokens`. `Troupe.LLM.ProvidersTest`: the four marks
  and where they go, the task list after the system prompt's, and nothing marked on a
  request not to be cached or on the OpenAI-compatible wire. And the installed daemon,
  with scratch homes, run against a stand-in like the test's: a session made over the
  protocol with `provider: anthropic` pointed at it took ten calls for one input, each
  marked on the last tool, the system prompt and the last two user messages, and
  every call after the first read the cache, the two after a rewritten task list the
  tools and the system prompt; the build installed before it marked nothing and read
  nothing on any of the ten.
