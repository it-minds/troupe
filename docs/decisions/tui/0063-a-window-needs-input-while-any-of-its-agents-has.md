---
number: 63
title: A window needs input while *any* of its agents has an outstanding request, and `y`/`n`/`a`/Enter answer the request belonging to the agent whose pane is open
date: 2026-09-15
status: accepted
paths:
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
gist: A window needs input while *any* of its agents has an outstanding request, and `y`/`n`/`a`/Enter answer the request belonging to the agent whose…
---

`branch_state` is window-scoped, but each agent emits it from `State.awaiting_user/1`, which sees only that agent's own calls — so with the root and a subagent both waiting, answering the root logged `branch_state running` and the window stopped advertising the subagent: no badge, no "needs input" in the attention line, and Enter on an empty command line no longer routed there. The prompt was still drawn inside the pane, prefixed `[code-1/general-1]` per Decision 46, so the branch was reachable but only by someone who already knew to look. Rather than make the event agent-aware — it is a window's state, and the Dispatcher folds it as one — `UI.TUI.Model` keeps `:needs_input` while `w.pending` is non-empty, since the pending list is the same fold and already carries `agent_path` for every item. That `agent_path` now also picks *which* request the keys answer: previously `Enum.find(w.pending, kind == :approval)` took the oldest in the window, so `y` while reading a subagent's transcript could allow the root's `shell`. The dispatcher's ledger still folds no approval events and so still clears its own copy early; it drives `Troupe.windows/1` and reconcile-on-restart, not what the user is shown.
