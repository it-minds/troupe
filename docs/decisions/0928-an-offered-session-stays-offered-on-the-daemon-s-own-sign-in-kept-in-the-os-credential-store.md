---
number: 928
title: "While a session is offered, the daemon keeps a sign-in of its own: a grant the plane gives the device at the first offer, asked with the client's token, kept in the OS credential store and exchanged for a token of the laptop's door alone; the last withdrawal, a sign-out or troupe logout releases it, the idle watch stays up for it, the TUI steers what is offered to its person, and a team's admins may forbid offering"
date: 2026-10-23
status: accepted
issue: 58
paths:
  - apps/troupe_protocol/lib/troupe/keyring.ex
  - apps/troupe_protocol/lib/troupe/keyring/*.ex
  - apps/troupe_core/lib/troupe/keyring/steering.ex
  - apps/troupe_gateway/lib/troupe/gateway/remote.ex
  - apps/troupe_gateway/lib/troupe/gateway/idle.ex
  - apps/troupe_gateway/lib/troupe/gateway/presence.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_plane/lib/troupe/plane/remote.ex
  - apps/troupe_plane/lib/troupe/plane/remote/*.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/web/router.ex
  - apps/troupe_plane/lib/troupe/plane/identity/team.ex
  - apps/troupe_plane/priv/repo/migrations/20261023000928_remote_grants.exs
  - clients/tui/lib/troupe/client/remote.ex
  - clients/tui/lib/troupe/remote/worker.ex
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/lib/troupe/ui/hq.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/cli/remote.ex
  - clients/gui/apps/console/src/views/Team.tsx
  - PROTOCOL.md
symbols:
  - Troupe.Keyring
  - Troupe.Keyring.Steering
  - Troupe.Plane.Remote.Grant
gist: "Offers ride the daemon's own grant, kept in the OS keyring and swapped at /auth/relay for a laptop-door token; last withdraw or sign-out drops it"
---

#58, slice 2. Slice 1 (Decision 921) dialled the relay with the plane token a client had
handed the daemon (Decision 764): fifteen minutes, renewed only while that client ran, so an
offered session went offline when the terminal or the desktop app closed, which is when
steering it from elsewhere matters. The maintainer decided on 2026-10-23 that the daemon
keeps its own sign-in while a session is offered: in the operating system's credential
store, owner-only, renewed for as long as anything is offered, and dropped by withdrawing the
last offer, by signing out and by `troupe logout`. The rest of the slice is the TUI steering
what is offered to its person, a team switch that forbids offering, and the idle watch
counting the relay.

## How the daemon gets its sign-in

**A grant the plane gives the device, asked with the client's token.** At the first offer
the daemon calls the plane's `remote.grant {device}` with the token the signed-in client
handed it, so the plane is told, in its own words, that this is the daemon of that person on
that device asking for itself. It answers `rg_<id>.<secret>`; the plane keeps the secret's
hash in `remote_grants`, one row per person and device (a new grant replaces the last), and
writes `remote.grant` to the audit trail with the device. The grant is not the client's
refresh token: an identity provider's refresh token rotates, and two holders of one would
spend it twice; and it is not a token `/rpc` takes.

**Exchanged for the laptop's door alone.** `POST /auth/relay {grant}` answers a fifteen-
minute token with the audience `troupe-relay-laptop` and the device in it. `/v1/relay` takes
it for that device; `/rpc`, a pod and a viewer's door do not. So a grant read out of the
store opens one thing: this laptop's connection to the relay, as this person. The daemon
exchanges it again two minutes before the token ends (or at the plane's `auth.expiring`)
and renews on the open socket with `auth.refresh`, as a client's token was renewed; a
dropped connection exchanges it again to dial. 401 (a grant released, unknown or unused for
thirty days) ends the sign-in, and the next link with a token asks for a new one; 403 (the
person deactivated, or a team forbidding offering) ends it and is not asked again on a timer.

**Not rotated.** A grant is the same until it is released. Rotating it at every exchange
would catch a copy used twice, but a laptop whose answer was lost on the way would hold a
grant the plane had already spent, and go offline for good at a network blip. The copy can
be made only by somebody who can read this person's credential store on this machine, and
it opens only the door above.

## Where it is kept

**The operating system's credential store** (`Troupe.Keyring`): Credential Manager on
Windows, a generic credential persisted on the machine, through `CredWriteW`/`CredReadW`
from Windows PowerShell; the login keychain on a Mac, through `security -i`; the Secret
Service through `secret-tool` elsewhere. The secret never goes on a command line, which
other users can read: it reaches the tool in the child's own environment and from there a
pipe. Decision 741 kept the person's MCP sign-ins in an owner-only file because the daemon
had no keychain; this is the daemon's first, kept small (three platform tools behind one
module) because only this one entry needs it so far. A machine with no store (no
`secret-tool`, no agent, a policy that forbids the PowerShell) keeps the grant in memory and
logs that it did: the offer then lasts as long as the daemon runs, and never a file.

**One entry per state directory**, `<service>/steering-<hash of the state directory>`
(`Troupe.Keyring.Steering`), so a daemon with homes of its own (a test, a scratch install)
keeps a sign-in of its own; the service is `troupe`, or `TROUPE_KEYRING_SERVICE`, which a
test and the installed check set. The value is the plane, the person and the grant, as
base64 of JSON. The tests use `Troupe.Keyring.Memory`; `Troupe.KeyringTest` asks the real
store under a test service.

## What drops it

- **The last withdrawal** (`remote.withdraw`, or erasing the last offered session): the
  plane is told `relay.withdraw` and answers before the connection closes, then the grant is
  released (`POST /auth/relay/release`, audited as `remote.release`), taken out of the store
  and the connection closed.
- **Signing out** (`identity.sign_out` naming that plane and person, which the desktop app's
  *Sign out* and `troupe logout` send) and **unlinking** (`identity.unlink`, or a link naming
  another person): the same. The offers stay in `remote.json`, offline, and the next link
  with a token asks for a new grant and offers them again, as slice 1 kept the record.
- **`troupe logout` with no daemon running** takes the entry out of the store itself
  (`Troupe.Keyring.Steering.forget/3`, where it is for that plane and person) and releases
  it at the plane, so a daemon started later does not offer again for somebody who signed
  out.

**What does not drop it**: the client closing; its fifteen-minute token running out
unrenewed; the plane's socket dropping; the daemon restarting, which reads the grant back
and dials with no client at all.

The brief for this slice also said the offer stays online across "the client's sign-out".
The maintainer's decision lists signing out among what drops it, and that is what this does:
what the offer outlives is the client's sign-in lapsing, not the person signing out.

## The idle watch counts the relay

`Troupe.Gateway.Idle.busy?/0` is also true while `Remote.offering?/0`: something offered and
the daemon's own sign-in to keep it offered, read from the offers table so the watch never
waits on the steering process. A remote person steering was already a connection. Withdrawn,
or signed out, the daemon stops at its quiet period as before. A daemon is started by a
client; one stopped by hand, or a machine restarted, is offline until something starts it.

## Steering from the TUI

- **Listed beside the plane's sessions.** `Troupe.Client.Remote.sessions/2` adds the plane's
  `remote.list` as rows of kind `remote` (*Ada's laptop · project*, `online` or `offline
  since`), which HQ (`/remote`) shows as `laptop` rows. A plane without `remote.list` adds
  none.
- **Opened through the relay** exactly as the desktop app attaches: `remote.open`, then the
  same `Troupe.Remote.Worker` a daemon session uses, at the relay's address with the token it
  minted; a dropped view asks `remote.open` again where it went, and `auth.expiring` is
  answered with the next `remote.open` token on the open socket. Follow, prompt, approve,
  cancel and switch agent are the client's ordinary commands, and the laptop holds them to
  Decision 921's table: an approval from elsewhere is once (`allow_session` is refused there,
  with its sentence).
- **Presence is drawn, not dropped.** Every window subscribes to its session's
  `presence:<id>` topic after its own, so its own arrival is not news; `joined` and `left`
  are lines in the session's window (*Bea joined from another device*), and the status line
  names whoever is there now (*with Bea (another device)*). The daemon's presence carries
  `via: "plane"` for a person attached through the relay, which is how a client tells them
  from somebody at the laptop.

## A team's administrators may forbid offering

`teams.remote_offering_allowed`, true by default, set in the console's team page under
Limits (*Members may offer a laptop session for steering*), previewed in words, applied on
confirm and recorded as `team.update` with the change, like the team's other switches; it is
the team's own administrators' to set, and `admin.team.update` takes it. The plane reads it
at offer time: `remote.grant`, `relay.offer`, `relay.sync` and the grant's exchange refuse a
person in a team that does not allow it, `forbidden` with `data.team` and *eng's
administrators do not allow offering a laptop session for steering from another device*;
`remote.open` refuses an offer made before the switch. A person in several teams may offer
only where every one allows it, the strictest holding as everywhere else. The daemon passes
the plane's refusal through to the client as it came, so `/steer on` says it.

## Proof

- `apps/troupe_plane/test/troupe/plane/remote_test.exs`: a grant asked with the person's
  token exchanged for the laptop's door alone, for its device, renewed on the open socket,
  refused at `/rpc`, a viewer's door and another device's, audited without the secret; a
  released, forged, deactivated person's grant refused, a second grant replacing the first;
  the team switch refusing a grant, an offer and an attach by name, audited, and a grant made
  before it refused at its next exchange.
- `apps/troupe_gateway/test/troupe/gateway/remote_test.exs`, against `FakePlane` and
  `FakeRelay`: the first offer asking for a grant of its own, keeping it in the store and in
  no file, and dialling with the laptop token; the offer steerable after its client closed;
  a restarted daemon online from the store with no client and no new grant; the last
  withdrawal and a sign-out releasing it, emptying the store and closing the relay, the
  record kept and offered again at the next link; a team's refusal passed through; renewal
  before expiry and at the plane's warning; the idle watch busy for an offer with nothing
  attached and not after its withdrawal.
- `apps/troupe_protocol/test/troupe/keyring_test.exs`, `apps/troupe_core/test/troupe/keyring_steering_test.exs`.
- `clients/tui/test/troupe/remote_steering_test.exs`: the offered rows beside the plane's,
  one opened through `remote.open` and prompted, approved once, cancelled, switched and
  reopened after a drop; presence drawn as joined and left and named on the status line.
- `clients/gui/apps/console/test/teams.test.tsx`: the switch previewed, applied and audited.
