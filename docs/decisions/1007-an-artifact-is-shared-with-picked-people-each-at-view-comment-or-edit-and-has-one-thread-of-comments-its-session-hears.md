---
number: 1007
title: "An artifact's owner shares it with picked people by name, each at view, comment or edit, with artifact.share naming a person instead of making a link, and a link may give comment too; every artifact has one thread of comments on the plane, read by whoever may open it and written by its owners and whoever holds comment or edit, which the session it came from hears as an artifact_commented event, never as input"
date: 2026-11-16
status: accepted
issue: 62
paths:
  - apps/troupe_plane/lib/troupe/plane/artifacts.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts/people.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts/person.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts/comments.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts/comment.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts/shares.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/priv/repo/migrations/20261116001007_artifact_people_and_comments.exs
  - apps/troupe_worker/lib/troupe/worker/plane/commands.ex
  - apps/troupe_gateway/lib/troupe/gateway/artifacts.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/gui/packages/client/src/artifacts.ts
  - clients/gui/packages/client/src/own.ts
  - clients/gui/packages/client/src/daemon.ts
  - clients/gui/apps/desktop/src/views/Artifacts.tsx
  - clients/gui/apps/console/src/views/ArtifactComments.tsx
  - clients/gui/apps/console/src/views/ArtifactLinks.tsx
  - clients/gui/apps/console/src/views/Artifacts.tsx
  - clients/tui/lib/troupe/ui/tui/artifacts_page.ex
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/gui/packages/client/src/transcript.ts
symbols:
  - Troupe.Plane.Artifacts.People
  - Troupe.Plane.Artifacts.Comments
  - Troupe.Plane.Artifacts.comments/3
  - Troupe.Plane.Artifacts.comment/4
gist: "artifact.share {person, role} grants by name (no link), roles view < comment < edit, strongest of link/grant/visibility wins; artifact.comments/comment, one thread, writers owner/edit/comment; pod session hears artifact_commented, never input"
---

Issue #62's last slice. Decisions 948, 950, 953 and 964 shipped the store, versions at one
address, links that honour sign-in, team and private visibilities and team ownership;
Decision 950 left "teams and picked people; comments", and named a link as what covered a
picked person meanwhile. A link has to be sent and opened before it gives anything, and the
issue's picker "searches people", and asks for "roles per share: view, comment, edit".

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
whom the picker finds.

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
otherwise. The owners and editors find comments on the gallery's cards (the count) and the
artifact's view in the desktop app and the console, where the thread is shown beside its
details.

## Clients

The desktop app's aside has **Shared with** under *Who can see it* for an owner (the people,
each at a role, **Remove**, and **Share with** with the search and *They may* view, comment or
edit) and **Comments** for everybody, with a box where the plane says the caller may write.
`audienceOf` reads `scope: shared` before `private`, so a private artifact shared with
somebody is under *Shared with you* for them, not *Only you*; that was wrong for a link's
holder before this too. The gallery gains a choice of kind beside the audience chips. The
console's artifact page shows the thread and, for an owner, who it is shared with by name and
**Remove**; its links offer **Comment**. The terminal's *Shared with you* row says "you may
comment" or "you may edit", and its empty tab says a share by name lands there.

## Left

Thumbnails, #977 (a page drawn to an image needs a browser on the plane, which the plane does
not run and the artifacts host's isolation would have to extend to); pinning an artifact in a
person's gallery and filters by team and date, #978 (the owner's version pin exists); a
comment's deletion or editing, #979; a laptop session hearing a comment, #980 (the plane has
no way to tell a daemon's session today); and a retention period, #981, the one admin control
#62 names that has none. The console lists and removes who an artifact is shared with by name
and does not pick: a person's own things are picked in their own app (Decision 954).

## Proof

- `apps/troupe_plane/test/troupe/plane/artifact_people_test.exs`: a person picked at view finds
  it under Shared with you, opens it on both hosts, and may not put, comment, share or delete;
  nobody else sees it; at comment writes in the thread and may not put; at edit puts and
  comments and does nothing an owner does; listed for the owner only, named again at another
  role, removed, each audited; refused for nobody, for the owner, for a role that is not one,
  and to a non-owner; the stronger of a link's and a grant's role, both ended by one removal;
  the thread read by an organisation's reader who may not write until given a role, oldest
  first with names, counted on the rows; empty and long refused; not there for whoever may not
  open it; audited without its text; gone with the artifact; and the session it came from, on
  a pod, told `artifact.commented` with the artifact, the author and the text.
- `apps/troupe_worker/test/troupe/worker/artifact_comments_test.exs`: the pod writes
  `artifact_commented` in a running session's log and starts no turn; nothing for a session
  not up there or at another epoch; a shapeless one refused.
- `apps/troupe_gateway/test/troupe/gateway/artifacts_test.exs` (the share with a person, the
  thread and `people.search` forwarded with only their arguments) and `local_only_test.exs`
  (refused under Local only).
- The desktop app's `artifacts-gallery.test.tsx` (a picked person at a role, listed and
  removed; the thread with names and a box for a role that comments, none for a reader; the
  kind filter), the console's `artifact-comments.test.tsx`, and the terminal's
  `artifacts_screen_test.exs` (a row shared by name under Shared with you, saying the role)
  and `remote_translate_test.exs` and the client's `transcript.test.ts` (`artifact_commented`
  as one line with who, which and what).

All of the plane's failed on the chunk's tip (`767aa773`): there was no `person` on
`artifact.share`, no `comment` role and no thread.
