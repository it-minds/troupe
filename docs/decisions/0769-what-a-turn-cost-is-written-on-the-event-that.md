---
number: 769
title: What a turn cost is written on the event that ends it, and what each model call's prompt was made of on its `llm_request`, in bytes
date: 2026-10-04
status: accepted
issue: 389
paths:
  - apps/troupe_core/lib/troupe/agent/spend.ex
  - apps/troupe_core/lib/troupe/log/fold.ex
  - apps/troupe_core/lib/troupe/session/usage.ex
gist: What a turn cost is written on the event that ends it, and what each model call's prompt was made of on its `llm_request`, in bytes
---

A turn, one input until the agent rests, is many model calls, each resending the whole
conversation.
- **Per turn.** `turn`, with `calls`, the four token figures summed, `cost_micros` and
  `unpriced`, on whichever event ends the turn: `turn_ended`, `cancelled` or
  `agent_done`. A field on those, not an event of its own: a client ignores a field it
  does not know, while the terminal UI prints an event type it does not know as a note,
  so a new type would have written itself into every older client's transcript at every
  turn. `Troupe.Agent.Spend` adds each call as `record_response/2` takes it, and the
  agent's replay adds the same from `llm_response` and starts again at each of the
  three, so a restart in the middle of a turn still counts the calls made before it.
- **A subagent's calls are its parent's turn's.** A turn that delegates has paid for what
  its subagents did, and the window's session count already includes them, so a turn's
  figure without them would disagree with the total it sits under. A subagent hands its
  parent its `Spend` in its result, where `Budget.usage/1` was: the budget is charged that
  `usage`'s billed part, the same tokens as before, and the parent's turn adds the whole
  of it. The subagent's own `agent_done` says what its task cost.
- **Money.** `cost_micros` adds up the calls' `gateway.cost_micros`, the gateway's own
  figure or this machine's arithmetic (689), so a turn is priced exactly as the listing
  is. A call nobody priced is counted in `unpriced` and left out of the sum rather than
  added as nothing, so a reader can tell free from not known, as PROTOCOL.md asks of a
  reader of `gateway`.
- **Per call.** `llm_request.prompt_bytes`: `system` (the whole system prompt, the end a
  request keeps apart for the prompt cache included, 770), `brief` (the part of it that is
  the instruction files and the project brief, 706), `tools` (the definitions as a JSON
  list of name, description and schema), `conversation` (each message as
  `Message.to_json/1` writes it), `tool_results` (the part of it that is tool results'
  text) and `total` (`system + tools + conversation`). On the request because it is what
  was sent, so a call that failed still says what it sent.
- **Bytes as the log writes them, not characters or estimated tokens.** And they are the
  same whoever answers, where an estimate of tokens would be a second tokenizer that
  disagrees with the provider's: the response's `input_tokens + cache_read + cache_write`
  is the real count, and scales the parts to tokens for whoever wants them.
- **The summariser's call is counted.** The call that writes a compaction's summary is
  billed like any other and was in nothing: not the log, the listing, the budget or the
  ledger. It is not an `llm_response`, which the agent's replay reads as its reply and a
  client draws as one, and not an `llm_request` either, which a listing reads as a call
  still unanswered until an `llm_response` follows. So the `compacted` that takes its
  answer carries what those two say of a call: `model`, `prompt_bytes`, `usage` and
  `gateway`, priced as the cheap model it addressed.
- **Not counted:** an ACP delegate's model, which is its own.
