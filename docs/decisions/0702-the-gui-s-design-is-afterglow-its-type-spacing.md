---
number: 702
title: "The GUI's design is Afterglow: its type, spacing and square corners in every theme, its palette as the default, and the three earlier palettes kept on the same contract"
date: 2026-09-26
status: accepted
issue: 52
paths:
  - apps/troupe_plane/lib/mix/tasks/troupe.theme.ex
  - apps/troupe_plane/lib/troupe/plane/web/page.ex
  - clients/gui/apps/desktop/src/theme.ts
  - clients/gui/docs/design/DESIGN.md
  - clients/gui/docs/design/themes/THEMES.md
  - docs/developer/architecture.md
  - docs/third-party-licences.md
  - scripts/licences.exs
gist: "The GUI's design is Afterglow: its type, spacing and square corners in every theme, its palette as the default, and the three earlier palettes kept…"
---

Issue #52, part 1 of 2: the tokens, the shell, the session list and
sign-in. The comp (`clients/gui/docs/design/afterglow.dc.html`) is a redesign, not a
palette: Figtree at black weights, DM Mono labels in capitals, the VT323 screen face
for a `// SECTION` label, radii of zero, a spacing scale of its own, a hard offset
shadow under tiles. The token pipeline already emitted structure once, from the
default theme's file, so the structure is now Afterglow's for every theme, and
`pnpm tokens` refuses a theme file whose copy of it differs.
- **Kept, not dropped.** Signal, Footlight and Limelight stay selectable. Whether
  they survive is a product question the issue does not settle, and the appearance
  screen, which is part 2, is where it would be answered; keeping them costs six
  colour names in three files and nothing in a component, and dropping one later
  is a file delete and a list entry.
- **The contract grew, once.** `text.body`, `text.label`, `bg.shadow`, `accent`,
  `status.running.solid` and `status.local` are what the comp needed and the
  contract lacked. Every theme answers them; the older three answer with values
  they already had (the link blue for `accent`, the stage for the shadow, the
  neutral of `queued` for `local`). Nothing was renamed, so every variable a
  component reads today still resolves, in every theme.
- **The reserved colour is also the brand, in Afterglow only.** Pink marks
  `waiting` and, through `--accent` and `--link`, the mask's lit half, links and
  the current nav item; the comp does this, and the rule that a component reaches
  for `--waiting-*` only for a waiting state holds. The other three keep their
  reserved colour for waiting alone.
- **Two values moved from the comp.** `text.muted`, the comp's grey-deep at 3.7:1
  on the void, is lifted to clear the 4.5:1 floor every theme is held to; and
  `queued` is grey rather than the comp's amber, because the list's idle sessions
  read as queued and three amber rows would fight the pink. The light mode is
  derived — the comp is dark only — by inverting the ground to cream and darkening
  every accent until it clears the same floor.
- **Generated, not typed.** `afterglow.tokens.json` carries both modes; the type
  roles are emitted as `--t-<role>` shorthands and the tracking as
  `--tracking-<role>`, so no size or weight is typed into the stylesheet.
- **Proof:** `pnpm tokens:check`, the GUI's typecheck, its test suites unchanged
  and passing, the desktop build, and the app against `pnpm fake` in a browser:
  the shell, the list and sign-in, light and dark, at 1280px and at 380px, on the
  pull request.
