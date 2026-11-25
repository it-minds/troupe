---
number: 1110
title: "A session has a lifespan, throwaway, normal or persistent, beside its kind and visibility: normal is today's; throwaway is erased a set time after it last worked, asleep with nothing waiting; persistent is never cleared away by any sweep and still sleeps; its owner alone sets it"
date: 2026-11-25
status: accepted
issue: 1209
paths:
  - apps/troupe_protocol/lib/troupe/protocol/lifespan.ex
  - apps/troupe_plane/lib/troupe/plane/sessions/session.ex
  - apps/troupe_plane/lib/troupe/plane/sessions.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/memory/proposals.ex
gist: "lifespan throwaway|normal|persistent (default normal, every old row normal); session.lifespan.set owner only, audited, pod logs session_lifespan_changed; pin = list order only; throwaway proposes no team memory"
---

Issue #1209. Every session lived the same way, and the pin's mark promised an exemption
from a retention that does not run (#635).

**The word.** `lifespan`, because `kind` is taken (team, private, local). Orthogonal to kind
and visibility: a team, only-me, private or local session can be any of the three.
`Troupe.Protocol.Lifespan` holds the words for the plane, the pod and the daemon.

- **normal**: today's, the default of every create, fork, spawn and trigger run, and what
  every row and log from before it is (the column defaults to it; a log without the field
  is normal).
- **throwaway**: erased by a sweep a set time after it last worked, once dormant with no
  approval or question waiting, not awaiting review and not pinned, through the erasure
  every session has; audit, spend and tombstone stay. It proposes nothing for a team's or
  the organisation's memory, in a sentence the agent relays: its erasure would delete the
  proposal from the administrator's queue unread.
- **persistent**: never cleared away by any sweep, now or when a team's erase-after runs;
  it sleeps, holds no pod, and its artifacts keep their own retention.

**The owner alone changes it,** with `session.lifespan.set`, shaped as Decision 1091's
`session.visibility.set`: an administrator is `forbidden` (they erase instead), audited
`from`/`to`, the pod told `lifespan.changed` so the log has `session_lifespan_changed` and a
checkpoint's facts fold it; a dormant or private session's change is its row. A private
session's row says it too, since the plane's sweep destroys its key (Decisions 756, 811).

**It narrows Decision 1038**: the pin is the list's order only; the retention it was said
to exempt from is the lifespan's to say. Archiving (Decision 1023) is untouched.

**`initialize` says `lifespans: true`** on the plane and the daemon, and a client offers the
choice only where it is said: a server from before it makes a normal session of any word.

## Not chosen

- Throwaway as "sealed with a short retention": it would keep it off the team's pods.
- Persistent as never asleep: a held slot and budget slice, and a profile that cannot
  scale down past it.
- Renaming the unused `retention_class`: a plane from before it selects that column, so a
  rename fails its session reads during the upgrade and after a rollback. It is left, unread.

## If undone

A short question leaves its log and workspace behind for ever, and a long report has no way
to say it stays; a throwaway session's proposals vanish from the review queue unread.
