---
number: 785
title: A daemon's `session.list` says a private session is private and how its sealing stands here, and `session.claim` takes one another device sealed last over on this one, where this copy holds what the plane has
date: 2026-10-05
status: accepted
paths:
  - PROTOCOL.md
  - apps/troupe_gateway/lib/troupe/gateway/private.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_worker/test/troupe/worker/auth_test.exs
  - clients/gui/apps/desktop/src/App.tsx
  - clients/gui/apps/desktop/src/views/bits.tsx
  - clients/gui/apps/desktop/test/private-sessions.test.tsx
  - clients/gui/packages/client/src/daemon.ts
  - clients/gui/packages/client/src/fleet.ts
  - clients/gui/packages/client/test/support/daemon.ts
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/test/support/fake_remote.ex
  - clients/tui/test/troupe/private_sessions_test.exs
gist: A daemon's `session.list` says a private session is private and how its sealing stands here, and `session.claim` takes one another device sealed…
---

D61's first two items and D59's
second, following 756, 764 and 766. The daemon's rows carried no `kind`, so the
desktop app listed a private session as a local one, and nothing reached
`Private.claim/3`: a session another device sealed last, which 764's `resume` leaves
to it, stayed that device's, a renamed machine's own included. A plane's
`erasure_pending` row read as dormant in the TUI and as a team session in the
desktop app.
- **What a row says.** `kind` (`local`, `private`, a pod's `team`), and for a private
  session `sync` and `device` (`Private.sync/1`): `current`, a sealer with nothing
  pending; `behind`, one with events pending, or one that does not answer a status
  within 250 ms because it is uploading; `paused`, no sealer: no token since the
  daemon started or the person signed out, no plane, or the session archived;
  `elsewhere`, the row named another device at the last link's `resume`, or a seal
  was refused `stale_version`, with `device` naming it where the plane did;
  `erasure_pending`, the row said so at the last link. Five where the slot named
  four, because not sealing and sealing behind ask different things of the person:
  the one waits for a sign-in, the other for a moment. What the plane said is kept in
  an ETS table the sealers' supervisor owns, and forgotten when a sealer starts or the
  session is erased here. A listing never asks the plane: the desktop app lists every
  four seconds, and a laptop is offline most of the time it is on.
- **`session.claim {session_id}`, `admin`.** Where a session lives is the person's
  say, as archiving and erasing it are. `Private.take_over/2` reads the row
  (`session.get`); one that names this device is carried on, a sealer started if none
  runs, and not claimed again, so a second claim moves nothing; another device's is
  claimed with the row's `epoch` through `claim/3`, a sealer still here that lost is
  stopped, and the session is sealed from the row's `last_seq` at the new epoch, as
  `resume` seals this device's. The answer is the row's `device` and `epoch` and the
  `sync`. Refusals: `not_found` with `erased` or `not_registered`, `stale_version`
  where another device claimed first, `unavailable` with `unlinked`, `invalid_params`
  for a session that is not private. A pod has no private session; a token for one
  session is refused it as not about that session.
- **Only the same history.** The event at the row's `last_seq` must be in this log
  with the row's `head_hash`, the `Event.hash` a seal reports of its last event; if
  not, `conflict` with `reason: "diverged"`, and nothing changes. The slot did not
  say this. Without it a claim on a machine whose copy the other device sealed past
  would seal this copy's later events after the other's, two histories under one
  prefix that no restore reads back. Restoring the plane's copy over this one first
  is what would let such a claim through; it is not done here.
- **The clients.** `@troupe/client`: `SyncState` is the five, and `syncState/1`
  reads one and says null of a value it does not know; `syncWords/2` gives the label
  and the sentence ("Synced", "Syncing", "Not syncing", "On <device>", "Waiting to be
  erased"), which the TUI says too; `claimable/1`, `DaemonClient.claimSession/1` and
  `claimRefusal/1`; `rowFromPlane` reads a plane's `kind`, where it said `team` of
  every row, and its `erasure_pending` as that sync, and the merge keeps a plane's
  `erasure_pending` over the daemon's sync, which hears of it only at its next link.
  The old `SyncState` (`synced`, `pending`, `conflict`, `this-device-only`) was never
  sent by anything and goes. The desktop list says the sync in those words with the
  sentence on hover, offers Claim beside a row another device holds (beside, since
  the row is a button), says a refusal in a banner, and shows no status on a row
  waiting to be erased, whose sync says it. The TUI: its Decision 146.
- **Not in this:** the session view's header, which still says only where a session
  runs; a sealer refused `stale_version` keeps running until its session stops (it
  is listed `elsewhere` meanwhile); a claim on a copy that diverged; D61's third item.
- **Proof:** the gateway's `private_test.exs` against MinIO and OpenBao, with the
  plane stand-in: through the daemon, `session.list` and `session.get` say
  `kind: "private"`, `sync: "paused"` of a private session nobody linked and
  `kind: "local"` of a local one; one whose row names another device is listed
  `elsewhere` with that device after a link, and `session.claim` makes the row this
  device's at the next epoch, answers the same to the same `command_id`, moves
  nothing on a second claim, and refuses a local session; one whose row is
  `erasure_pending` is listed so and not claimed; `take_over/2` seals a session
  another device took from the row's `last_seq` at the new epoch, its events after it
  in a second segment, and is `current` once sealed; and refuses with `diverged` where
  the row's `last_seq` is past this copy or its event is another. All five failed on
  the tip of `development-2026-10-05-2`. `@troupe/client`'s `fleet.test.ts` (a
  daemon's private row with each sync, an unknown one as null, the words, a plane's
  private and `erasure_pending` rows, the merge), the desktop app's
  `private-sessions.test.tsx` against the fake daemon (Private and the sync in words
  in the list, Claim only beside the row another device holds, the claim sent and the
  row synced after, a refusal said), and the TUI's `private_sessions_test.exs`,
  all failing on the tip. And the installed daemon, `troupe` and the desktop app's
  web build, with scratch homes, linked to a plane stand-in on loopback that keeps
  rows and signs nothing: `session.list` said `elsewhere` with the other device's
  name, `erasure_pending`, `paused` and a local session as such; the list showed
  Private with each, and Claim beside the one another device held; Claim made the
  stand-in's row this machine's at the next epoch and the row `paused`; and the
  installed `troupe resume` picker said `[private · on …]`, `c claims it here`, and
  `waiting to be erased`.
