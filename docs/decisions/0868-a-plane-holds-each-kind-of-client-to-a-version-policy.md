---
number: 868
title: "A plane holds each kind of client to a version policy (recommended, minimum, blocked) kept in its database; its initialize over /rpc refuses a client below the minimum or on a blocked version with update_required, and troupe update installs the plane's recommended version, never a blocked one or one below the minimum, and moves back only when the person names the version"
date: 2026-10-11
status: accepted
issue: 66
paths:
  - apps/troupe_plane/lib/troupe/plane/client_versions.ex
  - apps/troupe_plane/priv/repo/migrations/20261011000868_client_versions.exs
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/web/live/policy.ex
  - apps/troupe_protocol/lib/troupe/protocol/client_update.ex
  - apps/troupe_gateway/lib/troupe/gateway/plane.ex
  - apps/troupe_core/lib/troupe/update.ex
  - clients/tui/lib/troupe/remote/plane.ex
  - clients/tui/lib/troupe/cli/remote.ex
  - docs/user/updating.md
symbols:
  - Troupe.Plane.ClientVersions
  - Troupe.Protocol.ClientUpdate
  - Troupe.Gateway.Plane.handshake/2
gist: "Policy per component judged only at the plane's initialize (update_required -32016); troupe update: recommended, never blocked or below minimum, no downgrade unless named"
---

#66 slice 1b, after slice 1a (Decision 865) made releases signed and `troupe update`
install only what the release key signed. The maintainer decided the shape on 2026-10-11:
the plane's version policy is a floor, a recommended version and a blocklist per
component; it reaches clients through `initialize` and `troupe update`; and a client below
the floor gets a clear "update required". This records how.

## The policy

Per component — `tui` (the terminal, `troupe`), `daemon` (`troupe-daemon`) and `desktop`
(the desktop app) — a `recommended` version, a `minimum` and a `blocked` list, in the
plane's `client_versions` table, one row per component, written the first time an
administrator sets something. No row is no policy: every plane upgrading into this serves
every version until somebody decides otherwise. `admin.clients.get` (either admin role) and
`admin.clients.put` (platform admin) are the methods, audited as `clients.put` with the
diff, as every admin write is. A put changes the keys it sends, `null` clears one, and
`blocked` is the whole list; it is refused, with nothing written, for a version SemVer
cannot read, a `minimum` newer than `recommended`, or a `recommended` that is blocked.

The console has a small **Client versions** panel on the Policy page rather than a screen:
three fields per component, the same two calls. The real screen, with who runs what and a
"require update now", is #56's redo; the panel is what the console's patterns allowed for
almost nothing, and `Troupe.Plane.Admin.Console` places both methods on Policy.

**Ordering.** Versions are ordered as SemVer orders them, as `troupe update` already
ordered them (Decision 865), so `0.13.0-beta` comes before `0.13.1-beta` and also before
`0.13.0`. Comparing the numbers alone, dropping `-beta`, would have been kinder to an
administrator who types `0.13.0`, and would have made the plane and `troupe update`
disagree about which of two versions is older. So a policy names versions as releases are
numbered, the docs say so with an example, and a version that is not SemVer is refused at
the put. A client version that is not SemVer (`dev`) is judged against `blocked` alone.

`Troupe.Protocol.ClientUpdate` is the one reading of it: which component a client name is
(the names PROTOCOL.md §3 already gives: `troupe` and `troupe-headless`, `troupe-daemon`,
`troupe-gui`), what a policy says to a version, and the sentence a refusal is. It is in the
protocol app because the plane judging and the terminal and the daemon wording a refusal
must agree, and the TUI may call it (`troupe.xref`).

## Where it is judged: the plane's `initialize`, and only there

`/rpc` had no `initialize`: it keeps no connection, and the TUI's handshake over `POST`
was `me` (TUI Decision 93). It has one now, a call like any other, that answers `me` as
`principal` and the policy for the connecting client's component as `client_update`
(`action`: `suggest` below `recommended`, `none` otherwise), or refuses a client on a
blocked version or below `minimum` with **`update_required` (-32016)**, whose `data` names
the component, the version, the minimum, the recommended version, whether it is blocked,
what to run (`troupe update`; nothing for the desktop app, which has no updater yet) and
all of it as one sentence in `reason`.

The TUI's handshake over `POST` is now `initialize`, and `me` where the plane answers
`method_not_found`, so TUI Decision 93 still holds for a plane from before this. The
daemon has no connection to the plane, only a link a client hands it a token on
(Decision 764), so it makes the same `initialize` (as `troupe-daemon`) when a link brings a
token, before it asks for erasures or seals anything.

Only `initialize` judges. Every other `/rpc` call stands on its token, as before, and the
client is what stops: the TUI's plane connection goes down with the sentence as its
error, and every call through it answers that sentence until a reconnect is served; the
daemon answers every plane call with it until the next link's handshake. A per-request
header naming the client would let the plane refuse each call itself, and reach a client
already connected when the policy changes, which is #66's "while connected"; it is not
here, because the version is the client's own word either way. The refusal is a service
to the person — it tells them what they need — and not a way to keep anybody out: a
client that lies about its version, or one from before 0.13 that says none, is served,
and the plane cannot tell either from a script calling `/rpc`, which is held to nothing.

A refusal reads as itself. HQ's banner is the sentence rather than "the plane is
unreachable", which would send somebody to check their network; `troupe whoami` and every
plane call answer it; the daemon logs it once and `identity.get` carries it as
`update_required`.

## `troupe update`, signed in

`troupe update` asks the plane signed in to with `me.client_versions`: one call on its
own, because the client that most needs to update is the one `initialize` refuses. Then
(`Troupe.Update`, given the answer as `:plane`):

- the version asked for is the plane's `recommended` one (the terminal's, else the
  daemon's) rather than the latest, and a newer one already installed is left alone;
- a version the plane blocks, or one below its minimum for a component it would replace,
  is never installed, whether it is the latest or named with `--version`;
- **nothing moves backwards on the plane's word.** A component on a blocked version
  whose recommended one is older is told the `troupe update --version` that moves it back,
  for the person to run. Replacing it unasked would let a plane, or whoever holds one, walk
  a fleet back to an old signed release with known faults by blocking the current one;
- the release is checked against the release key exactly as without a plane. A plane can
  hold a version back or name one; it cannot make a client install anything the key did
  not sign.

With no plane signed in, or a plane with no policy, it is Decision 865's `troupe update`
unchanged. A plane that cannot be asked is said in a line and the update goes on as
without one: the release key still decides what may be installed, and a person whose plane
is down is not stranded on an old build by it. This closes slice 1a's held-back finding
for a signed-in client: a mirror that keeps serving an older signed release is refused,
because the version asked for is the one the plane names (`the release at … is X, not Y`).

## Why the policy carries no signature of its own in this slice

It travels on the plane's authenticated connection (TLS, and the person's plane token),
to a client that already trusts that plane with its sign-in, and it can only narrow what a
client does: refuse to serve it, or name a version for `troupe update`, which is installed
only if the release key signed it and only forwards unless the person names an older one.
A plane, or whoever holds its database, can hold a fleet back or tell it to move forward;
it cannot run anything the key did not sign, and cannot downgrade anybody unasked.

#66's plane-signed channel document would add what a connection cannot: a policy that
outlives the connection — cached, checked offline, with an `expires_at` so a stale copy
cannot pin a fleet — signed by a plane key pinned at sign-in, so a document served by a
mirror or carried to an air-gapped machine is still the plane's word. That is for when the
plane serves the assets itself.

## Not in this slice

The plane hosting the release assets (`/downloads/*`) and its channel document; the desktop
app's updater (Tauri) and its `desktop` policy being acted on by anything but the plane's
refusal; OS code signing (notarisation, Authenticode); the compatibility floor the plane
would compute from its own build; re-evaluating clients already connected when the policy
changes; the daily start-up check; and the Client versions screen with who runs what (#56).

## Proof

- `apps/troupe_plane/test/troupe/plane/client_versions_test.exs`: the methods over `/rpc`
  (roles, the audit, partial puts, every refusal with nothing written), `initialize`'s
  `client_update`, `update_required` below the minimum and on a blocked version, the
  daemon's own policy, a client the plane cannot place, and `me.client_versions`. On the
  tip before this, `admin.clients.get` and `initialize` were `method_not_found`.
- `panel_test.exs`: the Policy page's panel saves, audits and refuses; `admin_parity_test`
  and `console_coverage_test` hold the new methods to the table, the tools and a screen.
- `apps/troupe_gateway/test/troupe/gateway/plane_version_test.exs`: the daemon's
  handshake, a refusal answering every call, a later handshake lifting it, a plane from
  before the policy, and through the daemon: a refused link asks nothing more and
  `identity.get` says why.
- `apps/troupe_core/test/troupe/update_test.exs` ("signed in to a plane"): the recommended
  version installed, a mirror's older release refused, blocked and below-minimum versions
  never installed, no downgrade unless named, a newer version left alone.
- `clients/tui/test/troupe/plane_version_test.exs`: the handshake is `initialize`; a refusal
  is the sentence in HQ, `troupe whoami` and every call; `troupe update` asks
  `me.client_versions`.
