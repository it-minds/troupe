---
number: 694
title: A session that leaves its pod for good gives back its slot and its budget slice, each once, however it left
date: 2026-09-26
status: accepted
issue: 190
paths:
  - apps/troupe_plane/lib/troupe/plane/placement.ex
  - apps/troupe_plane/test/troupe/plane/grant_enforcement_test.exs
gist: A session that leaves its pod for good gives back its slot and its budget slice, each once, however it left
---

Issue #190, D22 in docs/developer/defects.md, found
by the fixer of #173. A pod's dormancy report gives back both. Three other endings
gave back less, and a budget slice left open is held for good, because every rung
reloads the ledger's open reservations. A slot came back at the next refused
reserve (Decision 690); a slice never did.
- **A revoked grant.** `Identity.revoke/2` froze the team's sessions on the profile
  with one `Sessions.read_only_for/2`, which clears `worker_id` and gives back
  nothing. It now takes each running one off its pod first, then freezes the rest.
- **An erasure.** It gave back the slot but not the slice. The pod's `session.erase`
  fences the session and throws it away without reporting it dormant.
- **A dormant session its pod will not take back.** Waking it reserves the slice
  again before `session.activate` is pushed, and a refusal left the slice held. The
  pod does report `workspace_gone` as `session.unrestorable`, which releases, but
  only when that report arrives.
- **`Drain.park/1`** is `Drain.strand/2` for a session that is not going back to
  any pod: the slot first, then the row read-only, then the slice at every rung.
  Erasure, a revoked grant and a `workspace_gone` refusal park; any other refusal
  strands, so the session is dormant again and holds nothing.
- **Once.** A second release finds nothing. `Placement.release/2` counts again, as
  Decision 690 says, and a budget release is by session. So when a pod that went on
  running a revoked session reports it dormant later, nothing goes back twice.
- **Since Decision 697** a revoked grant also puts the session to sleep on its pod,
  leaves the row read-only when the pod reports it, and parks the team's sessions
  still waiting for room.
- **Proof:** `Troupe.Plane.BudgetLadderTest`: revoking the grant of, or erasing, a
  running session leaves nothing held by the team, the person, the ledger or the
  pod. `Troupe.Plane.HarnessTest`: a pod that will not take back a dormant session,
  with `workspace_gone` or without, leaves no slice held. `Troupe.Plane.ControlTest`:
  a revoked session's pod reporting it dormant twice gives back one slot. All five
  fail on the chunk's tip.
