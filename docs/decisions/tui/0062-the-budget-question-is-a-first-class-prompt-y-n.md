---
number: 62
title: "The budget question is a first-class prompt: `y`/`n`/`a` answer it, `y` actually lets that one agent past its budget, and no pending kind can reach the renderer without a clause"
date: 2026-09-15
status: accepted
paths:
  - apps/troupe_core/lib/troupe/session/approvals.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
gist: "The budget question is a first-class prompt: `y`/`n`/`a` answer it, `y` actually lets that one agent past its budget, and no pending kind can reach…"
---

A delegated subagent runs on a fraction of its parent's remaining budget (`Budget.share/4`), so it is normally the first agent in a session to exhaust one — and asking cost the user the whole session. The side panel and the observer's detail pane matched only `:approval` and `:question`, so the `:budget` item raised a `FunctionClauseError` inside `View.render/2`; ExRatatui rescues a render and drops the frame, so the terminal froze on its last good contents while the app went on consuming keys, which is indistinguishable from a hang. Underneath that the prompt was unanswerable anyway: `window_key/3` matched `kind == :approval`, so `y` was typed into the input box, and Enter then sent `"y"` to an agent that was `:acting` and postponed it. Even a delivered `:allow` did nothing, because the fold wrote `budget_overridden` into the agent's own state and `start_turn` read only the session-wide flag in `Approvals` — the question came straight back, so `a` was the sole way past a budget and it lifted it for every agent in every branch. `y` now means this agent, `a` still means the session, `n` still ends the branch with `:budget_exhausted`, and the headless printer answers `n` rather than leaving a run blocked in `wait()` on a keypress nobody can make. The lines the two panels render come from one `pending_summary/2` with a catch-all clause, and `Model.pending_blocks/2` has one too: a prompt the user cannot answer is a bug, but a prompt that stops the screen from redrawing costs them the session, so an unknown `kind` must degrade to a row of text.
