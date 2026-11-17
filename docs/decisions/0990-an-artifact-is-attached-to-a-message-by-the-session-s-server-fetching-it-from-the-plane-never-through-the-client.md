---
number: 990
title: "An artifact is attached to a message by fs.upload naming it in place of bytes: the session's server fetches the version's files from the plane as the person who asked, a pod over its control link for someone who steers the session and a daemon with its sign-in, so the bytes never pass through the client"
date: 2026-11-15
status: accepted
issue: 920
supersedes: [986]
paths:
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/lib/troupe/gateway/artifacts.ex
  - apps/troupe_gateway/lib/troupe/gateway/connection.ex
  - apps/troupe_core/lib/troupe/artifacts.ex
  - apps/troupe_worker/lib/troupe/worker/artifacts.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/gui/apps/desktop/src/views/Session.tsx
  - clients/gui/packages/client/src/session.ts
symbols:
  - Troupe.Artifacts.files/1
  - Troupe.Plane.Artifacts.files/4
gist: "fs.upload {artifact, version?, file?, path?}: server fetches files from plane as the asker (pod: control link, steerers only; daemon: sign-in); capability fs_upload_artifact"
---

Issue #920's third part. The composer's "Add from artifacts" worked on this computer by the
desktop reading each file through the daemon (`artifact.read`) and uploading it
(`fs.upload`); on a pod the daemon is not in the path, so it was a void (Decision 986).

**The server fetches; the client names.** `fs.upload` takes `{artifact, version?, file?,
path?}` in place of `content`: the artifact, the version (the one its address serves where
none is named), one file of it, and the folder the files land in (`session:/` where none is
named), each at its own path in the artifact. The session's server asks the plane for the
files through its host (`Troupe.Artifacts.files/1`, installed as the publisher is): a pod
asks `session.artifact.files` over its control link, a daemon the plane's `artifact.files`
with its sign-in. The bytes go plane to server; the client sends an id and receives where
each landed. Not chosen: the client reading and uploading on the platform as it did here,
which carries every byte twice through the person's connection and needs a sign-in on the
client the pod does not need; and the plane writing into a pod's volume itself, which it
has no path to.

**As whom.** The plane reads the artifact as the person on the connection, by the rules
every read follows (`Artifacts.visible/3`: owner, team, audience, a link's holder). Over the
control link the pod names that person, whom its session token's plane-signed subject
says; the plane then also requires that they steer the session (owner, collaborator, or a
team member with `control`), so a pod can fetch nothing for someone who has not joined one
of its sessions. The control link's "no session content" rule (its module doc) is about
what goes up; this goes down, the person's own choice into their session, as memory goes
down with an activation. Audited as `artifact.attach` with the session, version and count.

**Limits.** 2 MB of files together in one attachment, under what one message of either
path carries comfortably once in base64; past it the refusal says the size and to name one
`file`. Every file is decoded and confined to the workspace before any is written, so a
path that would leave it (`forbidden`) writes nothing. Binary files go as they are, unlike
`content`, which is text: they never pass through JSON as text. Each written file is an
`fs_changed` of the person's.

**Refusals keep the plane's code.** `not_found` for one the person may not see or a version
or file that is not there; `unavailable` for a daemon not signed in ("troupe login signs it
in"), a pod whose link is down, and a session under Local only, which asks the plane
nothing.

**The client.** Both a daemon and a pod name `fs_upload_artifact` at `initialize`. The
desktop then attaches the artifact itself (its title as the tag) and sends `fs.upload` with
it as the message goes, saying in the message where each file landed, in `/upload`'s words.
On a platform session it lists the person's artifacts from the plane it is signed in to; on
this computer from the daemon. Against a daemon from before it, the old path stands: each
file read and uploaded. This replaces Decision 986's "Not yet on the platform".

**What an older client sees.** A capability it does not know; `fs.upload` with `content`
as before.

## Proof

`attach_artifact_test.exs` (the daemon's dispatch with a stand-in host): every file of the
version under the folder named, binary included, each an `fs_changed` of the person's, the
host asked as them; the root and one `file`; a path outside the workspace writing nothing;
the plane's `not_found` kept and signed out saying how to sign in. `control_test.exs`: a
pod handed a version's files for the session's owner, one file by `path`, the audit row,
and refusals for someone who does not steer the session, someone who is nobody, an artifact
nobody may see and a session another pod holds. `artifact_versions_test.exs`: `artifact.files`
for whoever may see it, not for someone who may not, nor for a missing file or version.
`harness_auth_test.exs`: a pod with no link says so. All failed on the chunk's tip, where
`fs.upload` required `content` and neither method existed. Desktop: `session-chat.test.tsx`,
an artifact attached on a platform session and fetched by the pod, one on this computer
fetched by the daemon, and the old path against an older daemon.
