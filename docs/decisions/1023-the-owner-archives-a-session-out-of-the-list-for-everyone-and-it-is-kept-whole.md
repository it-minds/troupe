---
number: 1023
title: "The owner archives a session out of the session list for everyone who sees it; it is kept whole and opens, and only session.unarchive brings it back"
date: 2026-11-17
status: accepted
issue: 1005
paths:
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/sessions.ex
  - apps/troupe_plane/lib/troupe/plane/sessions/session.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/priv/repo/migrations/20261117001021_session_archived.exs
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_core/lib/troupe/sessions/archive.ex
  - apps/troupe_core/lib/troupe/sessions/pin.ex
  - apps/troupe_core/lib/troupe/sessions/index.ex
  - apps/troupe_core/lib/troupe/commands.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_worker/lib/troupe/worker/auth.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
symbols:
  - Troupe.Plane.Sessions.archive/3
  - Troupe.archive_session/2
  - Troupe.Sessions.Archive
gist: "session.archive = dormant + archived flag (owner's, out of everyone's list, kept whole, opens); session.unarchive; lists default to not archived, archived: true lists them; admin lists both"
---

Issue #1005. Sessions piled up in the list. The only way out was `session.erase`, which
deletes. `session.archive` existed, but it only put a session to sleep, it stayed listed,
and no client called it.

**`session.archive` takes the session out of the list.** It still puts a running session to
sleep, as before, and now also marks it `archived`. An archived session is out of the
session list for everyone who sees it: the owner, the people on its ACL, and the team for a
team session. It is kept whole: log, workspace and state are untouched. It still opens for
anybody who could open it, and working in it again does not bring it back into the list.
Only `session.unarchive` does. Archiving is the owner's, as pinning and erasing are,
because it takes the session out of other people's lists. Both ways are audited on the
plane, and an archive that put a pod's session to sleep names the pod, as it did. The old
meaning is kept inside the new one, rather than given a method of its own, because no
client used it and "archive" is what a person means by hiding a session they're done with.

**The flag is not a state.** `archived` sits beside `state` (and beside `pinned`). A
session's state is about where it runs; whether it is listed is about the people looking
at it. A state would have needed every place that reads `state` to learn a new value, and
the `"archived"` arms already in the plane's `spawnable/1` and `forkable/2` were never
reached. A pending session is still refused, as before: there is no pod to put to sleep,
and it would start hidden.

**Lists default to not archived.** The plane's `sessions.list`, the daemon's `session.list`
and `fleet.get` list the sessions not archived. `archived: true` (on the daemon, in
`filter`) lists the archived ones instead. The default lives in those methods, not in the
stores: an administrator's `admin.sessions.list` lists both, with `archived` and
`archived_by`, and the daemon's own lookups by id find an archived session as before.

**On a daemon the mark is a file**, `archived`, beside the log, as the pin is.
`Troupe.Sessions.Pin.put_mark/4` and `marked?/2` are now how both are kept, so marking a
dormant session writes nothing to a log it has not opened.

**Both clients offer it**, as the commands `/archive` and `/unarchive` in the harness's
table:
- **The desktop app:** the session's ⋯ menu, for the owner; an "Archived" filter on the
  session list; Unarchive on an archived row.
- **The terminal:** the commands, and `/sessions archived`.

## Not chosen

- **Each person hiding a session for themselves.** Asked of the maintainer, who chose the
  owner archiving for everyone.
- **Unarchiving on activity.** Someone opening an archived session to read it would put
  it back in everyone's list.
