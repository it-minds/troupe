---
number: 950
title: "A republish is a new version at the same URL, with history, rollback and a pin the owner sets; the console edits a page's or a document's text with the artifacts host's own preview framed beside it; a share is a link that honours the plane's sign-in, giving view or edit to whoever the plane signs in through it, recorded per person and revoked by link or by person; and there is no public link unless an administrator switches them on"
date: 2026-10-25
status: accepted
issue: 62
paths:
  - apps/troupe_plane/lib/troupe/plane/artifacts.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts/*.ex
  - apps/troupe_plane/lib/troupe/plane/web/artifacts.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/settings.ex
  - apps/troupe_plane/priv/repo/migrations/20261025000950_artifact_versions_and_links.exs
  - apps/troupe_plane/test/troupe/plane/artifact_versions_test.exs
  - apps/troupe_plane/test/troupe/plane/artifact_shares_test.exs
  - apps/troupe_plane/test/troupe/plane/artifact_links_host_test.exs
  - apps/troupe_core/lib/troupe/tools/publish_artifact.ex
  - apps/troupe_gateway/lib/troupe/gateway/artifacts.ex
  - clients/gui/apps/console/src/views/Artifacts.tsx
  - clients/gui/apps/console/src/views/ArtifactEditor.tsx
  - clients/gui/apps/console/src/views/ArtifactLinks.tsx
  - clients/gui/apps/console/src/console.ts
  - clients/gui/apps/desktop/src/views/Publish.tsx
  - clients/gui/packages/client/src/artifacts.ts
  - clients/gui/docker/headers.conf
  - PROTOCOL.md
  - docs/user/artifacts.md
  - docs/admin/console.md
symbols:
  - Troupe.Plane.Artifacts.Shares
  - Troupe.Plane.Artifacts.Uploads
  - Troupe.Plane.Artifacts.Previews
  - Troupe.Plane.Artifacts.put/3
  - Troupe.Plane.Artifacts.rollback/4
  - Troupe.Plane.Artifacts.pin/4
gist: "Versions at one URL (put, rollback, owner's pin); a link gives view/edit to whoever the plane signs in through it, per person; public links only behind artifacts_public_links"
---

Issue #62's second slice, as the maintainer decided it on #765 on 2026-10-25: "versions at
one URL; links honouring plane sign-in with view or edit; no public links unless an admin
switches them on". It builds on Decision 948's store, protocol and origin and changes none of
them; it takes B44's follow-ups too (an upload handle, a failed publish's leftover objects,
the console's Open opening its tab at the click, and the desktop app's "Publish…").

## Versions

`artifact.put {id, files | upload, base?, note?}` is version n+1 at the same address, and so is
`artifact.publish` with an `id`, which is what `publish_artifact` sends with one: one door for
the tool, a client and the console. Without `base` the files sent are the whole version (what
a republish always was); with `base`, the version an edit was made on, the files not sent are
carried from it. A carried file is not copied: its row names the version whose object it is
(`stored_in`), and a rollback carries every file of the old version the same way. So the quota
counts stored bytes, not served ones, and a rollback costs nothing. A put on a `base` that is
no longer the newest is `conflict`, naming the newest: a second editor's version is never lost
under the first's without either knowing. `artifact.rollback` is a put of version n's files,
noted "rolled back to vn" and audited as `artifact.rollback` with `rolled_back_to`.

The address serves the newest version unless the owner pins one (`artifact.pin`, `null` to
unpin); a put while pinned keeps the pin, since the owner chose what readers see, and the
console says the address is pinned and to which. `current` beside `version` says which.

**Who.** The owner, and whoever holds an `edit` link, put and roll back; only the owner pins,
moves who it is for (`visibility`), makes and revokes links, switches its public links and
deletes it. A put by an editor is audited with `by: "edit link"`.

## Editing in the console

The console reads one text file of the newest version (`artifact.read`: UTF-8, at most a
mebibyte) into a text editor, and saves it with `artifact.put` on that `base`. The preview is
not drawn by the console, which never renders an artifact (Decision 948): `artifact.preview`
keeps the text for an hour (`artifact_previews`, in Postgres, swept at the next preview; no
object), and the artifacts host serves it at `/p/<nonce>/` over the base version's other
files, rendered as it renders a Markdown document and run as it runs a page, under the same
policy. The console frames that address in an iframe with `sandbox="allow-scripts"`. The nonce
in the path is the address's only key, so the frame needs no cookie, which a browser blocking
third-party cookies would withhold; whether its person may still put is read at every request.

The GUI image's policy gains `frame-src https:` for that frame, as `connect-src` already names
`https:` for hosts a deployment chooses at run time; the artifacts host's own `frame-ancestors`
still admits the plane's origin alone. That widens Decision 803's policy by one directive and
keeps everything else of it: a frame runs nothing on the plane's origin.

## Links

`artifact.share {id, role, expires?}` is `https://<artifacts host>/s/<token>`, 32 random bytes,
shown once; the plane keeps its SHA-256. It honours the plane's sign-in: opening it signs
nobody in. The artifacts host gives a viewer its own cookie names (Decision 948) the link's
role at once and opens the artifact; anybody else is sent to the console at
`#/artifacts/link/<token>`, which signs them in at the plane and spends the link there
(`artifact.redeem`), then goes on with a ticket as Open does. Spending it records the person
(`artifact_share_uses`, first and last use; audited the first time), and from then on they hold
its role on that artifact, which `role/2` reads with every other way of seeing it, at every
request on both hosts. They find it under "Shared with you".

**What it does not do.** It widens nothing for anybody who does not hold it: a role is a row
for a person, never for the link's other holders. It lasts as long as the link: an expired or
revoked link, or a revoked person, gives nothing, and the host and `artifact.redeem` answer as
for no link at all. It is one artifact's: an edit link is a put and a rollback, nothing an
owner does. Revoking a person revokes them from every link to that artifact, since "Bob no
longer holds this" means all of them.

Considered: a link that is itself a bearer, opening the artifact for whoever has it. That is
the public link below, and the maintainer ruled it out unless switched on. A link for picked
people chosen by name is the teams/people picker #62 still owes; a link covers that case now.

## Public links

`artifacts_public_links` (a boolean, off) under *Policy and settings*. On, the owner may make
`artifact.share {public: true}`: view only, `expires` mandatory and within 90 days, its
artifact served under `/s/<token>/` with no sign-in and no cookie, under the same sandboxed
policy. The owner's per-artifact switch (`artifact.public`, `artifacts.public_links`) stops
every one of its public links; the setting off stops all of them at once, and the gallery
marks an artifact one opens. Off, `artifact.share {public: true}` is `forbidden` with a
sentence naming the setting.

## The rest of B44's follow-ups

- **An upload handle.** `artifact.upload.begin {files: [{path, size}]}` answers a PUT URL per
  file, presigned for fifteen minutes into `artifact-uploads/<handle>/`, the handle the
  person's alone; a publish or a put names `upload` instead of `files`, and the plane reads
  each back, holds it to its announced size and the limits, writes the version and deletes the
  handle's objects. An unspent handle is swept, row and objects, at the next `begin` after it
  expired. The daemon uses it past about 2.5 MB of base64, so a laptop reaches the 16/64 MiB
  caps; a pod still sends inline over its control link (8 MiB), a follow-up.
- **Leftover objects.** A version the store refuses midway takes back the objects it put
  before the refusal, and one whose rows fail after its objects were put takes them back
  before the error goes on: a refused version leaves nothing under `artifacts/<id>/<n>/`.
- **Open at the click.** The console opens a blank tab in the click itself, cuts its `opener`,
  and points it at the ticket when the plane answers (or closes it on a refusal), so a popup
  blocker that refuses a tab opened after an `await` lets it through.
- **"Publish…" in the desktop app** is the palette's `/publish`: files from this computer, a
  new artifact or "Publish a new version of…" one of the person's own (the daemon's new
  `artifact.list`), with a note, and a link to the console's gallery.

Left: a path capability for the artifacts host's own cookie where a browser withholds it (the
preview and public links already need none); the pod's upload handle; teams and picked people;
comments.

## Proof

- `artifact_versions_test.exs`: a put is n+1 with note, who and when; on a base it carries
  files without copying them; a stale base is `conflict`; owner or edit link only; audited
  with the note; publish with an id is the same put, by an editor too, who may not move it; a
  rollback is n+1 audited as one; a pin holds over a later put and only the owner sets it; the
  editor's read; a preview served over its base, for whoever may put; an upload handle into
  MinIO, spent once, its objects gone, another's refused, a wrong size refused; a refused
  version leaves no object (a store refusal midway, and a quota).
- `artifact_shares_test.exs`: a link is the owner's, its token not kept; it gives its role to
  whoever spends it and nobody else; view cannot put and edit can, and nothing more; expired
  and revoked links refused and their roles gone; listed with its users, revoked by person,
  audited without the token; public refused while the setting is off, with a sentence naming
  it; on, expiry mandatory, view only, marked, stopped by the owner's switch and the setting.
- `artifact_links_host_test.exs`, over a socket: signed out, to the console with the link;
  signed in here, the role and the artifact; revoked, nothing; a public link served with no
  cookie under the policy while both switches are on; a preview rendered and under the policy.
- `publish_artifact_test.exs` (the tool sends `note`), `gateway/artifacts_test.exs` (a large
  version by an upload handle into MinIO; `artifact.list` through the daemon), the console's
  `artifact-versions.test.tsx`, the desktop app's `publish.test.tsx` and
  `content-security-policy.test.tsx`.

All of the plane's failed on the chunk's tip (`07415ab3`): there was no put, rollback, pin,
read, preview, upload handle, link or public link.
