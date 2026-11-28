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

> Superseded in part by Decision 1121: the teams and people that read an artifact change with no version (`artifact.access.set`); a put moving only between private and organisation is still a version.
