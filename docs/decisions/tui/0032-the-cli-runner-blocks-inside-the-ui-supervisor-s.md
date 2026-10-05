---
number: 32
title: The CLI runner blocks inside the UI supervisor's `start_link/1` and halts the VM when the UI exits
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: The CLI runner blocks inside the UI supervisor's `start_link/1` and halts the VM when the UI exits
---

Under Burrito the release boots with `start_cli`, which halts the node as soon as application start returns (documented by ExRatatui); blocking keeps the VM alive for the TUI's lifetime while the TUI itself stays supervised under `Troupe.UI.Windows` so a crash is a restart and redraw, not an exit.
