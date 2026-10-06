---
number: 46
title: "The TUI model keeps full tool results (was a 300-character slice, now capped at 200k characters) and the approval preview on the tool call itself, sanitised once at fold time: tabs expanded to 4-column stops, ANSI escape sequences and control bytes dropped"
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: The TUI model keeps full tool results (was a 300-character slice, now capped at 200k characters) and the approval preview on the tool call itself…
---

Collapsed tool lines carry the outcome (`· 300 lines`, `· +3 -1` for an edit whose diff was shown — with `auto_approve` or after `a` there is no approval and so no diff, and the head shows the result instead, `· exit 1 (12 lines)` for a failure, or a one-line result verbatim), and whatever the window waits on (approval with its diff, question) is rendered at the end of the scrollable transcript rather than only in the side panel, so a diff can be read at any width. Both are folds over persisted events (`tool_call_completed.content`, `approval_requested.preview`): no event or shape changes, and the rebuild from the log is unchanged.
