---
number: 66
title: Every answer to a request logs `branch_state`, and the TUI additionally derives `needs_input` from what is still pending rather than trusting the flag
date: 2026-09-15
status: accepted
paths:
  - apps/troupe_core/lib/troupe/session/approvals.ex
gist: Every answer to a request logs `branch_state`, and the TUI additionally derives `needs_input` from what is still pending rather than trusting the flag
---

Decision 63 made the window keep `needs_input` while any of its agents had an outstanding request; the other half was missing, and `y`/`a` on a budget question exposed it. `budget_ask_answered` clears the pending item and nothing else — the `:deny` branch logged `branch_state :running` on its way to `finish/3` while the allow branch went straight back to `start_turn`, so the flag was never taken down. For a root agent the eventual `done_unread` covered it up; for a **subagent** `finish/3` writes no `branch_state` at all, so answering a delegated agent's budget question left the branch blinking "waiting for you", counted in the attention line and picked by Enter, until the root finished — which is exactly the shape the bug report described, and why it looked like the answer was "not delegated up". `after_user_answer/1` is now on the budget path too (widened to consider `budget_ask_pending`, so it cannot clear while the question is still open), which fixes the Dispatcher and `Session.Index` ledgers as well: they fold `branch_state` and nothing else, so an event is the only way to tell them anything. The UI then stops depending on the event being perfect: `needs_input` with an empty `pending` is settled to `:running` on the next event, since the two are the same fold and the flag is redundant. That also closes the case no event can cover — `Approvals` deletes its entry on `{:DOWN, ...}` without logging, so a request whose agent died was unanswerable *and* pinned the window, because Decision 63's `pending != []` guard then blocked every future `:running`. `delegation_completed` and `cancelled` drop the pending items of that path and its descendants, the two points at which a subtree is known to be dead.
