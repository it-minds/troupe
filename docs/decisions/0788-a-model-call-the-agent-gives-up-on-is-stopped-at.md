---
number: 788
title: A model call the agent gives up on is stopped, at its timeout in a turn or in a compaction and on a cancel alike, and what the provider had reported of it is counted as any call's figures are
date: 2026-10-05
status: accepted
paths:
  - apps/troupe_core/lib/troupe/llm/provider.ex
  - apps/troupe_core/lib/troupe/llm/providers/anthropic.ex
  - apps/troupe_core/lib/troupe/llm/providers/openai.ex
gist: A model call the agent gives up on is stopped, at its timeout in a turn or in a compaction and on a cancel alike, and what the provider had…
---

- **Stopped by ending the task.** The timeout in `:thinking`, the timeout in
  `:compacting` and a cancel go through one `stop_llm/1`, which ends the task as a
  cancel did. The HTTP connection is checked out to that process, so the pool closes
  it when the process ends, and the provider sees the request go. Asking the adapter
  to stop was the other way, and is not taken: a task waiting between packets cannot
  hear it, and ending the process is what closes the connection either way.
- **Usage as it comes.** The adapters tell the agent what the provider has reported
  while the reply streams, `{:llm_usage, ref, usage}`, the running total, where it
  used to reach the agent only in the response. Anthropic reports the prompt's figures
  in `message_start`, before the first word, and the output in `message_delta` at the
  end; an OpenAI-compatible server reports usage in its last chunk only. Once the task
  has ended the agent reads what was already in its mailbox, a later report or an
  answer that came just as it gave up, so nothing reported before the stop is lost.
- **Counted as any call.** The stopped call goes through `count_call/4` as a reply
  does: the listing, telemetry's `[:troupe, :llm, :stop]` (with `stopped: true`), the
  budget's tokens (not a turn: `max_turns` counts the agent's replies) and the turn's
  `turn`. It is priced as a call the gateway did not price is (689), from the catalog
  or `models.prices`; the summariser's as the cheap model, as its `compacted` is.
- **Written on the event that says it stopped.** The timeout's `llm_error`, or the
  `cancelled`, carries `stopped`: `model`, and `usage` and `gateway` in the words
  `llm_response` uses, when the provider had reported any. One object rather than
  the fields flat, because `cancelled` already has the turn's figures beside it; not
  an event of its own, which an older terminal UI would print as a note (769). The
  agent's replay charges the budget and counts the turn from it, `Troupe.Log.Fold`
  adds its tokens, a dormant session's listing its tokens and cost, the ledger
  (`Troupe.Session.Usage`) makes a row of one that had usage, and `troupe bench
  --live` adds its cost to what a run has spent. PROTOCOL.md and the schema say so.
- **A call that had reported nothing counts as a call, and nothing else.** It is one
  of the turn's `calls` and one of its `unpriced`, with no tokens and no cost, and
  its `stopped` has only `model`. Not an estimate: one made from the prompt's bytes
  or from the text streamed is a second tokenizer that disagrees with the provider's,
  which 769 declined for the same reason, and it would go into the sums the budget
  and the plane's ledger read with nothing there to tell it from a provider's count.
  `unpriced` already says "not known". What is not counted is bounded by the stop:
  what the model wrote before `llm_timeout_ms` ran out, rather than everything up to
  `max_tokens`. The same holds for the output an Anthropic reply had written, which
  its provider reports only at the end.
