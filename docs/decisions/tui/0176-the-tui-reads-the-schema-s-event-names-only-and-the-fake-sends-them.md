---
number: 176
title: The TUI reads a remote session's events in the worker's envelope and under the protocol schema's names only, and its fake sends what the worker sends (this supersedes Decision 98)
date: 2026-11-17
status: accepted
issue: 1019
supersedes: [98]
paths:
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/lib/troupe/remote/worker.ex
  - clients/tui/test/support/fake_remote.ex
gist: "Events only under the schema's names (llm_response, tool_call_started, ...) in the worker's envelope; no dotted spellings; the fake sends the worker's"
---

A remote session's events arrive in the worker's envelope (`{"topic", "session_id",
"event"}`, an ephemeral marked `"ephemeral": true` inside), which `Troupe.Remote.Worker`
unwraps, and `Troupe.Remote.Translate` reads them under the names
`apps/troupe_protocol/lib/troupe/protocol/schema.ex` gives and no others. `FakeRemote`
sends those names too, and an `llm_response` with a message's content blocks
(`FakeRemote.said/1`), not a `text` field.

Decision 98 also read a dotted spelling of each name (`message.completed`, `tool.started`,
`fs.changed` and fifteen more) because the fake and its fixtures used them as the contract's
example. Neither PROTOCOL.md nor any server under `apps/` sends or names them, so they only
proved the fake against itself. Not chosen: keeping both spellings, which leaves a
second vocabulary in eighteen match clauses that no plane, worker or daemon has ever used.

Undoing it would let the fake drift from the worker again: a test can pass on a name the
live plane never sends, which is how the stream once stayed empty against it.
