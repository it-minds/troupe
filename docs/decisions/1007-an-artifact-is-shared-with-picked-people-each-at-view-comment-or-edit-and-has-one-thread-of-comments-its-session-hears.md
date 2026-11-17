---
number: 1007
title: "An artifact's owner shares it with picked people by name, each at view, comment or edit, with artifact.share naming a person instead of making a link, and a link may give comment too; every artifact has one thread of comments on the plane, read by whoever may open it and written by its owners and whoever holds comment or edit, which the session it came from hears as an artifact_commented event, never as input"
date: 2026-11-16
status: accepted
issue: 62
paths:
  - apps/troupe_plane/lib/troupe/plane/artifacts/shares.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts/people.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts/comments.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts.ex
  - apps/troupe_gateway/lib/troupe/gateway/artifacts.ex
  - clients/gui/apps/desktop/src/views/Artifacts.tsx
symbols:
  - Troupe.Plane.Artifacts.People
  - Troupe.Plane.Artifacts.Comments
  - Troupe.Plane.Artifacts.comments/3
  - Troupe.Plane.Artifacts.comment/4
gist: "artifact.share {person, role} grants by name (no link), roles view < comment < edit, strongest of link/grant/visibility wins; artifact.comments/comment, one thread, writers owner/edit/comment; pod session hears artifact_commented, never input"
---

## Picked people

`artifact.share {id, person, role}` shares the artifact with that one person by name, at
`view`, `comment` or `edit`, and makes no link. It is the owner's alone, as every share is.
The person need open nothing: the artifact is under `scope: shared` in their gallery at once,
whatever it is for. Naming them again changes the role. `artifact.unshare {id, person}`, which
already revoked a person from every link, takes the grant back too: "they no longer hold
this" means every way they held it. A row in `artifact_people` per artifact and person; the
person's deletion or the artifact's takes it.

**Roles add up.** What a person is to an artifact is the strongest of what a link they used,
the owner's naming them and who it is for give: `edit` above `comment` above `view`, owners
above all. `role/2` reads all three at every request on both hosts, as before. `comment` reads
it and writes in its thread; `edit` does that and puts a version, as an edit link did. Links
may give `comment` too, since a role is a role however it was given. Public links stay view
only.

**The picker** is `people.search`, which the session's invitation picker already uses: people
who share a team with the caller. The daemon forwards it, so the desktop app's gallery picks
the same people whether it reads the plane itself or through this computer's daemon, and
Local only refuses it as every `artifact.*`. The plane grants to any active person of the
plane by subject (an organisation's artifact already reaches all of them); the clients offer
whom the picker finds. The console lists and removes who an artifact is shared with by name
and does not pick: a person's own things are picked in their own app (Decision 954).

**Not chosen:** the put that sends no files (Decision 955) carrying a `people` list, as the
brief for this slice suggested. A put is a version, which an edit link's holder may make
too; who may open it beside its visibility is an owner's act, and `artifact.share` and
`artifact.unshare` are already the owner's "who else", forwarded by the daemon (Decision
954), with `person` already an argument of the second. A version per pick would also fill
the history the versions list shows with sharing rather than content. The audit records each
grant, change and removal (`artifact.share` and `artifact.unshare` with `person` and `role`).

## Comments

One thread per artifact, `artifact_comments` on the plane: author (the person, nulled if they
are removed, the subject kept), text (trimmed, at most 4000 characters), when. The artifact's
deletion takes it. `artifact.comments {id}` answers it oldest first, the newest 500, with each
author's name filled from the identity record (Decision 992) and whether the caller may write;
`artifact.comment {id, body}` writes one for an owner, an `edit` or a `comment` holder, and is
`forbidden` with a sentence that says who may to anybody who reads the artifact only because
of who it is for. Rows of `artifact.list` and `artifact.get` carry `comments` (how many),
`commented_at` and `may_comment`, so a gallery shows a thread without asking for it. Audited
as `artifact.comment` with the comment's id and length, never its text; reading is not
audited.

**Who is told.** The session the artifact came from, where that is a pod's and it runs: the
plane notifies its pod `artifact.commented`, and the pod writes `artifact_commented` (the
artifact's id and title, the comment) in the session's log at the plane's epoch, best effort,
as a share's or a memory save's news is. Whoever steers the session reads it beside the work,
and may ask the agent to act on it. It is never input: a comment is somebody else's words,
and a reader with `comment` must not be able to steer an agent they could not steer
otherwise.
