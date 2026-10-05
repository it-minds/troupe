---
number: 660
title: "A spent budget is a question for the person attached, not a stop: `allow` buys the same slice again, `always` lifts that limit for the agent and its subagents, `deny` ends the agent; a budget the plane's terms set is a contract and stops; `full_send` never asks; an unattended session answers no itself"
date: 2026-09-20
status: accepted
paths:
  - ARCHITECTURE.md
  - PROTOCOL.md
  - apps/troupe_core/lib/troupe/agent/budget_question.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/budget.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/sessions/index.ex
  - apps/troupe_core/test/troupe/agent/budget_question_test.exs
  - apps/troupe_core/test/troupe/agent/resilience_test.exs
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_worker/lib/troupe/worker/session/restore.ex
  - clients/gui/apps/desktop/src/views/Question.tsx
  - clients/gui/packages/client/src/transcript.ts
  - clients/tui/lib/troupe/remote/translate.ex
gist: "A spent budget is a question for the person attached, not a stop: `allow` buys the same slice again, `always` lifts that limit for the agent and…"
---

Ending the agent is what a
limit is for on a pod running the plane's terms, and exactly wrong on a laptop
where the person watching would gladly buy another forty turns to see the branch
finish. The question rides on what the harness already has rather than on a
mechanism of its own: the agent hands a question to `Troupe.Session.Questions` —
the `ask_user` path — with `call_id` `budget-<n>`, `detail` (`turns 40/40 (100%)`)
as the text and `allow` / `always` / `deny` as the options, so a client that can
answer an `ask_user` can answer this and needs no method of its own; a task waits
on the answer, since the agent must not block; the agent sits in `waiting`, where
input queues as it does mid-turn. `allow` adds the allowance the agent was first
given (`Budget.grant/1`, so grants do not compound) and forgets which limits were
warned about, because a fresh slice is a fresh warning; the question comes back at
the end of that slice, a checkpoint each time rather than one irreversible yes.
`always` lifts the limit the question was about, and no other (687), and a
delegation inherits it: a person who lifted it for the root did not mean each of its
children to stop at it. The events are
`budget_ask_started` and `budget_ask_answered` (with the `grant`), both folded: the
grant survives a restart, and a `budget_ask_started` without its answer leaves the
question owed, asked again under the same id, where the questions server hands back
an answer given meanwhile rather than asking twice. The budget is checked when a
model call is about to be made and nowhere else — an agent whose turn ended with
the budget spent rests idle and asks when next given something to do — except where
the budget is a contract: `budget_asks: false`, which the worker sets whenever the
plane's terms set anything at all, keeps the stop, because a limit somebody wrote
into a session's terms is not a suggestion. A subagent never asks either: its
budget is a slice its parent gave it, and what it found goes back to the parent
labelled partial for the parent to delegate again if it wants more — a subtree
waiting on a person while its parent's tool call hangs would be the worse shape.
`full_send` passes the gate without asking; a session running `approvals: deny`
gets the questions server's unattended answer, which is no.
