---
number: 955
title: An artifact's owner moves who may open it with an artifact.put over its newest version that sends no files, a new version carrying every file, which the daemon forwards so the desktop app changes it in place; a pod sends a large version by an upload handle as a daemon does; and a path part past 255 bytes is refused before anything is written
date: 2026-10-27
status: accepted
issue: 765
paths:
  - apps/troupe_plane/lib/troupe/plane/artifacts.ex
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - apps/troupe_gateway/lib/troupe/gateway/artifacts.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_worker/lib/troupe/worker/artifacts.ex
  - clients/gui/apps/desktop/src/views/Artifacts.tsx
gist: artifact.put with base and no files carries every file (visibility moves in the app via the daemon); pods upload past 2.5 MB by handle; path parts <= 255 bytes
---

**Why.** D137 and the chunk's first wave left three things a person met. The desktop app's
*Change who can see it* opened the console, because moving an artifact's visibility had no
call the daemon forwarded (Decision 954 says so), and the only call that moved it,
`artifact.publish` or `artifact.put` with `id`, needed the files sent again: a put with no
files was refused. With Decision 953's `private` and `team:<name>`, which visibility an
artifact has is the first thing its owner may want to change, and the console's Mine is to
stay as it is (the maintainer, on #765, 2026-10-26). A pod's agent sent an artifact inline
over its control link, so a version past what one message carries (8 MiB) could not be
published from a pod at all, while a daemon's went by an upload handle. And a path part
past the object store's 255 bytes was refused by the store halfway through writing a
version.

**The decision.**

- **A put over a version may send no files.** `artifact.put {id, base, visibility?, title?,
  note?}` with neither `files` nor `upload` is the next version carrying every file of
  `base`, their objects not copied. It is checked as any put is: `base` must still be the
  newest (`conflict` otherwise), only the owner moves `visibility`, and a move to a team takes
  every stored byte to that team's quota (Decision 953). It stays a version, not a field
  changed in place, so the history says when an artifact was moved and by whom, as every
  other change to one does (Decision 950). Without `base` a put with no files is refused as
  before: there is nothing to carry.
- **The daemon forwards it**, with `id`, `base`, `visibility`, `title` and `note` and never
  files (those go by `artifact.publish` with `id`), refused under Local only as every
  `artifact.*` is (Decision 951). The desktop app's *Change who can see it* is a choice of
  the same audiences its Publish dialog offers, in place; this narrows Decision 954, under
  which it opened the console's page.
- **A pod sends a large version by an upload handle**, as a daemon does: past about 2.5 MB of
  base64, `session.artifact.upload.begin {session_id, epoch?, files}` over the control link
  answers a handle for the session's owner, the pod PUTs each file to its presigned URL, and
  `session.artifact.publish` names `upload`. One function decides it for both
  (`Troupe.Gateway.Artifacts.carried/2`), given how each begins. A pod reaches the object
  store as it does to seal a session; a deployment whose worker egress does not reach the
  plane's object-store endpoint publishes only what fits inline.
- **A path part is at most 255 bytes**, the object store's own limit, refused with the
  publish's other path rules before anything is written.

**Proof.** `artifact_teams_test.exs`: an owner's put with `base` and no files is version 2
with version 1's files, moved; without `base` it is `invalid_params`, over a replaced base
`conflict`, and nobody else moves it. `apps/troupe_gateway/test/troupe/gateway/artifacts_test.exs`:
`artifact.put` forwarded with only its arguments, and a publish to a team the person is not
in keeps the plane's `forbidden` and its `teams`. `apps/troupe_worker/test/troupe/worker/artifacts_test.exs`:
a 10 MiB file from a pod, refused on the tip (the link could not carry it), published by a
handle and read back from the store. `artifacts_test.exs` and `artifact_versions_test.exs`:
a 256-byte part is `invalid_params` and no object is written. The desktop's
`artifacts-gallery.test.tsx`: the move sends `artifact.put` with no files and opens no
console page, and a conflict is said in the plane's words.
