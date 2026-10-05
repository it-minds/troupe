---
number: 48
title: With a pane open the window strip becomes a tray of at most 8 rows (4 on a 24-row terminal), the side panel is `clamp(width/4, 30, 60)` columns and disappears below 100 columns, and clicking the tile of the already-activated window jumps back to following the tail rather than toggling the pane
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: With a pane open the window strip becomes a tray of at most 8 rows (4 on a 24-row terminal), the side panel is `clamp(width/4, 30, 60)` columns and…
---

The pane title keeps `<path> (<profile>) — Esc back` (a subagent view reads `<path> › <sub> (<name>)`), the scroll position sits in the top-right title and the applicable keys on the bottom border, trimmed to the width.
