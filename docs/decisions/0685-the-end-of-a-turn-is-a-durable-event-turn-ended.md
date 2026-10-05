---
number: 685
title: The end of a turn is a durable event, `turn_ended`, beside the ephemeral `agent_state`
date: 2026-09-25
status: accepted
issue: 127
paths:
  - PROTOCOL.md
  - apps/troupe_core/test/troupe/agent/loop_test.exs
  - apps/troupe_core/test/troupe/agent/turn_ended_test.exs
  - apps/troupe_core/test/troupe/session/log_schema_test.exs
gist: The end of a turn is a durable event, `turn_ended`, beside the ephemeral `agent_state`
---

An agent whose turn ends without `finish` — a reply in prose, or a
failed model request — rests `idle`, and until now only the live `agent_state` said
so. That event is ephemeral: a client that attached after the turn ended never saw
it, and a connection that falls behind drops it. `troupe run --headless` is exactly
that client, since its session starts working before anything has subscribed, and
against a real model it never exited (issue #127). The agent now logs `turn_ended`
(no fields) just before it publishes `idle`, from the one place a turn comes to rest;
a cancelled turn still ends with `cancelled` and a finished agent with `agent_done`,
so between them the three say from the log alone that an agent is waiting. It is an
added event type, which PROTOCOL.md §11 allows and clients must ignore when they do
not know it; the GUI does, and the TUI reads it as the `idle` it is (clients/tui
Decision 112). The Loop and the sealer keep reading the live state, which in-process
they cannot miss, and the index keeps asking the agent.
- **Proof:** `Troupe.Agent.TurnEndedTest`, the whole-turn sequence in
  `Troupe.Agent.LoopTest`, `Troupe.Session.LogSchemaTest` (the schema knows the type),
  and `mix troupe.schema.diff`.
