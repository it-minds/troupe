---
number: 770
title: "An agent's own model calls ask Anthropic to cache the prompt, with four marks: the last tool, the system prompt without its task list, and the last two user messages. An OpenAI-compatible provider caches by itself, and what either reports reaches the log"
date: 2026-10-04
status: accepted
issue: 389
paths:
  - apps/troupe_core/lib/troupe/agent/spend.ex
  - apps/troupe_core/lib/troupe/llm/providers/anthropic.ex
  - apps/troupe_core/lib/troupe/llm/providers/openai.ex
gist: "An agent's own model calls ask Anthropic to cache the prompt, with four marks: the last tool, the system prompt without its task list, and the last…"
---

Issue #389, slice 2. Every model call of a turn sends the whole conversation again, and
Anthropic's prompt cache is opt-in: a request with no `cache_control` mark caches nothing,
so every resend was billed as fresh input.
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
- **The task list goes behind the system prompt's mark.** `todo_write` rewrites the list
  within a turn, and the list was the system prompt's last section, so every rewrite
  changed the prefix in front of that mark. It is now the request's `system_tail`: still
  the end of the system prompt and rendered fresh for each request, as 678 has it, sent to
  Anthropic as a second system block after the mark and to an OpenAI-compatible provider
  joined to the system message exactly as before (`Request.system_text/1`). What this does
  not settle: the conversation's marks come after the whole system prompt, so the call
  after a rewrite reads the tools and the system prompt and writes the conversation again
  instead of reading it. Putting the list after the conversation was not taken. A block
  added to the last user message and gone from it on the next request is an edit of
  history, which on the newest models invalidates the replayed thinking behind it and the
  cache with it; keeping every copy is the message in the conversation 678 declined.
- **Who asks.** `Request.cache` is false unless set, and the agent's own requests set
  it. A one-off does not, the compaction summary among them: a cache write costs more
  than plain input, and nothing would read it back.
- **The cache's life.** Anthropic's default of five minutes, which each read renews,
  and a turn's calls come well inside it. The hour-long cache costs twice the input
  price to write and is not asked for. Nothing here is configurable. A prompt shorter
  than the model's minimum (512 to 4096 tokens, by model) is not cached, silently.
- **What a provider reports.** OpenAI caches a long enough prompt without being asked and
  reports what it served. A LiteLLM or self-hosted gateway behind `provider: openai`
  caches whatever it and the model behind it do, which may be nothing, and `cache_read`
  says which; no marks go on that wire.
