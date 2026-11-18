---
number: 800
title: A daemon sealing a private session names the epoch it holds in every write it asks the plane to sign, and the plane signs nothing for an epoch another device has claimed past, so a device that lost the session writes nothing more under its prefix
date: 2026-10-06
status: accepted
issue: 441
paths:
  - apps/troupe_gateway/lib/troupe/gateway/private.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_protocol/lib/troupe/sessions/sealer.ex
symbols:
  - Troupe.Gateway.Private.store/3
  - Troupe.Sessions.Sealer
gist: A sealing daemon names its epoch on every presigned write and the plane refuses a stale one, so a sealer that lost the session stops before writing.
---

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
  :stale_version}`, is not started again (`restart: :transient`), and `seal_now/2` answers
  `{:error, :stale_version}`. A seal whose manifest was refused makes no report, which the
  plane would refuse too. The report stays a fence, for a plane from before this, which
  signs whatever epoch it is named: there the loser still writes a segment and the
  manifest before it learns, as 789 left it. A pod's store and its cast reports answer
  neither, so a worker's sealer is unchanged.
- **What is left.** A write signed before the claim and sent after it: the plane cannot
  take back a URL. The daemon signs each object just before it puts it, so the window is
  one upload in flight when the claim lands. If that is the segment, it is at the old
  epoch from the row's `last_seq` on, where the holder seals too, at a higher epoch, which
  a restore's chain prefers (`Storage.live_segments/1`); if it is the manifest, the
  holder's next seal writes it back, as 789 said of every such overwrite, now narrowed
  from a seal to one PUT. A crash costs nothing new: nothing is reported earlier than
  before.
