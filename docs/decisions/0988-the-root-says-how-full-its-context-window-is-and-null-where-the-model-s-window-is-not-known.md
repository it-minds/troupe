---
number: 988
title: "The root agent says how full its context window is in an ephemeral context_status, after each call and before a turn on a model it has not yet said, with the window the model is known to have, or null where only the fallback is"
date: 2026-11-15
status: accepted
issue: 920
supersedes: [986]
paths:
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/gui/scripts/fake-deployment.ts
symbols:
  - Troupe.Config.known_window/2
gist: "context_status {window_tokens, used_tokens}: ephemeral, root only, after each call; window null where only context_window's fallback says one"
---

Issue #920's first part. The desktop's composer draws a ring of how full the context is
(Decision 986). The stream carried each call's `usage` and nothing said the model's window,
so the ring was a turning quarter arc.

**The event.** `context_status` `{window_tokens, used_tokens}` on the root agent, published
after each of its `llm_response`s, and before the first call of a turn on a model it has not
said the window of: the first turn of the agent's process, which covers a new session and
one woken from dormancy, and a turn after the model changed (a profile switch, a definition
with another model). `used_tokens` is the last call's whole prompt, cached or not, the
number compaction and `agent_state.budget.headroom` already read (Decision 657).

**The window.** `Troupe.Config.known_window/2`: what a provider's `models:` entry or
`models.windows` declares, else what the provider's model list reported into the catalog,
else `nil`. `context_window/2`, which compaction plans against, is that or the
`context_window` fallback (200 000 by default). The fallback is not sent: it is a number
nobody said about this model (Decision 799's reason for `troupe models` leaving it out), and
a ring drawn as the share of it would look exact and be a guess. With `null` the client
keeps its indeterminate arc and says the tokens in.

**Ephemeral.** It is derived from the log's `llm_response` and the configuration, so a
replay loses nothing a client could not work out; written down it would be one more event
per call in every log. A client that attaches between two calls has the window from the
next one. Not chosen: a field on `session_created` (it is not re-sent when the model
changes) or on `llm_response` (the log would then carry a configuration fact on every
call). Only the root's: a subagent's window is not what the composer is about.

**What an older client sees.** An event type it does not know, which the protocol says it
ignores. The desktop already folded it behind a type guard (`contextStatus`).

**Decision 986** said the ring waits on #920; that part is replaced by this.

## Proof

`apps/troupe_core/test/troupe/agent/context_status_test.exs`: with a declared window the root
says it before its first call (`used_tokens` 0) and after each call (the fake's 100), nothing
before the turn's second call on the same model, and nothing in the log; a model with no
known window says `null`; `known_window/2` has no fallback while `context_window/2` keeps it.
All failed on the chunk's tip, which had no such event or function. The fakes send it after
each call, and `session-chat.test.tsx` shows the ring turning into the share once a pod's
call says the window.
