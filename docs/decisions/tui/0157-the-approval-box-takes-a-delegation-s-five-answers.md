---
number: 157
title: "A delegation at the gate is drawn whole in the window's approval box and answered with y run, e edit a part in the box, s switch the subagent, n deny with a word typed back, a always for that agent; the draft is the window's until it is answered"
date: 2026-10-11
status: accepted
issue: 554
paths:
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/lib/troupe/remote/worker.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/ui/headless/printer.ex
  - clients/tui/test/troupe/delegation_gate_test.exs
symbols:
  - Troupe.UI.TUI.Model.gate_draft/2
  - Troupe.UI.TUI.Model.gate_answer/2
gist: "Gate in the approval box: y run, e+digit edits a part in the box, s+digit switches agent, n types a word back, a always; draft is the window's"
---

Root Decision 850 puts a delegation a person asked to see through the approval gate, with
five answers where an approval had three. The window's approval box is where a TUI
person answers approvals (`y`/`n`/`a`, Decision 62), so the gate is drawn and answered
there, not on a screen of its own.

- **What it shows.** The `DELEGATE to <agent>` line with the keys, then where its
  definition is with the command that opens it (`/agents <agent>`; the box never edits
  one), the child's depth of the cap, its share of the budget and every tool it will hold
  with its permission, then the brief's five parts under their names, an edited one
  marked `(edited)` in the added colour. The side panel and command mode's line say
  `delegation to <agent> (y / e / s / n / a in the window)`, and the window's hint says
  `y/e/s/n/a delegation` where it said `y/n/a approve`.
- **The keys,** with nothing typed: `y` runs it, `a` runs it and lets that agent run
  unasked for the session, either with what the draft changed; `e` asks which part, a
  digit picks it and the part goes into the box as it stands, to be changed there, Enter
  keeping it and Shift-Enter starting a line; `s` lists the subagents numbered and a digit
  sends the brief there; `n` asks for a word back, typed in the box, and Enter sends the
  denial with it, or with none. Esc leaves a step and keeps the draft. While the box waits
  for words every key types, so `y` and `n` are letters of a word back. `e` toggles
  expanded output everywhere else, as before.
- **The draft is the window's, not the log's.** Edits and a switch are a cursor, like a
  multiple-choice question's ticks (`state.answer`): kept in the UI process for the call
  on screen, dropped when another window is activated, and sent only when the person
  answers. A draft for another call is a fresh one (`Model.gate_draft/2`). A part kept
  empty is refused on the spot, as the daemon would refuse it; a part typed back as it was
  is no edit. A refusal from the daemon is the notice line, and the draft stays.
- **Headless** denies it, as it denies every request with nobody to ask, with a line
  saying it asks because of `delegation.ask` or the definition's `delegation: ask` and
  that `--auto-approve` does not answer it.
- **Proof:** `Troupe.DelegationGateTest`, against the daemon the VM embeds: the box shows
  the delegation, `e` `3` edits the constraints in the box and `y` runs it with them; `y`
  then `a` lets the third delegation through unasked; `n` sends a typed word back, and `s`
  sends the next brief to `explore`; the draft's answer.
