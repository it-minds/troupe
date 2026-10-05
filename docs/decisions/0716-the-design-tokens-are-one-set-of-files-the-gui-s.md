---
number: 716
title: The design tokens are one set of files, the GUI's; the plane's front page and the TUI are generated from them, and the front page stays in Signal
date: 2026-09-27
status: accepted
issue: 228
paths:
  - .github/workflows/ci.yml
  - apps/troupe_plane/lib/mix/tasks/troupe.theme.ex
  - apps/troupe_plane/lib/troupe/plane/web/page.ex
  - docs/developer/architecture.md
  - docs/developer/build.md
gist: The design tokens are one set of files, the GUI's; the plane's front page and the TUI are generated from them, and the front page stays in Signal
---

Issue #228,
defect D30. `docs/design/themes/` was a copy of `clients/gui/docs/design/themes/`
from before Afterglow: three themes on the old structure, with the kits and
`support.js` byte for byte the same. It is gone, and `mix troupe.theme` reads the
GUI's directory.
- **One copy rather than a checked one.** The GUI's image builds with `clients/gui`
  as its only context, so the files stay where `pnpm tokens` finds them; nothing
  else needs them anywhere else, since the plane's image copies no `docs/` and
  `theme.css` is committed. A generated copy with a check that fails on drift would
  have worked too; a file that exists once cannot drift at all.
- **The front page keeps Signal's colours and takes the shared structure.**
  Graphite, cyan for the machine, magenta on the mask and the approval figure and
  nowhere else. Afterglow spends its pink on links and the accent (702), which is
  exactly what the front page's rule and `front_page_assets_test.exs` forbid, so
  moving it to Afterglow is a change to that rule and not to this file; the one
  line is `@default_theme`. What changes is what every theme has carried since 702:
  Figtree and DM Mono (the page's webfont link follows), black-weight headings,
  square corners, Afterglow's spacing.
- **Three generators, three checks.** `pnpm tokens:check` (the GUI), `mix
  troupe.theme --check` (the front page) and `mix troupe.palette --check` in
  `clients/tui` (TUI Decision 126), and CI's path filters send a change to the
  themes directory to all three.
- **Proof:** the three checks and `mix troupe.admin.tokens --check`;
  `front_page_assets_test.exs` and `console_assets_test.exs`; `/` and `/docs`
  before and after, at 1280px and 380px, on the pull request.
