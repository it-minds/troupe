---
number: 126
title: The TUI draws in Afterglow's palette, generated from the design tokens, at the depth the terminal can show, and its pink means a person is needed
date: 2026-09-27
status: accepted
issue: 228
paths:
  - clients/gui/docs/design/themes/afterglow.tokens.json
  - clients/tui/lib/mix/tasks/troupe.palette.ex
  - clients/tui/lib/troupe/ui/hq.ex
  - clients/tui/lib/troupe/ui/tui/palette.ex
  - clients/tui/lib/troupe/ui/tui/theme.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/test/troupe/tui_theme_test.exs
gist: The TUI draws in Afterglow's palette, generated from the design tokens, at the depth the terminal can show, and its pink means a person is needed
---

Issue #228,
root Decisions 702 and 716. Every colour was a literal in `view.ex` and `hq.ex`,
magenta on code and reasoning, yellow on what waited for you.
- **Roles, generated.** `mix troupe.palette` writes `Troupe.UI.TUI.Palette` from
  `afterglow.tokens.json`: fourteen roles, each a token with its dark and light
  values, the nearest of xterm's fixed 240 to each (CIELAB, never 0 to 15, which
  are the person's theme) and a stand-in among the sixteen. An alpha token is laid
  over `bg.canvas`. `--check` is in `mix check`. The view names roles, never
  colours, and `Theme.paint/2` resolves them once per frame.
- **Depth from the terminal.** Truecolor under `COLORTERM=truecolor|24bit` or in
  Windows Terminal (`WT_SESSION`, which sets no `COLORTERM`), 256 from a `TERM`
  that says so, otherwise the sixteen; none under `NO_COLOR` or `TERM=dumb`. The
  light values when `COLORFGBG` reports a light background. `TROUPE_COLORS`
  (`truecolor`, `256`, `16`, `none`, and `light` or `dark`) overrides all of it; an
  environment variable rather than a setting, since the setting belongs with the
  theme choice (#57) and this is about the terminal, not the person's taste.
- **The canvas is not painted.** Text outside a role keeps the terminal's ink, and a
  background never comes from anything but a role: the code highlighter's
  backgrounds are dropped, and its colours become their nearest of 256 at 256 and
  the terminal's ink with the sixteen.
- **Pink is for being needed.** `:needs_you` goes on the pending line and a ticked
  option, "waiting for you", the border and title of a window that waits on you,
  the status line's count and how to answer, and the rows in the observer, the
  session picker and HQ that wait on you; `:brand` on the mask's lit half. Magenta
  in the sixteen goes to those three roles and nothing else, and a test reads every
  tag `model.ex` draws and holds all but those to other roles. Code and headings
  take the accent (the focus cyan), reasoning goes muted.
- **A window waits on you when something in it is pending.** No daemon sends the
  `branch_state` that used to set `needs_input`, so the strip, the status line's
  count and hint read `pending` instead; the needs-you border blinks once a second,
  off the clock rather than the tick.
- **The mask, in half-blocks.** Rasterised by the task from `mark.path` and the
  eyes at two cuts, light from the right, the eye on the lit half cut out; drawn
  in the middle of a session's window until its first line, over the empty strip,
  and beside HQ's lists. With no colour the lit half is solid ink against the
  hollow one.
- **Not in this slice:** the theme picker and the other three themes (#57, #122),
  the ◐ glyph family in each window's corner and as the spinner, a `blink` setting,
  and painting the canvas on request.
- **Proof:** `test/troupe/tui_theme_test.exs` (the palette against the tokens,
  detection and each depth, the pink's tags, an approval drawn at truecolor, 256,
  16 and none, the light values, the mask's rules, the fresh window, HQ), `mix
  check`, and the installed build's screens at each depth, headless and in Windows
  Terminal, on the pull request.
