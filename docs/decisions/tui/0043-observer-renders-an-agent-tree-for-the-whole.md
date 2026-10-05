---
number: 43
title: "`/observer` renders an agent tree for the whole session from the TUI model, and the model now folds per-agent facts (definition name, model, tokens, start and end) alongside the per-window ones"
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: "`/observer` renders an agent tree for the whole session from the TUI model, and the model now folds per-agent facts (definition name, model…"
---

The hierarchy is already in the agent paths (`code-1/explore-1`), so the tree is a sort over each window's `agents` map rather than new state; a pending approval or question outranks every other status because that agent is the one holding you up. Enter opens the selected agent's branch window, since transcripts live there and the observer stays read-only.
