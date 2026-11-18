---
number: 1020
title: A gallery card shows the picture its publisher sent with the version, a PNG, JPEG or WebP of at most 256 KiB kept beside the version's files and served by the artifacts host at a signed address for the person whose row gave it; nothing on the plane or a worker renders a page into one in this slice
date: 2026-11-16
status: accepted
issue: 977
paths:
  - apps/troupe_plane/lib/troupe/plane/web/artifacts.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts/version.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts.ex
  - apps/troupe_core/lib/troupe/tools/publish_artifact.ex
  - clients/gui/apps/desktop/src/views/Artifacts.tsx
symbols:
  - Troupe.Plane.Artifacts.thumbnail/1
gist: "Thumbnail = the publisher's own image per version (png/jpeg/webp, 256 KiB, not decoded); served at /t/<signed> for that person, visibility read per request; no renderer"
---

## Who draws it: the publisher

The publisher sends it with the version. `artifact.publish` (and `artifact.put`, and the
pod's `session.artifact.publish`) take an optional `thumbnail: {content_type, bytes}` beside
`files`, base64 as the files are. A separate key, not a reserved path among `files`: a
reserved path would be one of the page's own files, in its hash, its file list, the editor's
choice of files and the entry a page opens, and served at `/a/<id>/` to the page itself. A
key of its own also fits `artifact.upload.begin` with nothing new: at most 256 KiB, about
350 KB as base64, it always rides inline in the publish call, beside `files` or beside an
`upload` handle, under the plane's 4 MiB door with the daemon's 2.5 MB inline budget for
files and under the control link's 8 MiB.

**Limits.** `image/png`, `image/jpeg` or `image/webp`, at most 256 KiB, its first bytes that
kind's signature; anything else is `invalid_params` with a sentence saying which. The plane
reads those few bytes and nothing more: no image library is on the plane, nothing decodes or
resizes the picture, and a client draws it fitted to the card (`object-fit: cover`). It is
stored at `artifacts/<id>/thumbnails/<n>` in the object store, beside the version's files and
never among them (no path is a number followed by `thumbnails`, since a file's key is
`artifacts/<id>/<n>/<path>`), and an artifact's deletion takes it with every other byte. It
counts against the team's `artifact_quota_bytes` as a file does.

**Not chosen: a renderer.** A headless browser on the plane would be a new dependency, and
it would run a stranger's page outside the artifacts host's policy and network isolation: a
new attack surface on the one service that holds every person's sign-in. A job on a worker
would run it where agents run, which Decision 948 keeps an artifact out of. A later slice may
add one, run as the artifacts host's own client under that host's policy, filling the same
`thumbnail` a publisher fills now. In this slice the `publish_artifact` tool takes a
workspace path (`thumbnail`) and its description says to send one only where the agent
already has a screenshot of the page; it is never required.

## Which version's

Each version's own, so a card never shows a picture of a page that is not the one it opens:

- a version that sends any file and no picture has none, whatever the one before had;
- a version that sends no file (Decision 955's put that retitles or moves who may open it) is
  the page its base was, and keeps the base's picture, carried rather than copied
  (`stored_in`, as a carried file is);
- a rollback carries the picture of the version it brings back;
- the row's picture is the version its address serves: the pinned one, else the newest,
  moved by `artifact.pin` as `bytes` is.

## Where it is served

On the artifacts host, under its policy (`Web.Artifacts.CSP`, with `nosniff`): `GET
/t/<token>`, the image with the type it was sent with, `cache-control: private`. A row of
`artifact.list` and `artifact.get` carries `thumbnail_url`, that address, or `null`.

A gallery's `<img>` cannot carry the artifacts host's cookie: the console and the desktop app
are other origins that never opened the artifact, and the cookie only comes from a ticket
(Decision 948). So the address is its own key: `Plug.Crypto` signed with the plane's secret
under a salt of its own, naming the person the row was made for, the artifact and the
version, dated to the start of the hour and good for two hours, so a gallery listed twice in
an hour asks for the same address and a browser keeps the picture. At every request the host
reads that person again, as active, and whether they may still see the artifact now
(`visible/3`); a forged or old address, a leaver, a moved or deleted artifact, and a version
without a picture are the host's 404. Decision 948 turned down a capability in the path for a
page, whose links copy it into every address the page loads; a picture loads nothing, and
its address stops at the next request once its person may no longer see the artifact. No
image bytes are in a list's answer.

**The apps' policies.** The GUI image's `img-src` gains `https:`, as `connect-src` and
`frame-src` already name it for hosts a deployment chooses at run time; the desktop shell's
gains `https:` and `http://127.0.0.1:*` (a local plane's artifacts host). An image runs
nothing. This narrows Decision 954's "no picture of the artifacts host in the app" to this
one picture, an image from that host at an address the plane signed; the app still fetches
none of an artifact's files and draws no frame. A picture that does not load (its address
past its hours, the artifact gone) leaves the card as it was without one.

## Left

The terminal's `/publish` takes no picture: its arguments are positional (a path, an
audience, an owner), and a picture needs a flag the parser does not have. The terminal's
gallery draws no image. The administrators' table (**Published artifacts**) stays a table of
titles, owners and sizes. A renderer, as above.
