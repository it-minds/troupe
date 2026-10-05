---
number: 75
title: Remote events are translated into the harness's own event types at the edge, and only five new types were added
date: 2026-09-16
status: accepted
paths:
  - clients/tui/lib/troupe/remote/translate.ex
gist: Remote events are translated into the harness's own event types at the edge, and only five new types were added
---

`Troupe.Remote.Translate` maps `message.completed` to `:assistant_message`, `tool.completed` to `:tool_call_completed`, `approval.*` to the approval events, and so on, so the TUI model folds a remote session with the same code it folds a local one. The five that had no local equivalent are `:tool_started` (a local tool call is announced by the assistant message that asked for it), `:remote_note` (`session.resumed`, `config.upgraded`, `acl.*`, `session.tainted` — transcript lines), `:remote_status` (session state, scopes and connection health), `:input_accepted` (the optimistic-input reconcile) and `:fs_changed` (the files panel's staleness signal). An unknown type is logged once and rendered generically.
