---
number: 807
title: "`ui.theme` is the theme both clients draw in and `ui.blink` whether what waits on a person blinks: the terminal UI acts on both, the daemon on neither, and a theme a client does not know is drawn as Afterglow"
date: 2026-10-07
status: accepted
issue: 228
supersedes: [761]
paths:
  - apps/troupe_core/lib/troupe/config/schema.ex
  - clients/tui/lib/troupe/settings.ex
  - protocol/schema/config/v1.json
gist: "ui.theme is both clients' theme and ui.blink the TUI's blinking; an unknown theme draws as afterglow, not refused; ui.mode stays the desktop's"
---

Issue #228's rest: "pick Afterglow once, get it in both clients". Decision 761 put a
`ui` section in `config.yaml` for what follows a person from one client to the other
and called its three keys the desktop app's; the terminal UI's settings table was the
schema's less the `ui` keys. This is the part of 761 it supersedes: the terminal UI
draws in the theme `ui.theme` names too, and the page that sets it shows it (TUI
Decision 149).

- **One key, two clients.** `ui.theme` was the desktop app's palette; it is now the
  palette both draw in, with the same four values (`afterglow`, `signal`, `footlight`,
  `limelight`), the same default, and the same rule for a value a client does not know:
  it reads as `afterglow`. The schema keeps it a string, not an enum, so a newer client's
  theme in the file is not something an older daemon refuses, which is why 761 chose a
  string; the terminal UI says once that it does not know the value, rather than nothing.
  Not chosen: a terminal key of its own (`tui.theme`), which is two settings for one
  choice and the drift #228 is about.
- **`ui.blink` is new**, a boolean, on by default: whether what waits on a person blinks.
  The terminal UI's needs-you mark and border are the one thing on its screen that
  blinks (TUI Decision 126), and a permanently flashing cell is an accessibility problem
  over a long run, as the issue says. In `ui` rather than at the top level beside `mouse`,
  because it is about the person, not this terminal: a desktop app that blinks one day
  reads the same key. The desktop app acts on it not at all today.
- **`ui.mode` and `ui.notifications` stay the desktop app's.** A terminal's light or dark
  is its background, which the terminal reports (`COLORFGBG`) or `TROUPE_COLORS` says;
  a window's mode chosen in the desktop app says nothing about it.
- **The daemon still acts on none of them**, as 761 has it: it keeps them, serves them in
  `config.get` and names them in `config.changed`, which is how the terminal UI hears a
  theme picked in the desktop app and redraws without a restart.
- **Proof:** `Troupe.Config.SettingsTest`, `Troupe.Config.ExplainTest`,
  `Troupe.Gateway.SharedSettingsTest` and `ModelSettingsTest` unchanged and passing with
  the new key; `mix troupe.config.schema --check`; the terminal UI's
  `Troupe.SharedSettingsTest` (a theme the desktop app sets is the one the running
  terminal draws, failing on the chunk's tip; one picked on the terminal's page reaches
  the desktop app's `config.get`; an unknown one drawn as Afterglow and said once).
