---
number: 655
title: A limit is announced before it stops the agent, once, and a client can draw the gauge
date: 2026-09-20
status: accepted
paths:
  - apps/troupe_core/lib/troupe/agent/headroom.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/test/troupe/agent/headroom_test.exs
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/tui/lib/troupe/remote/translate.ex
gist: A limit is announced before it stops the agent, once, and a client can draw the gauge
---

`Troupe.Agent.Headroom` is pure and read after every model response: five
fractions — turns, input tokens, output tokens, wall clock, and the model's context
window, which is the provider's ceiling rather than ours. A dimension that crosses
`budget_warn_at` writes a `budget_warning` with the numbers and a sentence
(`input tokens 4.9M/6.0M (82%)`), and is not warned about again by that agent;
`agent_state.budget.headroom` carries all five fractions always, so a client draws a
gauge without knowing how each limit is counted. The warning is durable, not
ephemeral, although the numbers are in `agent_state` for whoever asks later: the
contract lets an ephemeral be dropped under load, and a warning that may not arrive
is not one. The agent's replay ignores it, so it moves no fixture. `full_send: true`
turns the warnings off for a session that wants no nagging, and a client may set it
at `session.create`. What happens at the ceiling is 660.
