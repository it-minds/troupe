---
number: 1091
title: "A pod session's visibility changes after it started by its owner alone, through `session.visibility.set` and the log's `session_visibility_changed`; invitations stay, a person invited and on the team holds the stronger role, and the team's steering rule applies while it is the team's"
date: 2026-11-22
status: accepted
issue: 1169
paths:
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/sessions.ex
  - apps/troupe_worker/lib/troupe/worker/plane/commands.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/gui/packages/client/src/visibility.ts
  - clients/gui/apps/desktop/src/views/Session.tsx
  - clients/tui/lib/troupe/client/share.ex
symbols:
  - Troupe.Plane.Sessions.set_visibility/2
  - Troupe.Plane.Sessions.role_for/2
gist: "session.visibility.set {team|private}: owner only (admins too forbidden), audited, answers the row; pod pushed acl.changed per member then visibility.changed, which logs session_visibility_changed; ACL kept, role = max(ACL, team)"
---

Issue #1169. A pod session's `visibility` was fixed at `session.create`.

**One method, the owner's.** `session.visibility.set {session_id, visibility}`, `team` or
`private`, `control` scope. The owner alone (`owner_subject`, not an ACL `owner` row):
anybody else who may see the session, a platform administrator included, is `forbidden`
with `required_role: "owner"`; Decision 1049's oversight reads and does not change. To
anybody who may not see it, `not_found` (Decision 87). A private session is `conflict` (it is
sealed on its owner's machine), so is one with no team to give it to; an erased one is
`not_found`; asking for what it already is writes nothing. A change is one audit row
(`session.visibility.set`, `from`, `to`) and answers the row as `session.get` does, which
now names its team (`team`) so a client can say whom it is given to.

**The log hears it through the pod.** The plane never writes a session's log, so it pushes
`visibility.changed {session_id, visibility, by, by_name}` to the pod holding it, as
`invite.changed` is, and the pod writes `session_visibility_changed`. Before that, one
`acl.changed` carries every team member's role now (`null` for none), so a connection open
on the pod meets the change at its next command, as a revoked invitation does (949). Best
effort: a dormant session has no pod and no line, and its row is the record.

**Invitations stay; the stronger role holds.** ACL rows are untouched. `role_for/2` was the
ACL row's role when there was one and the team's only failing it; it is now the stronger of
the two, so a member invited to follow a session given to a team that lets members steer
steers it, and keeps following once it is taken back.

## Not chosen

- An administrator changing it: whose a session is is its owner's word.
- Writing the line from the plane: it holds no session key, and a second writer of a log
  breaks its chain.
- A migration: the column was always there.

## If undone

A session started for one person stays so, and the team is let in by name only. Without the
`acl.changed` push, a member keeps steering a taken-back session on an open connection until
their token ends.
