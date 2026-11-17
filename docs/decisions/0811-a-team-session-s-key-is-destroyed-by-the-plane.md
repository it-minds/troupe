---
number: 811
title: The plane destroys a team session's key itself, as it does a private one's; the session is `erasure_pending` and refused everything but a look and another erase until it has, a pod is recorded only once the key is gone, a pass every five minutes retries what the key manager refused, and the keys earlier erasures left are destroyed once on upgrade
date: 2026-10-07
status: accepted
issue: 470
supersedes: [90, 756]
paths:
  - apps/troupe_plane/lib/troupe/plane/erasure.ex
  - apps/troupe_plane/lib/troupe/plane/erasure/retry.ex
  - apps/troupe_plane/lib/troupe/plane/application.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/sessions.ex
  - apps/troupe_plane/lib/troupe/plane/sessions/tombstone.ex
  - apps/troupe_plane/priv/repo/migrations/20261006000811_tombstone_key_destroyed.exs
  - apps/troupe_worker/lib/troupe/worker/plane/commands.ex
symbols:
  - Troupe.Plane.Erasure.retry/0
  - Troupe.Plane.Erasure.Retry
gist: The plane, not a pod, destroys a team session's key; erasure_pending until it has, refused but for get/erase; 5-minute retry; old keys destroyed once
---

- **The key, by the plane.** `Erasure` destroys a team session's key as it does a private
  one's (756), at once and with its own credential, whose policy
  (`Troupe.KMS.Policy.plane/1`) has `delete` on `metadata/troupe/teams/+/sessions/*` and
  nothing on the data path, and was written with both subtrees for exactly this ("erasure
  is erasure"). This revises 90's first sentence for a team session and 756's "a team
  session is unchanged ... its key is never the plane's to touch", and keeps 90's reason:
  the plane can destroy a key and read none, and a pod still cannot destroy one, so a pod
  cannot make a session unreadable by being wrong. The alternatives were the slot as
  written (the pod answers not done unless its destroy succeeded), which under the
  installed policies leaves every team erasure pending for good, and giving pods `delete`,
  which undoes that policy and needs every installation's policies rewritten.
- **`erasure_pending` until it is gone.** The state 756 made for a private session, now
  for both: a key manager that refused or could not be reached leaves it, and the session
  is `erased` once the key is destroyed. Looked at (`session.get`, the listing) and erased
  again, which tries again, and nothing else: `visible/3` answers everything else
  `not_found` with `reason: "erased"`, opening, minting, forking, spawning and sharing,
  and `minted/3` refuses a link's redemption, which came there without a visibility check
  and so minted for an erased session as well; a pod's late report of a dormancy leaves it
  (`Sessions.dormant/2`, as for `read_only` and `erased`).
- **The pod at once, recorded after the key.** The plane still pushes `session.erase` the
  moment it is asked, whatever the key manager said, so a running session stops and the
  pod's copy and the objects go. The pod makes no key call any more, and its answer no
  longer carries `key_destroyed`, which nothing read; carried out still means every
  version gone (804). A pod is recorded in `applied_by` only once the key is gone: one that
  carried the erasure out while the key was still there is told again once it is, and finds
  nothing left. `pending_for/2` hands an enrolling pod a session whose key is still
  pending too, so its copy goes then, and `applied/2` records it only once the key has.
- **Retried every five minutes.** `Troupe.Plane.Erasure.Retry`, a `:global` singleton kept
  by a keeper on every replica as the scheduler is, runs `Erasure.retry/0`: every session
  whose key is not yet destroyed, private ones included, and once a key goes, a team
  session no pod has been recorded for is pushed to one.
- **Once on upgrade.** A tombstone has `key_destroyed_at`, set when the plane destroys the
  key. Every tombstone written before this has it empty, so the pass destroys the key of
  every team session an earlier release erased, once, and a key already gone counts as
  destroyed; those it cannot destroy stay empty and are tried at every pass. Chosen over
  doing it in the migration, which runs in the chart's pre-upgrade job with no OpenBao
  credential, and would hold the upgrade on the key manager answering; and over a pass at
  every start with no record, which would send a request per erased session ever, every
  restart.
