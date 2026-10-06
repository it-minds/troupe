---
number: 811
title: The plane destroys a team session's key itself, as it does a private one's; the session is `erasure_pending` and refused everything but a look and another erase until it has, a pod is recorded only once the key is gone, a pass every five minutes retries what the key manager refused, and the keys earlier erasures left are destroyed once on upgrade
date: 2026-10-07
status: accepted
issue: 470
supersedes: [90, 756]
paths:
  - ARCHITECTURE.md
  - PROTOCOL.md
  - apps/troupe_plane/lib/troupe/plane/erasure.ex
  - apps/troupe_plane/lib/troupe/plane/erasure/retry.ex
  - apps/troupe_plane/lib/troupe/plane/application.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/sessions.ex
  - apps/troupe_plane/lib/troupe/plane/sessions/tombstone.ex
  - apps/troupe_plane/priv/repo/migrations/20261006000811_tombstone_key_destroyed.exs
  - apps/troupe_plane/test/troupe/plane/private_erasure_test.exs
  - apps/troupe_worker/lib/troupe/worker/plane/commands.ex
  - apps/troupe_worker/test/troupe/worker/erasure_test.exs
  - docs/admin/backup-restore.md
  - docs/admin/monitoring.md
  - docs/admin/routine-tasks.md
symbols:
  - Troupe.Plane.Erasure.retry/0
  - Troupe.Plane.Erasure.Retry
gist: The plane, not a pod, destroys a team session's key; erasure_pending until it has, refused but for get/erase; 5-minute retry; old keys destroyed once
---

Issue #470; Decisions 90, 756 and 804. A team session's erasure was a pod's
(`session.erase` on the control channel), and the pod destroyed the key, deleted the
objects and answered carried out. When the destroy failed it logged it and answered
carried out all the same, with `key_destroyed: false`, and the plane recorded the pod in
the tombstone's `applied_by` and called the session `erased`. The issue read that as a
key manager being down now and then. It is every time: the credential an installation
gives a pod is `Troupe.KMS.Policy.worker/2`, create and read on its teams' keys and no
`delete` anywhere ("a pod must not be able to make a session unreadable, even its own",
which `open_bao_test.exs` asserts), so every pod answered 403 and every team session ever
erased kept its key. The worker's tests ran under the development root token, which may
delete, and never saw it. On the chunk's tip, with the pod holding the policy
installations give it, the erasure answered `erased: true`, recorded the pod, and left the
key; with a pod that says the key is still there, the plane called the session erased.

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
  which undoes that policy and needs every installation's policies rewritten. The key is
  named by the session's team, or, once the team is gone and the row's column with it
  (`on_delete: :nilify_all`), by the team the session's plaintext manifest names, which is
  there to say where the key is.
- **`erasure_pending` until it is gone.** The state 756 made for a private session, now
  for both: a key manager that refused or could not be reached leaves it, and the session
  is `erased` once the key is destroyed. Looked at (`session.get`, the listing) and erased
  again, which tries again, and nothing else: `visible/3` answers everything else
  `not_found` with `reason: "erased"`, opening, minting, forking, spawning and sharing, and
  `minted/3` refuses a link's redemption, which came there without a visibility check and
  so minted for an erased session as well; a pod's late report of a dormancy leaves it
  (`Sessions.dormant/2`, as for `read_only` and `erased`). A private session in this state
  is refused the same way, where before it was only refused sealing, keying and signing.
- **The pod at once, recorded after the key.** The plane still pushes `session.erase` the
  moment it is asked, whatever the key manager said, so a running session stops and the
  pod's copy and the objects go. The pod makes no key call any more, and its answer no
  longer carries `key_destroyed`, which nothing read; carried out still means every
  version gone (804). A pod is recorded in `applied_by` only once the key is gone: one that
  carried the erasure out while the key was still there is told again once it is, and finds
  nothing left. `pending_for/2` hands an enrolling pod a session whose key is still
  pending too, so its copy goes then, and `applied/2` records it only once the key has.
- **Retried every five minutes.** `Troupe.Plane.Erasure.Retry`, a `:global` singleton
  kept by a keeper on every replica as the scheduler is, runs `Erasure.retry/0`: every
  session whose key is not yet destroyed, private ones included, and once a key goes, a
  team session no pod has been recorded for is pushed to one. Five minutes because a key
  manager is down or refusing for minutes to hours, and a pass is one request per session
  still pending. A session's refusal is logged when it is erased, and the pass says only
  how many it destroyed and how many not, when that changes, so a key no pass can destroy
  is not said every five minutes for good. Before this a team session's erasure was tried
  again only when a pod of its profile next enrolled (D84's first item).
- **Once on upgrade.** A tombstone has `key_destroyed_at`, set when the plane destroys the
  key. Every tombstone written before this has it empty, so the pass destroys the key of
  every team session an earlier release erased, once, and a key already gone counts as
  destroyed; those it cannot destroy stay empty and are tried at every pass. The first
  pass runs as the singleton starts, which is the upgrade. Chosen over doing it in the
  migration, which runs in the chart's pre-upgrade job with no OpenBao credential, and
  would hold the upgrade on the key manager answering; and over a pass at every start with
  no record, which would send a request per erased session ever, every restart. Such a
  session stays `erased` while its key goes: only the key was left. One whose team and
  manifest are both gone cannot be named and stays counted as not destroyed.
- **Not in this:** a team session whose objects a store kept after the key went is still
  told again only at a pod's enrolment or a later erase (804), since a held object is held
  on purpose and asking every five minutes would only fill two logs; and a key the pass
  cannot name, its team deleted and its manifest erased, is left for an operator.
- **Proof:** the worker's `ErasureTest`, with each side holding the credential
  `Troupe.KMS.Policy` writes for it (the pod `worker/2`, the plane `plane/1`): the key and
  every version of the objects gone and the pod recorded, for a dormant session, a running
  one, a pod that enrolled later and a store that held an object; with the plane refused,
  the session `erasure_pending`, the pod told and unrecorded and the objects gone, and the
  next `retry/0` destroying the key and recording the pod; a key an earlier release left
  destroyed once, after a refused pass, and the next pass finding nothing; and a session
  whose team is gone found by its manifest. Seven of its eight failed on the tip (the
  pod's 403 left every key). The plane's `PrivateErasureTest`: a team session's key
  destroyed by the plane and its objects by a pod; with the key manager refusing, pending,
  listed and answered by `session.get`, erased again still pending, and refused
  `session.open` in both modes, `token.mint`, `session.fork`, `session.spawn`,
  `session.share` and the redemption of a link made before, a dormancy report refused, an
  enrolling pod not recorded, and the next pass finishing it; a pod that could not delete
  every object leaving the session erased and itself unrecorded; with no healthy pod, the
  key destroyed and the objects left for the next pod to enrol; and the singleton's first
  pass destroying a key an earlier release left and saying so. On the tip a pod that says
  the key is still there had the session called erased.
