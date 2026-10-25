---
number: 945
title: "An offer survives a reboot where the daemon starts at login, and says so where it does not: the listing's offer says whether it lasts across restarts or until this machine restarts and whether it came back after one, both clients say it in the same words and say the command once; a relayed approval offers only allow once and deny, since the laptop's rules are its own person's to loosen; the release keeps the versioned app archive alone, and the signing guide counts what a release signs"
date: 2026-10-25
status: accepted
issue: 58
paths:
  - apps/troupe_gateway/lib/troupe/gateway/remote.ex
  - apps/troupe_gateway/test/troupe/gateway/remote_test.exs
  - apps/troupe_core/lib/troupe/start_at_login.ex
  - clients/tui/lib/troupe/client/steering.ex
  - clients/tui/lib/troupe/client/remote.ex
  - clients/tui/lib/troupe/remote/worker.ex
  - clients/tui/lib/troupe/remote/capability.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/test/troupe/steer_command_test.exs
  - clients/gui/packages/client/src/fleet.ts
  - clients/gui/apps/desktop/src/views/Remote.tsx
  - clients/gui/apps/desktop/src/views/Approval.tsx
  - clients/gui/apps/console/src/views/Remote.tsx
  - .github/workflows/native.yml
  - apps/troupe_core/test/troupe/release/desktop_update_test.exs
  - docs/developer/code-signing.md
  - docs/developer/signing-day.md
  - docs/user/README.md
  - PROTOCOL.md
symbols:
  - Troupe.StartAtLogin.enabled?/1
  - Troupe.Client.Steering.state/1
  - Troupe.UI.TUI.Model.relayed?/1
gist: "Offer's lasts (across_restarts | until_restart) and restored in the listing, said alike by TUI and desktop, command said once; relayed approvals offer allow once and deny; only the versioned app archive ships"
---

#58's last two items, after slice 2 (Decision 928) and the console and presence (Decision
942), and two loose ends of the 0.26.0 release (D135).

## An offer and a restart

Decision 928 made the offer outlive its client: the daemon keeps its own sign-in in the
operating system's credential store and, restarted, reads it back and offers again what its
record holds, with no client at all. What it left is the machine restarting. Nothing starts
the daemon after a reboot unless the person turned start-at-login on (`troupe-daemon login
on`, Decision 762); until a client starts it, the offer is offline. So the two cases are
told apart, and said:

- **The listing says which.** The offer a session's listing carries (`remote` in
  `session.list` and `session.get`, and `remote.offer`'s answer) has `lasts`:
  `across_restarts` where the login entry is there, `until_restart` where it is not. It is
  asked at each listing (`Troupe.StartAtLogin.enabled?/1`, which reads the entry's files and
  does not look for the binary), so turning start-at-login on after the offer is what the
  next listing says. `restored` is true for an offer read back from `remote.json` as the
  daemon started, until it is offered again.
- **Said once, with the command.** The terminal's `/steer on` answer and the desktop app,
  as the offer is made, say one sentence where `lasts` is `until_restart`: *It stays offered
  until this machine restarts: troupe-daemon login on starts the daemon when you log in, and
  the offer comes back with it.* Asked again, `/steer` and the desktop's *Offered* pill say
  only the state.
- **In the same words.** The state is *online* (or *connecting to the plane*, *offline
  since …*), then *back after a restart* and *until this machine restarts* where they hold:
  `/steer` says *(online, back after a restart)*, the desktop's pill *Offered · Online ·
  back after a restart*.
- **The plane's half was already there.** A restarted daemon dials the relay as soon as its
  steering process starts and sends `relay.sync` with its whole record; the plane's
  `relay.offer` and `relay.sync` insert or update each row, so offering again is idempotent
  and nothing new was needed. The session is listed online again within seconds of the
  daemon starting.

**Not chosen: the daemon writing the login entry itself at the first offer.** It would
make every offer survive a reboot, but a login entry is the person's choice (Decision 762
asks it in Setup, and the installers offer it), and a daemon that adds itself to the login
items because a session was offered is the kind of thing a person finds later and did not
agree to. Saying so, with the command, leaves the choice where it was.

**Not done: the plane saying it.** `remote.list` on another device says nothing of
`lasts`: the laptop's word is in its own listing, where its person reads it. Carrying it in
`relay.offer` is a field more on the plane's row and the brief's "no new relay method
beyond what idempotent re-offer needs" leaves it out.

## A relayed approval offers what the laptop honours

Decision 921 decided it: *a remote person cannot loosen the laptop's rules*. An approval
answered from another device is `allow` or `deny` for that call, and `allow_session`, which
stops the session asking for the tool for the rest of it, is refused over the relay
(`Troupe.Protocol.Relay`) and is the laptop's person's to give at the laptop. Decision 928
repeats it for the terminal. Honouring it from somebody with `control`, recorded with who
allowed it, would undo that sentence, so the clients stop offering it instead:

- **The terminal** knows a session is a laptop's through the plane from the daemon's own
  `initialize` (`capabilities.relayed`), which the worker publishes (`relayed?`) and the
  model keeps (`Troupe.UI.TUI.Model.relayed?/1`). The approval line reads *(y allow once / n
  deny)*, the summaries *y / n*, the status line *y/n approve once*, and a delegation at the
  gate drops *a always for …*. Pressing `a` sends nothing and says why: *From another device
  a call is allowed or denied once: y allows it, n denies it. Allowing it for the rest of
  the session is done at the laptop.*
- **The desktop app** already left out the session-wide button on a relayed session; its
  allow button now reads *Allow once*, as the console's has since Decision 921.
- **The console's** steering view offers *Allow once* and *Deny*, unchanged.

## The release's loose ends

- **One app archive.** The macOS build leaves an unversioned `Troupe.app.tar.gz` of its own
  in `bundle/macos/`, which `Keep the installers` uploaded with every `*.app.tar.gz`, so
  releases carried it beside `Troupe_<version>_universal.app.tar.gz`, named in the manifest,
  in no `latest.json` and signed by nobody. The step that packs the updater's archive now
  removes any other archive first, and the upload names the versioned archive alone. The
  updater is unchanged: `latest.json` (`scripts/release-desktop-update.exs`) and the desktop
  app (`release.rs`) name `Troupe_<version>_universal.app.tar.gz` only.
- **The signature count.** `code-signing.md` §3 said a release signs about 85 Windows files.
  `sign-windows.ps1` leaves a file that already carries a valid signature as it is, and the
  Erlang runtime's own executables and libraries in both payloads are signed by Ericsson AB,
  so what a release signs is what the build makes itself: about three files in
  `troupe-daemon`'s payload, five in `troupe.exe`'s, the desktop app's executable and its
  installers. The cost paragraph follows from the count.

## Proof

- `apps/troupe_gateway/test/troupe/gateway/remote_test.exs` ("after a restart"): an offer on
  a daemon with no login entry says `until_restart` in its answer and its listing; with the
  entry, `across_restarts`, and a steering process started again with no client syncs the
  offer to the relay on the kept sign-in, with no new grant, and lists it online and
  `restored`. Both failed on the chunk's tip.
- `apps/troupe_core/test/troupe/start_at_login_test.exs`: `enabled?/1` beside `status/1`.
- `clients/tui/test/troupe/steer_command_test.exs`: the sentences, the command said once,
  *back after a restart*; and on a session whose daemon says `relayed`, the approval drawn
  *y allow once / n deny*, `a` refused in words with nothing sent, and `y` answering it.
- `clients/gui/apps/desktop/test/remote-sessions.test.tsx`: *Offered · Online · until this
  machine restarts* and the sentence as the offer is made, *back after a restart* from the
  listing after; a relayed approval's *Allow once* and no session-wide button.
- `apps/troupe_core/test/troupe/release/desktop_update_test.exs`: the pack step run on a
  bundle holding the build's own archive, the upload's globs taking the versioned archive
  and the disk image only, and a manifest over them naming no unversioned archive; it failed
  on the tip's workflow.
- The installed build, with scratch homes, against a stand-in plane: an offer, the daemon
  killed and started again with the login entry's command, the offer back online.
