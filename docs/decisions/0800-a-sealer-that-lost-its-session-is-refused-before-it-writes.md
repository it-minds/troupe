---
number: 800
title: A daemon sealing a private session names the epoch it holds in every write it asks the plane to sign, and the plane signs nothing for an epoch another device has claimed past, so a device that lost the session writes nothing more under its prefix
date: 2026-10-06
status: accepted
issue: 441
paths:
  - ARCHITECTURE.md
  - PROTOCOL.md
  - apps/troupe_gateway/lib/troupe/gateway/private.ex
  - apps/troupe_gateway/test/support/fake_plane.ex
  - apps/troupe_gateway/test/troupe/gateway/private_test.exs
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/test/troupe/plane/private_sessions_test.exs
  - apps/troupe_protocol/lib/troupe/sessions/sealer.ex
symbols:
  - Troupe.Gateway.Private.store/3
  - Troupe.Sessions.Sealer
gist: A sealing daemon names its epoch on every presigned write and the plane refuses a stale one, so a sealer that lost the session stops before writing.
---

Issue #441, found while fixing #433 (789). A seal uploads its segment, writes
`manifest.json` and then reports to the plane, and the report was the only place the
plane fenced a device that had lost a private session. So a sealer whose session another
device had claimed wrote one more segment and overwrote the manifest at its old epoch
before its report was refused, and a restore read that manifest, the loser's history,
until the holder sealed again. 789 named it under "Not in this". On the tip, with the
claim made in the middle of a seal through the plane stand-in, the old sealer wrote a
third version of `manifest.json` after the claim, or a segment at epoch 1 and the
manifest, after the holder had sealed its own.

- **The choice: the presign names the epoch.** A daemon holds no object-storage
  credential, so it cannot write a byte under a session's prefix without asking the plane
  to sign that one key first (`ObjectStore.Signed` signs each object just before it puts
  it, and keeps no URL). That request is the fence: `session.presign` takes `epoch`, the
  one the caller holds, and refuses one the row has moved past with `stale_version`,
  signing nothing. It costs no round trip, since every write already makes this one, and
  the plane compares the epoch with the row it already reads to check the session is the
  caller's. The segment, the manifest and a snapshot are each signed only while the
  device still holds the session.
- **Not reporting, or asking, first.** Reporting the seal before the upload undoes the
  sealer's upload-then-report order: a plane told of a segment storage does not have
  makes a rebuild claim history it cannot produce, and a crash between the two leaves
  exactly that. Asking first, a `session.register` with the epoch and no `last_seq`
  before the upload, adds a round trip to every seal and still leaves a seal's own length
  open: a claim between the segment and the manifest, the issue's case, overwrites the
  manifest, unless it asks again before every write, a round trip per object.
- **Not a conditional write.** An `If-Match` on the manifest's ETag fences the holder's
  next write, not its claim: a claim moves no object, so until the holder seals, the ETag
  the loser holds is still the current one and its write goes through. And the daemon
  would choose whether to send the header; the plane would enforce nothing.
- **Not a manifest named by its epoch.** Every reader of `manifest.json` knows its name
  (a pod's ghost check, the plane's index rebuild, `Storage.list_sessions/1`), and the
  loser would still write under the prefix, which is what the issue asks it not to do.
- **The plane.** `epoch` is optional and additive (protocol v1, and the plane's `/rpc` is
  not in the generated schema): named and not the row's, `stale_version` with the same
  data as a refused report, for whichever method; not an integer, `invalid_params`; not
  named, signed as before, which is what a restore, holding no epoch, and a daemon from
  before this send.
- **The daemon.** `Private.store/3` names the epoch of the row its sealer was started
  from on every `put`; reads are not fenced, and a restore's store (`store/2`) names
  none. A refusal is `{:error, :stale_version}`, and the session is listed `elsewhere`
  with one warning in the log, as at a refused report (`lost/1`, which both use).
- **The sealer.** A write `Storage` answers `{:error, :stale_version}`, the segment, the
  manifest or a snapshot, is the plane's fence, as a refused report is (789): it writes
  and reports nothing more, not even on its way down, stops with `{:shutdown,
  :stale_version}`, is not started again (`restart: :transient`), and `seal_now/2`
  answers `{:error, :stale_version}`. A seal whose manifest was refused makes no report,
  which the plane would refuse too. The report stays a fence, for a plane from before
  this, which signs whatever epoch it is named: there the loser still writes a segment
  and the manifest before it learns, as 789 left it. A pod's store and its cast reports
  answer neither, so a worker's sealer is unchanged.
- **What is left.** A write signed before the claim and sent after it: the plane cannot
  take back a URL. The daemon signs each object just before it puts it, so the window is
  one upload in flight when the claim lands. If that is the segment, it is at the old
  epoch from the row's `last_seq` on, where the holder seals too, at a higher epoch, which
  a restore's chain prefers (`Storage.live_segments/1`); if it is the manifest, the
  holder's next seal writes it back, as 789 said of every such overwrite, now narrowed
  from a seal to one PUT. A crash costs nothing new: nothing is reported earlier than
  before.
- **Proof:** the gateway's `private_test`, against the development MinIO and OpenBao with
  the plane stand-in, which now fences a presign as the plane does and can hold a request
  open (`FakePlane.before/3`). A laptop sealing its second event, with the desktop
  claiming the session and sealing its own second event while the plane is asked to sign
  the laptop's manifest, writes nothing more under the prefix (every version of every
  object the same as when the desktop had sealed), reports nothing more, stops with
  `{:shutdown, :stale_version}`, is not started again and is listed `elsewhere`; a restore
  reads the desktop's manifest (epoch 2, `last_seq` 2, its segment latest) and the
  desktop's history. The same with the claim made while the plane is asked to sign the
  laptop's second segment: no segment and no manifest. Both failed on the tip of
  `development-2026-10-06`, with a third version of the manifest, and with a segment at
  epoch 1 and the manifest. #433's test runs against a stand-in that signs any epoch, as a
  plane from before this does, and its report is still the fence. The plane's
  `private_sessions_test`: after a claim a `put` or a `get` naming the old epoch is
  refused `stale_version` for the manifest and a segment, the holder's epoch and a
  restore naming none are signed, and a non-integer epoch is `invalid_params`; it failed
  against the tip's `harness.ex`, which signed them. And the installed daemon, with
  scratch homes and the fake provider, through the client library, against a stand-in on
  loopback that fences a presign as the plane does, signs real assertions through the
  development OpenBao and real MinIO URLs: two private sessions sealed through their
  eleventh event; in the first, another device claimed the session as the daemon asked
  to sign the manifest of its second turn's seal, after the segment (events 12 to 20) was
  up, and wrote its own manifest at epoch 2; in the second, as the daemon asked to sign
  that seal's segment. Each request was refused `stale_version`, the daemon logged that
  it had stopped sealing, a third turn asked nothing, every version under each prefix was
  the same after as at the claim, the manifest read epoch 2, and both were listed
  `elsewhere`.
