---
number: 769
title: What a turn cost is written on the event that ends it, and what each model call's prompt was made of on its `llm_request`, in bytes
date: 2026-10-04
status: accepted
issue: 389
paths:
  - PROTOCOL.md
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/spend.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/bench/live.ex
  - apps/troupe_core/lib/troupe/log/fold.ex
  - apps/troupe_core/lib/troupe/session/usage.ex
  - apps/troupe_core/lib/troupe/sessions/index.ex
  - apps/troupe_core/test/troupe/agent/tool_failures_test.exs
  - apps/troupe_core/test/troupe/agent/turn_cost_test.exs
  - apps/troupe_core/test/troupe/agent/turn_ended_test.exs
  - apps/troupe_core/test/troupe/bench_live_test.exs
  - apps/troupe_core/test/troupe/session/usage_test.exs
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/gui/apps/desktop/test/turn-cost.test.tsx
  - clients/gui/packages/client/src/transcript.ts
  - clients/gui/packages/client/test/turn-cost.test.ts
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/test/troupe/turn_cost_test.exs
  - docs/developer/bench.md
gist: What a turn cost is written on the event that ends it, and what each model call's prompt was made of on its `llm_request`, in bytes
---

Issue #389, slices 1 and 4; the
terminal UI's half is TUI Decision 139. A turn, one input until the agent rests, is
many model calls, each resending the whole conversation. The log had each call's
tokens and cost (`llm_response.usage` and `gateway.cost_micros`, 657 and 689) and
nothing that said how many calls a turn took, what they came to together, or which
part of the prompt was the large one, so a turn billed in millions of tokens could not
be traced to any of the four causes the issue names.
- **Per turn.** `turn`, with `calls`, the four token figures summed, `cost_micros` and
  `unpriced`, on whichever event ends the turn: `turn_ended`, `cancelled` or
  `agent_done`. A field on those, not an event of its own: a client ignores a field it
  does not know, while the terminal UI prints an event type it does not know as a note,
  so a new type would have written itself into every older client's transcript at every
  turn. `Troupe.Agent.Spend` adds each call as `record_response/2` takes it, and the
  agent's replay adds the same from `llm_response` and starts again at each of the
  three, so a restart in the middle of a turn still counts the calls made before it.
- **A subagent's calls are its parent's turn's.** A turn that delegates has paid for
  what its subagents did, and the window's session count already includes them, so a
  turn's figure without them would disagree with the total it sits under. A subagent
  hands its parent its `Spend` in its result, where `Budget.usage/1` was: the budget is
  charged that `usage`'s billed part, the same tokens as before, and the parent's turn
  adds the whole of it. The subagent's own `agent_done` says what its task cost. Live
  only, as the budget's charge always was: a cancel stops a subagent before it reports,
  and a parent restarted mid-turn forgets what its subagents had reported. Writing each
  delegation's spend on the parent's side of the log would make it replayable, and is
  not done here.
- **Money.** `cost_micros` adds up the calls' `gateway.cost_micros`, the gateway's own
  figure or this machine's arithmetic (689), so a turn is priced exactly as the listing
  is. A call nobody priced is counted in `unpriced` and left out of the sum rather than
  added as nothing, so a reader can tell free from not known, as PROTOCOL.md asks of a
  reader of `gateway`.
- **Per call.** `llm_request.prompt_bytes`: `system` (the whole system prompt, the end a
  request keeps apart for the prompt cache included, 770), `brief` (the part of it
  that is the instruction files and the project brief, 706), `tools` (the definitions
  as a JSON list of name, description and schema), `conversation` (each message as
  `Message.to_json/1` writes it), `tool_results` (the part of it that is tool results'
  text) and `total` (`system + tools + conversation`). The provider's own input, cached
  and output figures were already on the `llm_response` that answers the call. On the
  request because it is what was sent, so a call that failed still says what it sent.
- **Bytes as the log writes them, not characters or estimated tokens.** It is the
  measure `troupe bench` takes of a request (772), less its writing the workspace's path
  as `<workspace>`, so a live run can read its `calls[]` from the log and agree with an
  offline one. Bytes are the unit `tool_output_limit` is set in, so the measurement reads
  straight against the default slice 3 is to move. And they are the same whoever
  answers, where an estimate of tokens would be a second tokenizer that disagrees with
  the provider's: the response's `input_tokens + cache_read + cache_write` is the real
  count, and scales the parts to tokens for whoever wants them. The price is encoding
  the conversation once more a call, which the log does for every message anyway.
- **The summariser's call is counted.** The call that writes a compaction's summary is
  billed like any other and was in nothing: not the log, the listing, the budget or the
  ledger. It is not an `llm_response`, which the agent's replay reads as its reply and
  a client draws as one, and not an `llm_request` either, which a listing reads as a
  call still unanswered until an `llm_response` follows. So the `compacted` that takes
  its answer carries what those two say of a call: `model`, `prompt_bytes`, `usage`
  and `gateway`, priced as the cheap model it addressed. The budget is charged its
  billed tokens and not a turn, since `max_turns` counts the agent's own calls; the
  turn counts it among its `calls`; the listing adds it, live and from the log; the
  ledger makes a row of it (`Troupe.Session.Usage`), so a team's money budget on the
  plane has it too; telemetry's `[:troupe, :llm, :stop]` fires for it with
  `summariser: true`; and the replay charges and counts it again from the event. A
  `compacted` written before this has none of it, and folds as it always did.
- **Not counted:** an ACP delegate's model, which is its own.
- **The witness.** The agent's replay now acts on `cancelled`, so `Troupe.Log.Fold`
  witnesses it, a `cancels` count present only once there has been one, and adds a
  `compacted`'s usage to the agent's tokens; no recorded fixture holds a cancel or a
  compaction with usage, and no hash moves.
- **Proof:** core's `turn_cost_test.exs`: a turn of three calls sums the three responses
  (945 micros); two calls' prompt parts, the brief from an `AGENTS.md`; a turn that
  compacts counts five calls, four replies and the summariser, whose `compacted` says
  what it was made of and cost and whose tokens the budget was charged; a model with no
  price; the next turn counting from nothing; a delegation's four calls, with the
  subagent's two on its own `agent_done`; a cancel; a finish; and a kill in the middle of
  a turn that keeps the calls before it. The eight written first fail on the chunk's
  tip, and the compaction one reads fields the tip does not write. `UsageTest`: a
  `compacted` with usage is a ledger row, one from before is not. The terminal UI's
  test is 139's, and the installed daemon and `troupe` are on the pull request.
