---
number: 22
title: Single-letter window hotkeys (`y`/`n`/`a`/`x`/`d`/`e`, Tab) apply only when the window's input buffer is empty
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: Single-letter window hotkeys (`y`/`n`/`a`/`x`/`d`/`e`, Tab) apply only when the window's input buffer is empty
---

Otherwise typing "yes" into a window would approve on the first keystroke; `y`/`n`/`a` also require a pending approval. Superseded in part by Decision 83 for `x` and `d`, which are the two that destroy something.
