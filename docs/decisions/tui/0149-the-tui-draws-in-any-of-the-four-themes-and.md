---
number: 149
title: The TUI draws in any of the four themes, generated from every theme's tokens and chosen by `ui.theme` without a restart, and each window's corner carries the mark — ◐ ◓ ◑ ◒ turning while its agent works, ◑ in the reserved colour while it needs a person, ⏺ done and unread
date: 2026-10-07
status: accepted
issue: 228
supersedes: [136]
paths:
  - clients/tui/lib/mix/tasks/troupe.palette.ex
  - clients/tui/lib/troupe/settings.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/ui/tui/palette.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/theme.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/test/troupe/shared_settings_test.exs
  - clients/tui/test/troupe/tui_theme_test.exs
symbols:
  - Troupe.UI.TUI.Theme.choose/2
  - Troupe.UI.TUI.View.mark/2
  - Troupe.UI.TUI.Model.spinner/1
gist: Every theme generated; no role but the reserved three takes the reserved colour at any depth; the theme is ui.theme, live; ◐◓◑◒ / ◑ / ⏺ in each window's corner
---

Issue #228's rest, on what Decision 126 built: Afterglow's palette by role, at the
depth the terminal can show, with its pink kept for a person being needed. 126 left out
the theme picker, the other three themes, the ◐ family and a `blink` setting; this is
those. Root Decision 807 is the shared setting. This is the part of 136 it supersedes:
the settings page now shows two of the `ui` keys.

- **Four themes, one module.** `mix troupe.palette` reads every
  `clients/gui/docs/design/themes/*.tokens.json` and writes them into
  `Troupe.UI.TUI.Palette`, in the order the desktop app offers them (`theme.ts`),
  Afterglow first as the default: `themes/0` (id, name, description, the reserved
  colour's word), `roles/1` per theme, `mask/1` once. One module rather than one per
  theme, because a role's lookup is then one map and a theme file added there is a
  theme here at the next run; `--check` fails CI on drift, as before. The mark is one in
  every theme file, so the task refuses a theme whose mark differs instead of drawing it
  four times.
- **The reserved colour stays reserved in every theme, at every depth.** The roles are
  the same in all four and each theme keeps its own reserved colour for them (Signal's
  magenta, Footlight's amber, Limelight's lime). Two things in the tokens would have
  broken that, and the generator now steers round both. Limelight's focus ring is its lime,
  and the TUI's accent (126's "focus cyan") is on every heading, so a role may name a
  second token for where its first is the reserved colour: the accent there is
  `text.link`, the link blue, which is what Limelight's own `accent` token is. And two
  near colours can share their nearest of 256 — Limelight light's `ok` and its reserved
  colour did — so a role that is not reserved never takes the reserved colour's index and
  takes its next nearest instead. With sixteen colours the stand-ins are the same in every
  theme, magenta for the reserved three: the terminal's own theme decides what the
  sixteen look like, so a stand-in names the role, not a theme's hue. Not chosen:
  Footlight's amber as yellow at sixteen, which takes the plane-offline yellow and gains
  nothing the terminal's palette does not override.
- **Chosen by `ui.theme`, live.** The server reads `config.get` as it mounts and again on
  every `config.changed` that names a `ui` key, so a theme picked in the desktop app is
  drawn here with nothing pressed, and one picked on the settings page at once. A value
  it does not know is drawn as Afterglow and said once, in the status line, per value. A
  session on a plane has no settings door (`Client.settings/1` answers it with an error),
  so it draws in Afterglow for now. Light or dark stays the terminal's (807).
- **The settings page** shows `theme` as a menu of the four, its cursor on the one in
  use and no "type one instead", since a theme is one of them or none; and `blink` as a
  toggle. Both apply immediately.
- **The mark, per #228's table: fill is what the agent did alone, hollow is what waits on
  you.** In the top right corner of every window's border, a right-aligned title three
  cells wide that the left title is fitted around (`View.mark/2`). ◐ ◓ ◑ ◒ in `:working`
  while its agent works, a quarter turn every 250 ms off the clock rather than the frame
  rate (`Model.spinner/1`), and the activity line turns the same glyph in place of the
  braille spinner, so the two turn together. ◑ — the lit right half, the mark itself — in
  `:needs_you` while it needs a person, blinking with its border, `:rail` in the dark half
  of the beat. ⏺ in `:ok`, written with the text-presentation selector (U+FE0E) so it
  keeps one cell, when done and not yet read; ○ muted once read; ✗ in `:error`, muted
  once read. `combining?/1` counts U+FE0E as no cell. A narrow title no longer carries a
  glyph of its own (the old ▶ ✓ ✗ and spinner): the corner is that glyph, and the
  word stays in the title wherever it fits, so status is never the colour alone.
- **Blinking is drawn, not asked of the terminal.** The SGR blink attribute is ignored or
  drawn differently by many terminals, so the TUI draws the mark and the border lit and
  unlit off its clock, which works in any of them; `ui.blink: false` holds them lit.
  Terminals do not report reduced motion, so the setting is the switch.
- **Not in this slice:** painting the canvas (126's opt-in), still not built; glyph
  fallbacks for a font without the Geometric Shapes (#228's ⏺ → ● → *), since nothing
  measures the font; "follow my terminal", a fifth theme of only the sixteen
  (`TROUPE_COLORS=16` draws that today); the mark in the status line, and the observer's
  blinking "▶ you".
- **Proof:** `test/troupe/tui_theme_test.exs` — every theme at truecolor, 256, 16 and no
  colour, light and dark (the reserved colour on what waits on you and nowhere below the
  window's tile, the accent and the diff in the theme's own, ◑ in the corner), the
  palette against all four tokens files, no other role on the reserved colour at
  truecolor or 256, the corner turning ◐ ◓ ◑ ◒ with the activity line, ◑ blinking and
  steady with blinking off, ⏺ in one cell, ○ read, ✗ failed, and with no colour the
  glyph and the word still there; `settings_test.exs`; `shared_settings_test.exs` (a
  theme the desktop app sets drawn by the running TUI, one picked on its page reaching
  the desktop app, an unknown one said once). The reproductions — Footlight drawn in
  Afterglow's pink, a working window with no ◐, the running TUI not following the
  desktop app's `ui.theme` — failed on the chunk's tip. `mix check`; and the installed
  TUI in Windows Terminal on scratch homes with the fake provider, in Footlight and in
  Limelight, its window working (◐ turning in the corner and the activity line) and then
  waiting on a question (◑ in the theme's reserved colour, blinking with the border).
