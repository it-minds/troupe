---
number: 1049
title: A platform administrator reads every memory document the plane holds, a person's own included, and every artifact's page, a person's private one included, each read a row in the audit naming who read whose; a person's own memory stays theirs and their agents' to change, an administrator reading and, by removing the person, erasing it; and the console's first group, Oversee, is that whole view, with a person's own a filter beside everybody's
date: 2026-11-18
status: accepted
issue: 1096
supersedes: [942]
paths:
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/admin/api.ex
  - apps/troupe_plane/lib/troupe/plane/memory.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts.ex
  - clients/gui/apps/console/src/nav.ts
  - clients/gui/apps/console/src/views/Memory.tsx
  - clients/gui/apps/console/src/views/Artifacts.tsx
  - clients/gui/apps/console/src/views/ArtifactAudit.tsx
symbols:
  - Troupe.Plane.Admin.memory_people/1
  - Troupe.Plane.Admin.memory_person/4
  - Troupe.Plane.Admin.artifact_get/2
  - Troupe.Plane.Artifacts.admin_get/3
  - Troupe.Plane.Memory.people/0
gist: "admin.memory.people/person (platform admin, read only, memory.read per read) and admin.artifact.get (artifact.read per read, never files); Oversee first; Mine a filter"
---

The maintainer, on #1096: "It needs to be ALL artifacts and ALL memory as this is the global
admin console. I need to control and audit it all."

**A person's own memory.** This narrows Decisions 943 and 954, which had it read by nobody but
its person. `admin.memory.people` lists, for a platform admin alone, everybody who keeps one:
subject, name, the version in force with its size and who saved it when, never its text.
`admin.memory.person {person, version?, against?}` reads one as `admin.memory.get` reads the
organisation's (text, versions, diff, lines, entries) and writes one audit row per call,
`memory.read` on `user/<subject>` with the version read, so who read whose is in the trail. A
team admin reads nobody's: a person's memory follows them across teams, so no team answers
for it. The console reads one only on a page of its own (`#/memory/person/<subject>`), so a
row in the audit is a choice somebody made. The person's apps say the plane's platform
administrators may read it (`me.memory.preview`'s effect, the console, the desktop app).

**Read and erase, never edit.** `admin.memory.put`, `preview`, `rollback` and `nudge` still
refuse a person's scope. A person's memory is what they and their agents wrote for their own
sessions; an administrator's words belong in the organisation's, a team's or a profile's,
which the person's sessions read first and which say they are the organisation's. An edit by
somebody else would put words in a person's mouth. Erasure is the person's removal, which
deletes their documents (`Identity.remove_user/2`), not a new method.

**An artifact's page.** This narrows Decision 953's "nor read it" for a platform admin, and
gives a team admin the same for their teams' artifacts. `admin.artifact.get {id}` answers what
`artifact.get` answers its owner, with its links, who it is shared with and its comments, a
private one too, and `may_open`; it never returns a file nor the publisher's picture, and
writes `artifact.read` per call. Opening one on the artifacts host stays its owner's and their
links' holders' (953 holds there): the page says so and offers the takedown. The owner's
methods are not widened, so a person's own app answers nothing it did not before.

**The map.** Oversee comes first: Artifacts (Every artifact, then Mine and the person's other
tabs) and Memory. Published artifacts and Company memory are gone into them; Mine is a tab of
Sessions, a person's clients are on Client versions, their own memory on Memory; `#/mine…`
and `#/published` redirect. A member is shown Artifacts, Memory, Sessions and Client versions,
each theirs alone, in place of Decision 942's Mine; its pushed offers hold as they were.

Not chosen: one `admin.memory.get` scope for people (its writers would have to refuse it one
by one); an unaudited listing with text; an administrator's edit of a person's memory.

Undone, an administrator again cannot see what the plane holds, or reads it unrecorded.
