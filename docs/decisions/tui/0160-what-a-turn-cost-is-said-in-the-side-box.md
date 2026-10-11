---
number: 160
title: "What a turn cost is said in the side box, `This turn` above `Session`, and wherever the side box is drawn the window's transcript leaves out the turn's line, which a screen below 100 columns keeps"
date: 2026-10-11
status: accepted
issue: 578
supersedes: [139]
paths:
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/test/troupe/side_box_cost_test.exs
  - clients/tui/README.md
symbols:
  - Troupe.UI.TUI.Model.turn_box/2
  - Troupe.UI.TUI.Model.session_box/2
  - Troupe.UI.TUI.Model.without_turn_lines/1
gist: "At 100+ columns the side box says the window's last turn and the session, and its pane and tile drop the turn line; the fold keeps it for narrower screens"
---

Issue #578. Decision 139 put what a turn cost in one line under the turn, and the side box
beside the transcript, whose title promises tokens, said less than that line: the window's
tokens and nothing of calls or money. One fact now has one place: the side box, where the
screen has one. This replaces Decision 139's "under the turn" for a screen of 100 columns
and wider; below that, and for everything else 139 says, it stands.

- **The side box.** Two groups where `Tokens:` was:

  ```
  This turn:
    9 calls · $0.14
    ↑ 208.9k sent · 0 cached
    ↓ 3.5k received
  Session:
    41 calls · $0.61
    ↑ 1.2M sent · 310.0k cached
    ↓ 19.0k received
    ⚠ 82% of input tokens
  ```

  `This turn` is the window's `last_turn`: the `turn` map on the event that ends its own
  agent's turn (root Decision 769), its subagents' calls included, kept instead of dropped
  once the line is written. Whatever starts the next turn clears it (`working/1`: an input,
  a loop's, a live working state), so while a turn runs the group says `said when it ends`
  and never a running count, as 139 has it; before any turn has ended, or after one that
  made no call, it says `(none)`. `Session` is the window's ended turns' calls and money
  (its `cost`, from the first turn's end), its tokens in the turn's words, and the headroom
  warning under them, where the limit is. Its tokens count each reply as it lands and its
  calls and money each turn as it ends, as the status line's do.
- **The words are the line's.** `↑` is input billed in full plus cache writes, `cached` the
  provider's cache reads, there at nothing too, `↓` what came back, and the money is
  `money/1`'s, `no price` and `, n calls unpriced` included. The side box's old
  `⟳ … from cache` line went with `token_lines/1`.
- **Width.** The side box is 30 to 60 columns (Decision 48). Two figures share a line where
  the room (inside the borders, less the two-column indent) holds both, and each takes its
  own where it does not, so at 30 columns `↑ 1.2M sent · 310.0k cached` is two lines
  rather than one wrapped mid-figure.
- **The transcript.** The fold still writes `{:system, turn_line(turn)}` under the turn:
  the narrow screen reads it there, and so does every test written for 139. The view
  leaves it out of the window's own agent's transcript wherever the side box is drawn, the
  pane at 100 columns and wider and the window's tile in the tray above it, with
  `Model.without_turn_lines/1`, which knows the line by its own words (nothing else in a
  transcript starts with `turn: `). The pane's geometry does it, so scrolling, selecting
  and copying work on what is drawn. A subagent's line says what its own task cost, which
  the side box does not, and stays in that subagent's transcript.
- **Not changed.** `turn_line/1`'s string, the headless printer's line (Decision 144) and
  the desktop app's (`@troupe/client`'s `turnLine`, root Decision 782), so the three still
  agree to the cent.
- **Not done.** A `{:turn, map}` transcript entry drawn by width would not need the line's
  words to find it, but every test of the line reads the fold's `{:system, …}` entry, and
  the issue keeps them as they are. `This turn` following the agent viewed with ←→ would
  move a subagent's line too; the issue keeps the group the window's.
- **Proof:** `test/troupe/side_box_cost_test.exs`: the two groups after a turn and no line
  on screen at 120 columns; the line and no side box at 99; the line back at 90 and gone
  again at 120, drawn by one process; `said when it ends` while the next turn runs, and its
  figures once it ends; `(none)` before any; `no price` and an unpriced call; the warning
  under `Session`; the figures one to a line at 30 columns and side by side at 60; every
  line within its room from 26 to 56 columns; the window's lines left out and a subagent's
  kept. Eight of the first nine failed on the chunk's tip, the narrow one passing there as
  it should. `turn_cost_test.exs` and `cli_test.exs` pass unchanged.
