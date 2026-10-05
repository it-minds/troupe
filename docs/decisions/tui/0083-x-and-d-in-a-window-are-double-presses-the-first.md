---
number: 83
title: "`x` and `d` in a window are double presses: the first types the letter and arms, the second acts, and any other key disarms and keeps the letter as text"
date: 2026-09-16
status: accepted
supersedes: [22]
paths:
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
gist: "`x` and `d` in a window are double presses: the first types the letter and arms, the second acts, and any other key disarms and keeps the letter as…"
---

Decision 22 made the single-letter hotkeys conditional on an empty input box, which is exactly the case that bites — the box *is* empty when you start typing a reply, so an answer beginning "do it", "don't", "drop that" or "x the second one" cancelled the branch or dismissed the window on its first keystroke, with nothing to undo it (`x` also discards the branch's worktree). The rest of the hotkeys can stay single: `y`/`n`/`a` need a pending approval and are recoverable, `e` only toggles output, Tab switches a profile. These two destroy something, so they get the shape Ctrl-C already has here — arm, then confirm. The arming is `{agent_path, code}` in `TUI.Server` state, never a fold over the log: it is a keystroke, not a decision, so a restart must come back unarmed, and it is scoped to the window because activating another one clears it. `disarm/2` runs before `window_key/3` on every key event, so the confirm has to be the *very next* keystroke; that also means the first press leaves the letter in `win_text`, and the armed clauses therefore match on `win_armed` rather than on an empty box (the `win_text: ""` clauses below them no longer apply). The input box's title says which press is outstanding and that typing on is safe, and the pane's hint line reads `xx`/`dd` when idle and "x again cancels & removes" when armed, because a key that needs two presses has to say so where the reader is already looking.
