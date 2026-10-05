---
number: 139
title: "What a turn cost is one line under it when it ends: its calls, `↑` sent, cached, `↓` received and the money, apart from the window's count, which is the session's"
date: 2026-10-04
status: accepted
issue: 389
paths:
  - clients/tui/lib/troupe/ui/headless/printer.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/test/troupe/cli_test.exs
  - clients/tui/test/troupe/turn_cost_test.exs
gist: "What a turn cost is one line under it when it ends: its calls, `↑` sent, cached, `↓` received and the money, apart from the window's count, which…"
---

Issue
#389, slice 4, root Decision 769. `↑ sent` on a tile and in the side panel is
cumulative, and that is how "every turn costs 9M" was read: nothing said what one turn
had cost. The event that ends a turn carries `turn` (769), `Troupe.Remote.Translate`
hands it on with the `agent_state` it already makes of `turn_ended`, `cancelled` and
`agent_done`, and the model writes
`turn: 3 calls · ↑ 300 sent · 3.0k cached · ↓ 3 received · $0.04` into that agent's
transcript, a system line as a cancel's is.
- **Under the turn, not in the status line.** The status line is the session's and
  the windows'; a turn's figure there is one more number that moves, and nothing is to
  stream while the turn runs. The transcript is where the turn is, the line stays under
  it so scrolling back reads each turn's cost, and the tile's tail shows it as the turn
  ends. A live `agent_state` carries no `turn`, so nothing is said before the end.
- **The words.** `↑ sent` is input billed in full, as the window's own count reads it,
  so the two compare. `cached` is there even at nothing, because `0 cached` answers
  whether the provider's cache is being used at all. The money is dollars to the cent,
  `under a cent` below one as the budget question says it, `no price` when no call was
  priced, and `, 2 calls unpriced` after the sum when some were not.
- **Nothing** for a turn that made no call, and nothing from a log written before turns
  were counted.
- **The summariser's call is the session's too.** A `compacted` that says what the
  call that wrote its summary used (769) is translated into a `:call_usage` beside its
  note, and the window and its agent add it to their counts as they add a reply's, so a
  turn's line that counts that call is never more than the session's count above it.
- **Proof:** `test/troupe/turn_cost_test.exs` (a turn's line; a second turn's line with
  the session's count beside it; nothing while a turn runs; a cancel and a finish; an
  unpriced turn and a partly priced one; a compaction's call in the session's count; an
  old log), four of the six first written failing on the chunk's tip.
