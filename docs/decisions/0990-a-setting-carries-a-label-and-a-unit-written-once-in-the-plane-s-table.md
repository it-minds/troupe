---
number: 990
title: "A platform setting carries a label and a unit, written once in the plane's settings table; the console names the row by the label and asks for the value in the unit"
date: 2026-11-15
status: accepted
issue: 933
paths:
  - apps/troupe_plane/lib/troupe/plane/settings.ex
  - apps/troupe_plane/lib/troupe/plane/settings/setting.ex
  - apps/troupe_plane/lib/troupe/plane/settings/ladder.ex
  - apps/troupe_plane/test/troupe/plane/settings_test.exs
  - clients/gui/packages/client/src/admin.ts
  - clients/gui/packages/client/test/support/admin.ts
  - clients/gui/apps/console/src/views/settingUnits.tsx
  - clients/gui/apps/console/src/views/Policy.tsx
  - clients/gui/apps/console/src/views/Organisation.tsx
  - clients/gui/apps/console/test/policy.test.tsx
  - clients/gui/apps/console/test/organisation.test.tsx
  - docs/admin/console.md
  - PROTOCOL.md
symbols:
  - Troupe.Plane.Settings.naming/1
  - Troupe.Plane.Settings.Setting.units/0
gist: "Each setting in settings.ex has label + unit (days, minutes, seconds, dollars, bytes, count, switch, text, choice with choices, url); settings.list and setting.effective carry them; the value on the wire stays the plane's (micros, seconds); a plane without label falls back to the key"
---

The console's Policy and Organisation pages headed every setting with its key
(`platform_budget_micros`) and asked for money in millionths and time in seconds, while
Budgets and a team's Limits already spoke dollars and minutes. `admin.settings.list`
carried the key, the value and two sentences, and nothing else a surface could name a row
or pick a control from.

- **The plane's table is the one place.** Each `%Setting{}` in `Troupe.Plane.Settings`
  has a `label`, the reader's name for it as a short noun phrase ("Erase a session
  after"), and a `unit`: `days`, `minutes`, `seconds`, `dollars`, `bytes`, `count`,
  `switch`, `text`, `url`, or `choice` with `choices`, each value with the words it is
  picked by. The settings test refuses a setting with no label or a unit outside that
  list, and holds the obvious pairs: a `*_micros` key is in dollars, a `*_seconds` key in
  minutes or seconds, a `*_days` key in days, a boolean is a switch, an enum is a choice
  whose choices are exactly its values.
- **The unit is how a person reads it, not how it is kept.** A `dollars` value is still
  millionths of a dollar and a `minutes` one still seconds, in every answer and in what
  `admin.setting.put` takes; a surface converts both ways. Changing the wire would have
  broken every caller over MCP and every older console for a change of words.
- **Both answers that name a setting carry it.** `admin.settings.list` on each row, and
  `admin.setting.effective` (so a team's `effective` too) through `Settings.naming/1`, so
  the ladder's rows say the same words as the settings they are about.
- **The console asks in the unit.** The label heads the row and the key is its mono line
  beneath; the value is shown in the unit (`$500.00`, `30 min`, `180 days`, `on`, a
  choice's words); the field is the unit's control, a dollars or minutes field that
  converts on save, a select for a switch or a choice, with the unit and the setting's
  consequence as its hint; the preview's diff and the audit note name the setting by its
  label and say each value in the unit ("Budget for the platform: $500.00 → $750.00").
  The audit row itself keeps the plane's values: it is a record, not a page.
- **A plane from before it** answers no label: the row is named by its key and the field
  is what it was, a switch for a boolean, a select for an enum, text otherwise.

`troupe config pull` prints the client configuration's own keys (`llm.provider`), not
the plane's settings, and is left as it is. The Audit page shows a setting's row as the
audit recorded it, in the plane's values.
