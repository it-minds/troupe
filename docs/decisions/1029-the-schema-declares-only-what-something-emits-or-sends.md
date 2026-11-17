---
number: 1029
title: "The protocol schema declares only the events something writes and the methods some client sends; acl_*, session_read_only, session_archived, session_erased and fleet.get go, and so do four telemetry events nothing attached to"
date: 2026-11-17
status: accepted
issue: 1020
paths:
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - PROTOCOL.md
  - apps/troupe_worker/lib/troupe/worker/auth.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/lib/troupe/gateway/session.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/gui/packages/client/src/transcript.ts
gist: "No schema event without a writer, no method without a sender; access changes are session_invited/uninvited + acl.changed; session.list is the fleet"
---

Issue #1020. Five event types were declared and written by nothing, and the clients read
two of them; `fleet.get` was served and sent by no client; four `:telemetry` events had no
handler anywhere. Each was removed rather than wired, for its own reason:

- **`acl_granted` / `acl_revoked`.** An invitation and its withdrawal are already in the
  log as `session_invited` and `session_uninvited`, and the pod's mirror of the ACL is fed
  by the plane alone, which pushes `acl.changed` at each grant, invitation and invitation
  taken back. A grant by `session.grant` writes no line, as it wrote none before.
- **`session_read_only`.** The plane parks a session read-only in its own table, and a
  parked session has no tree running to write to its log. `state` on the session's row is
  where a client reads it, as it reads `dormant`.
- **`session_archived` / `session_erased`.** Archiving is a mark beside the log (Decision
  1023) and the answer to `session.archive` says so; an erased session has no log left to
  carry an event. Both also leave the gateway's list of lifecycle types.
- **`fleet.get`** answered the rows `session.list` with no filter answers, archived ones
  left out as there. The conformance client lists the fleet with `session.list` now. A
  `fleet` subscription stays: something subscribes to it.
- **`[:troupe, :llm, :start]`, `[:troupe, :llm, :stop]`, `[:troupe, :tool, :stop]`,
  `[:troupe, :agent, :transition]`.** The operator's guide said nothing attaches to them,
  and nothing did. `[:troupe, :llm, :retry]` (the live bench counts it) and
  `[:troupe, :llm, :unpriced]` stay. Decisions 769 and 788 mention `[:troupe, :llm, :stop]`
  firing for a summariser's and a stopped call; that part of each no longer holds.

The TUI read `version` from `config_upgraded` and `worker` or `pod` from
`session_resumed`, none of which the schema has; it reads `from`, `to` and `moved` now.

## Not chosen

- **Writing the events from where the schema implied.** Each would have been a second
  record of something already recorded once, and no client needed it.
- **Keeping `fleet.get` as an alias.** One way to ask for the list.

## If undone

An event declared again needs its writer in the same change and a test that it is
written; a method, a client that sends it.
