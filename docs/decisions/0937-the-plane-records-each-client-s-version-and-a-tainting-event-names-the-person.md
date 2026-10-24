---
number: 937
title: "The plane records, per person and component, the version, platform and times of the client it last served at initialize, one row moved on and never a history, and an administrator reads it beside the policy; the credential stores are exercised on a real macOS keychain and Secret Service in CI, the daemon keeping a value too long for one `security -i` line in parts; session_tainted carries the person's display name beside their subject; and the desktop app asks again about a server signed in to while attached and offers only the servers ticked"
date: 2026-10-24
status: accepted
issue: 657
paths:
  - apps/troupe_plane/lib/troupe/plane/clients_seen.ex
  - apps/troupe_plane/priv/repo/migrations/20261024000937_clients_seen.exs
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/test/troupe/plane/client_versions_test.exs
  - apps/troupe_gateway/lib/troupe/gateway/plane.ex
  - clients/gui/apps/console/src/views/ClientVersions.tsx
  - clients/gui/apps/console/src/views/Overview.tsx
  - clients/gui/packages/client/src/admin.ts
  - apps/troupe_protocol/lib/troupe/keyring/os.ex
  - apps/troupe_protocol/test/troupe/keyring_test.exs
  - clients/gui/apps/desktop/src-tauri/src/secrets.rs
  - .github/workflows/keyring.yml
  - apps/troupe_core/lib/troupe/session/client_tools.ex
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/gui/packages/client/src/transcript.ts
  - clients/gui/packages/client/src/offer.ts
  - clients/gui/apps/desktop/src/views/Offer.tsx
  - clients/gui/apps/desktop/src/hooks.ts
  - PROTOCOL.md
symbols:
  - Troupe.Plane.ClientsSeen
gist: "clients_seen: one row per (person, component) at a served initialize, no history; keyring CI on real stores, mac parts past one line; taint has display_name; offer re-asks, per server"
---

The last part of #657, the loose ends of the 0.24 seam that the Stage 1 gate walks (#765),
D133's credential-store item and D50's first edge.

## The plane records each client's version

A policy (Decision 868) was set blind: nothing said how many clients a raised minimum
would turn away, or who was behind. The plane already reads each client's component and
version at `initialize`; now it keeps them.

- **One row per person and component, never a history.** `clients_seen` is keyed by the
  person's row (`user_id`, so a subject rekeyed under Decision 751 keeps it, a person
  folded into another takes theirs away, and a removed person's go with them) and the
  component. It holds the version, the platform where `client_info` names one, when that
  version was first seen (`since`, which moves only with the version) and when the client
  was last seen. "Who is behind" is a question about now; a history would be a table
  nobody reads that grows with every daemon's thirty-second handshake (Decision 931).
- **Recorded only for a client the plane served.** One refused with `update_required` is
  not written: its row stays as it last was, which `standing` then counts as refused. One
  the plane cannot place, and a service principal (no row), are not recorded. A database
  that cannot be written is logged and the client served all the same.
- **Cheap at thirty seconds.** One upsert whose update is skipped when the version and the
  platform are unchanged and `seen_at` is under five minutes old, so most handshakes write
  nothing. `seen_at` is right to within those five minutes.
- **Read beside the policy.** `admin.clients.get` answers `fleet` per component: how many
  are `current`, `behind` the recommended version, and `refused` (below the minimum or
  blocked, judged by `ClientUpdate.judge` against the policy as it is now), and the people
  with their `standing`. A team admin's is their visible teams' members, a platform
  admin's everybody's. `admin.clients.put` answers and audits `affected`, the same counts
  against the new policy. The console's Client versions page shows a count line per
  component and a filterable list of who is behind, oldest first; the Overview says
  "n clients behind the recommended version" among what needs attention when n > 0.
- **Nothing new for a person.** `initialize`'s answer is as it was; no protocol method is
  added. The daemon now sends `client_info.platform` (`<os>/<arch>`); a label of at most 64
  printable characters, and anything else is dropped.

## The credential stores, on CI

`Troupe.Keyring.OS` had been exercised on Windows only; Linux CI checked the "store
unavailable" answer and nothing ran `security` or `secret-tool` (D133).

- **A workflow of its own.** `keyring.yml`, called by `ci.yml` and by `dev-check.yml` (as
  the cluster suite is, since a fixer's Windows machine has neither store) when the code
  that keeps a secret in one changes, and in a full run: the protocol's keyring test on a
  `macos-14` runner against a keychain the job makes, unlocks and sets as default, and on
  Linux against `gnome-keyring` on a session bus of the step's own, with an empty-password
  login keyring; and the desktop crate's `secrets.rs` tests on the Mac. A value stored,
  read, replaced, four kilobytes of it whole, and deleted with every part.
- **Skipped where there is no store, failed where there should be one.** Both tests print
  `SKIPPED` and pass on a machine with no store; the jobs set `TROUPE_KEYRING_REQUIRE=1`,
  so a store that did not come up fails them rather than passing green with nothing run.
- **macOS: parts past one command line.** `security -i` reads each command as one line of
  at most 4096 bytes, so a value whose `add-generic-password` line would be longer is
  kept in parts in Decision 935's layout (`<entry>/0..n-1`, `<entry>` = `troupe-parts:<n>`,
  2048 bytes a part, never inside a character). This narrows 935's "elsewhere a value is
  one entry" for the daemon on macOS; a value that fits is still one entry, and the
  desktop app's keyring crate, which calls the keychain directly, keeps one entry there.
  Linux's `secret-tool` takes the value on standard input and has no such limit.

## A tainting event names the person

`session_tainted`'s `actor` is the identity's subject (`subject_of/1`). On a plane whose
subject claim is opaque that is an identifier, so "names the person" failed (A41's walk).

- **Both, not instead.** The event keeps `actor` (the subject, which says who to the
  system and which earlier clients print) and gains `display_name`, the actor's name as
  the sign-in gave it: on a pod the session token's `name`, on a laptop the daemon's from
  `me`. Absent where there is none.
- **The sentence.** The terminal and the desktop app say "<name> offered tools that run
  on their own machine: …", the subject where the event has no name, "somebody" where it
  has neither.

## The desktop app's offer, per server and on sign-in

D50's first edge: a person's servers were offered once per attachment, all or none, and a
server signed in to while attached waited for the next attachment.

- **Asked again on a new server.** `ServerOffer.refresh` lists the servers and, when one
  signed in has not been asked about in this attachment, asks again over the socket it
  offered last. The desktop calls it when the window comes back to the front, where a
  person returns from the browser that signed them in, and every thirty seconds for one
  signed in from the terminal. A list call, no registration, when nothing is new.
- **Per server, all by default.** The question lists every signed-in server, each a box:
  ticked, except one the person left out before in this attachment. Only the ticked
  servers' tools are registered; where that is fewer than the session asked about, a
  fresh challenge for those alone is spent, so a consent covers exactly what is offered.
  A server unticked on a later question has its tools taken back (`tools.unregister` with
  their names, which the gateway already takes). "Not now" changes nothing already
  offered and leaves the new servers out; nobody is asked again until another server is
  signed in to. At the first question it leaves every server out, as before.
- **The rest as it was.** A socket that comes back registers what the person chose
  without asking; a different set of tools from the same servers is asked about again; a
  session that takes no person's tools refuses for the attachment (Decision 879).

## Proof

`ClientVersionsTest`: a served `initialize` records the version and platform, one row a
component, moved on by a newer one; a refused client, an unplaced one and a bare
`initialize` record nothing; `admin.clients.get` counts current, behind and refused and
lists the people, a team admin only their team's; `admin.clients.put` answers and audits
`affected`; a removed person's rows go. The console's tests: the count line, the list
oldest first with its filter, a team admin's own people, the note after applying, and the
Overview's line and its absence. `ClientToolsTest`, the TUI's `RemoteTranslateTest` and
the client's transcript test: the name in the event and in the sentence, the subject
without it. The client's own-servers tests: a server signed in to while attached is asked
about with what was offered ticked, a picked subset alone is registered and stays so on
the next socket, an unticked server is taken back; the desktop's: the boxes, the button
naming what is ticked, the focus that asks again. The keyring jobs on this change's pull
request.
