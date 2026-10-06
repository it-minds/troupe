---
number: 45
title: "The activated pane scrolls (PgUp/PgDn, Home/End, ↑/↓ while nothing is typed, the mouse wheel), follows the tail by default and stays put once scrolled up; the transcript is wrapped in Elixir and handed to ratatui as pre-wrapped lines with `wrap: false`, only the rows in view"
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: The activated pane scrolls (PgUp/PgDn, Home/End, ↑/↓ while nothing is typed, the mouse wheel), follows the tail by default and stays put once…
---

ratatui's `Wrap{trim: true}` strips leading whitespace from every row and drops tabs, which destroyed code indentation, and taking a tail in logical lines then wrapping clipped the newest rows off the bottom. Row heights are counted with a byte-size fast path so a 200k-character result costs microseconds per frame; the scroll position is Server state (not in the model), so a TUI restart comes back following the tail. Expanding or collapsing tool output (`e`) keeps the entry at the top of the view in place instead of jumping to the bottom.
