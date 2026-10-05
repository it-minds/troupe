---
number: 144
title: A headless run prints what each turn cost when it ends, the window's line, and the line's figures are worked out in whole numbers, a million as `M`
date: 2026-10-05
status: accepted
issue: 389
paths:
  - clients/tui/lib/troupe/ui/headless/printer.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
gist: A headless run prints what each turn cost when it ends, the window's line, and the line's figures are worked out in whole numbers, a million as `M`
---

Issue #389, root
Decision 782. `Troupe.UI.Headless.Printer` prints `Model.turn_line/1` of the `turn` a
durable `agent_state` carries (139), prefixed with its agent like every other line:
after the turn's reply, before `exit N:`, once whether read live or back from the
journal, and nothing for a turn that made no call. It goes to standard output with the
transcript; the printer has no `--json`. `short/1` and `dollars/1` round half up in
integers, as `@troupe/client`'s `turnLine` does, so the desktop app says the same to
the cent, and a count past a million is `6.0M`, where `Float.round/2` printed
`6.0e3k`; the tile and the side panel count that way too. Proof:
`test/troupe/cli_test.exs` ("prints what a turn cost when it ends", "prints each
ended turn's line in the window's words"), both failing on the chunk's tip.
