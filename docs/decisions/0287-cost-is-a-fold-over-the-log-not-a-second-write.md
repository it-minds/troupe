---
number: 287
title: Cost is a fold over the log, not a second write path
date: 2026-09-13
status: accepted
paths:
  - apps/troupe_core/lib/troupe/session/log.ex
gist: Cost is a fold over the log, not a second write path
---

Every model call already
left a durable `llm_response`; making it carry the model, the gateway's request id
and the cost means the ledger is derivable from what the pod already wrote down.
The alternative — a second record kept beside the log — has to be made durable
itself, and then has its own recovery story. This one's recovery story is
`Log.replay_from/2`.
