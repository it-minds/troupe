---
number: 1018
title: "A person keeps an artifact at the top of their own gallery with artifact.keep {id, on}, a row of theirs on the plane that artifact.list says as kept on each row and never leaves out of its 500, not audited and nobody else's; the desktop app groups the kept ones above Today, This week and Earlier, and narrows the rest by team, with a second row of chips inside Your teams where it shows more than one, and by the days they were published, a choice of the app's alone"
date: 2026-11-16
status: accepted
issue: 978
paths:
  - apps/troupe_plane/lib/troupe/plane/artifacts/keep.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts/keeps.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts.ex
  - apps/troupe_gateway/lib/troupe/gateway/artifacts.ex
  - clients/gui/apps/desktop/src/views/Artifacts.tsx
symbols:
  - Troupe.Plane.Artifacts.keep/4
  - Troupe.Plane.Artifacts.Keeps
gist: "artifact.keep {id, on}: the person's own row on the plane (user, artifact, when), kept on each list/get row, never cut by the 500, not audited; desktop groups kept above the days; team chips inside Your teams only with 2+; published since/until is the app's, reset with it"
---

## The word

**Keep at the top**, **Kept at the top** and **Let go from the top**. "Pin" is taken: an
artifact's owner pins the version its address serves (Decisions 950 and 953), and two pins
on one aside, one the owner's on the artifact and one the person's on their gallery, would
say two things with one word. DESIGN.md §11's word list has no favourite or star, and "keep"
says what happens without one. The method is `artifact.keep {id, on}`, one call with a
boolean, as `artifact.public {id, enabled}` is.

## Where it lives: the person's, on the plane

A row in `artifact_keeps` per person and artifact, with when. It is the person's view of their
gallery, not the artifact's, and it follows them: the desktop app on another computer, signed
in or through its daemon, reads the same `kept`. "New to you" stays this device's storage
(Decision 954): it is about what this device opened. A row goes with its person and with its
artifact (foreign keys, deleted with either). One for an artifact the person may no longer open
stays where it is and is never read, since `artifact.list` answers only what they may open; if
they may open it again, it is kept again. Chosen over deleting the row when access ends because
access ends in many places (a team left, a share taken back, a visibility moved) and none of
them should have to know about galleries.

Anybody who may open the artifact may keep it, for themselves alone; a principal has no gallery
and is refused. `artifact.list` and `artifact.get` say `kept` on each row. **The plane does not
reorder the list:** it stays newest first for every client (the console and the terminal say so
in words), and the desktop app forms the group. The plane does make sure a kept one is never
cut off by the list's 500: it takes the kept ones first into the 500 and puts every row back
newest first.

**Not audited.** It changes nothing anybody else sees, reads or may do; it is the person's
own view state, as reading their gallery is (Decision 954), and the audit is for what changes
an artifact or who may open it.

## The desktop app's gallery

The kept ones form a group above *Today*, *This week* and *Earlier*, titled **Kept at the
top**, and are not repeated below; the audience chips, the kind, the search and the range
narrow it as they narrow the rest. The aside offers **Keep at the top** or **Let go from the
top** where the plane says `kept` (a plane from before it says nothing, so there is no choice
to offer, DESIGN.md §8).

**Team chips.** Inside *Your teams*, when what it shows is for more than one team or profile,
a second row of chips names each (a profile as "<name> profile", since *Your teams* holds
both), with a count, and **All of them**. With one there is nothing to choose and no row. The
choice applies only while that row is shown, so it never narrows the list unseen.

**Published since … until ….** Two day fields beside the kind, each end included and either
open, read in the computer's own time zone. They narrow which artifacts the groups show; empty
is as before. The range, the team and the kind are this window's and reset when the app starts
again, as the kind already did; nothing of them is stored. The plane's `artifact.list` does not
take a range: it answers the newest 500, which is every artifact a person sees today, and a
range the client applies is one less argument for the daemon to forward. When lists pass a page
the plane should take it, with the search.
