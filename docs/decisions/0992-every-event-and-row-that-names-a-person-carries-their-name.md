---
number: 992
title: "Every event and row that names a person carries their name beside the subject: an event's actor its display_name from the connection (the plane's token on a pod, the link or the OS user on a laptop), session_created its owner_name, the plane's session and audit rows owner_name and actor_name filled from the identity record by one helper; a name that is only the subject is no name; the clients draw initials and the name and fall back to the subject"
date: 2026-11-15
status: accepted
issue: 931
supersedes: []
paths:
  - apps/troupe_plane/lib/troupe/plane/names.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/gui/packages/client/src/people.ts
  - clients/gui/packages/client/src/transcript.ts
  - clients/gui/packages/client/src/fleet.ts
  - clients/gui/apps/desktop/src/views/Session.tsx
  - clients/gui/apps/console/src/views/Sessions.tsx
  - clients/gui/apps/console/src/views/Audit.tsx
  - clients/gui/apps/console/src/views/Remote.tsx
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
symbols:
  - Troupe.Plane.Names.of/1
  - Troupe.Plane.Names.decorate/2
  - nameOrSubject
  - initials
gist: "display_name beside every subject: actor from the connection, owner_name/actor_name on plane rows via Names.decorate; subject-again is no name; clients draw initials + name, fall back to subject"
---

Issue #931. The transcript and the console showed people by subject or email: the
desktop drew "B / bob@example.com" for another person, the backstage's Owner row an email,
the console's laptop-session page the author as an email. DESIGN.md §2 asks for initials
and the full name.

**Events.** The plane never sees an event, so it cannot fill a name into one after the
fact, and a hash-chained log is not rewritten. The name travels with the connection
instead: on a pod the token the plane signs carries `name` beside `sub`, from the identity
record SCIM and sign-in write; on a laptop the principal is the linked person, or the
operating system's user. The gateway writes the event's `actor` with that name as
`display_name`. A connection whose name is only its subject again (a token with no name
claim falls back to `sub`) writes none, so a client tells "no name" from a name.
`session_created` carries `owner_name` beside `owner` where the writer knew it; a pod is
told no owner, so its sessions' names come from the plane's rows. The event shapes that
carry a `subject` in their data carry `display_name` beside it, which a test holds over
both the schema and `PROTOCOL.md`'s table.

**Rows.** `Troupe.Plane.Names` answers the names of a set of subjects in one query and
decorates rows with them, so no handler does it by hand: `owner_name` on every session
row the harness answers and on `admin.sessions.list`, `actor_name` on `admin.audit.list`.
The offers' and invitations' `owner_name` and `invited_by_name` were already there.

**Clients.** The client package reads the actor's name into the entry (`authorName`,
`decidedByName`) and the row's into `ownerName`, through one `named` rule (non-empty, not
the subject). The desktop's author line and ring, the backstage's Owner row and the
`/copy` text, the console's session and audit tables (the subject on hover) and the
laptop-session transcript, and the TUI's transcript (`BE · Bob Example` above another
person's line, once `initialize` said who this connection is) and its session rows show
the name. Initials are two letters from the name, or from the subject's local part.
"You" stays for the reader's own. A plane or daemon from before sends none, and each
client shows what it showed before.
