---
number: 788
title: A model call the agent gives up on is stopped, at its timeout in a turn or in a compaction and on a cancel alike, and what the provider had reported of it is counted as any call's figures are
date: 2026-10-05
status: accepted
paths:
  - ARCHITECTURE.md
  - PROTOCOL.md
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/bench/live.ex
  - apps/troupe_core/lib/troupe/llm/provider.ex
  - apps/troupe_core/lib/troupe/llm/providers/anthropic.ex
  - apps/troupe_core/lib/troupe/llm/providers/openai.ex
  - apps/troupe_core/lib/troupe/session/usage.ex
  - apps/troupe_core/lib/troupe/sessions/index.ex
  - apps/troupe_core/test/support/endless_stand_in.ex
  - apps/troupe_core/test/troupe/agent/stopped_call_test.exs
  - apps/troupe_core/test/troupe/llm/providers_test.exs
  - apps/troupe_core/test/troupe/log/fold_test.exs
  - apps/troupe_core/test/troupe/session/usage_test.exs
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
gist: A model call the agent gives up on is stopped, at its timeout in a turn or in a compaction and on a cancel alike, and what the provider had…
---

The first item of D69. `llm_timeout_ms` gave a
call up and left it running: `clear_llm/1` only demonitored the task streaming it,
and Req's `receive_timeout` bounds only the gap between packets, so a reply that kept
coming went on being generated, and billed, up to `max_tokens` while the agent went
on without it, and nothing of it was counted. A cancel did stop the stream, since it
ends every task the agent runs while a call is in flight, but counted nothing either.
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
- **A summary given up on** is stopped and counted live, in the turn's figures, the
  budget and the listing, but is written nowhere: a failed summary never was (774),
  and the events in that path are ones it must not look like (`llm_error` ends a turn
  for the desktop app and fails an A2A task). Writing it is a new event type, left for
  later; until then a restart in the same turn forgets it, and the ledger has no row.
- **Proof:** core's `StoppedCallTest`. Against the fake model with a step that streams
  for ever (`{:endless, ms}`, after reporting the prompt's usage, or `:no_usage`): a
  turn's call and a compaction's summary still streaming at `llm_timeout_ms` are
  stopped (the agent's task supervisor is empty), the `llm_error` says what the call
  reported and the turn counts it (one call and 100 tokens; six calls and 600 with the
  compaction); one that reported nothing is a call and `unpriced`; a cancel says what
  it stopped; and a restart charges the budget what the live agent was charged.
  Against a loopback stand-in speaking Anthropic's and OpenAI's wire, streaming a
  delta every 100 ms for ever: the connection of a call stopped at its timeout is
  closed after deltas were sent, Anthropic's `message_start` is counted and priced
  (6,165 micro-dollars), and the OpenAI-compatible call had reported nothing. All seven
  fail on the chunk's tip: three still had a stream running after the timeout, the
  two on the wire a connection still open, and the cancel and the restart counted
  nothing.
  `ProvidersTest`: each adapter says usage as it comes, Anthropic's prompt before the
  first delta; `UsageTest`: a stopped call is a ledger row when it had usage;
  `FoldTest`: its tokens are the agent's.
