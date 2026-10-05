---
number: 64
title: Re-registering a `call_id` with `Approvals` demonitors the process it replaces, and a restarted agent re-registers its budget question under the original id instead of logging a new one
date: 2026-09-15
status: accepted
paths:
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/session/approvals.ex
gist: Re-registering a `call_id` with `Approvals` demonitors the process it replaces, and a restarted agent re-registers its budget question under the…
---

`Agent.Server` replays and re-registers an outstanding request after a crash, reusing the `call_id` and writing no event, precisely so the UIs' folded pending item stays valid — except `resume_budget_ask/1` minted a fresh `"budget-<N>"` and logged a second `budget_ask_started`, so every Node restart left one more pending item that no answer could remove and, before Decision 62, one more guaranteed render crash. The id is now folded into `Agent.State` alongside `budget_ask_pending` for the resume to reuse. The monitor is the matching half: `pending` is keyed by `call_id` and `monitors` by ref, so a re-register left the dead process's ref behind, and its `:DOWN` — if it arrived after the restart rather than before, which nothing orders — resolved to the shared `call_id` and deleted the live entry. `Process.demonitor(ref, [:flush])` on the replaced entry is what makes reuse safe; this one is reasoned rather than tested, because the ordering it guards against is not one a test can force.
