---
number: 931
title: "The desktop app's shell checks the plane's signed version policy itself, against the key the daemon pinned, before it takes a version or where releases are from it; a connected daemon asks the plane's initialize again every thirty seconds and fetches the signed answers when its policy revision moves, so a change reaches the clients and, at their next turn, the running sessions; initialize's update_required is signed and acted on only as signed; a release is mirrored into the plane's object store only once its manifest checks against the release keys; and /downloads answers a bare 404 whatever the policy says"
date: 2026-10-23
status: accepted
issue: 657
paths:
  - clients/gui/apps/desktop/src-tauri/src/plane_word.rs
  - clients/gui/apps/desktop/src-tauri/src/update.rs
  - clients/gui/apps/desktop/src-tauri/src/daemon.rs
  - clients/gui/apps/desktop/src/updates.ts
  - clients/gui/apps/desktop/src/shell.ts
  - clients/gui/packages/client/src/update.ts
  - clients/gui/packages/client/src/planeSignature.ts
  - clients/gui/apps/console/src/views/Integrations.tsx
  - apps/troupe_protocol/lib/troupe/protocol/plane_signature.ex
  - apps/troupe_protocol/lib/troupe/release/minisign.ex
  - apps/troupe_protocol/lib/troupe/release/manifest.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/releases.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/web/router.ex
  - apps/troupe_core/lib/troupe/plane_keys.ex
  - apps/troupe_core/lib/troupe/session.ex
  - apps/troupe_core/lib/troupe/session/organisation.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_gateway/lib/troupe/gateway/plane.ex
  - apps/troupe_gateway/lib/troupe/gateway/policy.ex
  - clients/tui/lib/troupe/remote/plane.ex
  - PROTOCOL.md
  - docs/user/updating.md
  - docs/admin/routine-tasks.md
symbols:
  - Troupe.Gateway.Policy
  - Troupe.Session.Organisation
  - Troupe.Plane.Releases
  - Troupe.PlaneKeys.held_refusal/5
gist: "Shell checks the signed policy itself before any URL; daemon polls initialize every 30 s by revision; refusals signed; mirror checks the release key first; /downloads bare 404"
---

# The plane's word reaches the desktop updater signed, a policy change reaches connected clients, and releases are mirrored

#657 slice 2, after Decision 919 (slice 1) gave the plane a non-exportable signing key,
the two signed answers and a pin per plane, and left four things: the desktop app's
updater following the plane's release URL, a policy change reaching clients already
connected, a way to put a release into the plane's object store, and `initialize`'s
`update_required` and `/downloads`, which said things unsigned. This records how each was
done. It replaces two things of Decision 919: `initialize` standing unsigned, and
`/downloads` refusing a version no component is served; the rest of 919 stands.

## The desktop app's shell checks the plane's signature itself

Decision 874 has the shell take no URL from the page: a URL the page verified is still the
page's. So the page now hands the shell the policy's `signed` envelope as the plane sent it
(`UpdatePlane.signed`), and the shell (`src-tauri/src/plane_word.rs`):

- asks the daemon for the pinned key itself, over the daemon's loopback socket with the
  token in `daemon.json` (`daemon::identity`, `identity.get`'s `plane_key`), the same pin
  the terminal and the daemon hold every answer to;
- checks the Ed25519 signature over the document's bytes against that key, works its
  fingerprint out again rather than reading it, and checks the kind (`client_versions`)
  and that it is not past `expires_at`;
- only then reads the document: each component's policy, the `desktop` component's
  recommended version, and `release.url`.

With a signed answer the page's `version` and `versions` are not read at all. A policy the
pinned key did not sign, one changed after it was signed, of another kind or past its time,
one that came with no daemon to ask or no key pinned for that plane, is refused with a
sentence ending "nothing is installed", before anything is fetched from the URL it names.
Without a signed answer (a plane from before 0.22, or a page that has no key pinned) the
shell does as before: the page's policy can hold an update back, and releases come from
GitHub; no field of the page's is a URL in either case.

Where the plane names releases, the release is `<url>/v<version>/`, the version the signed
policy recommends; a mirror has no "latest", so with none recommended the shell says so and
offers nothing. `TROUPE_RELEASE_URL` is the person's own and still wins. Everything after is
Decision 874's: the manifest's release-key signature first, the update held to it, the
download from where the manifest was found. The verifier is the twin of
`Troupe.Protocol.PlaneSignature` and `planeSignature.ts`, held to their shared vector; it
uses `ring`, already in the lock through rustls, since `minisign-verify` checks only
minisign's own format.

**Not chosen: the shell fetching `me.client_versions` itself.** It would need the plane
token, which only the page holds, and would be a second plane client in Rust beside the
page's, outside the one gate every plane request goes through (Decision 926). The envelope
is self-checking: whoever carries it cannot change it without the pin refusing it.

## A policy change reaches connected clients: a signed poll, not a push

Nothing dials a laptop's daemon; it dials the plane. The one connection that stays open is
the offered session's (Decision 921), which exists only while a session is offered, so a
push over it would reach some machines and not others. The daemon is the client that is
running and signed in whenever any client on the machine is, so it asks
(`Troupe.Gateway.Policy`):

- **every thirty seconds while it holds a token**, the plane's `initialize` again
  (`Plane.handshake/0`). That alone judges the daemon's own version against the policy as
  it stands now, which is #657's "connected clients are judged again";
- the handshake's answer carries **`policy.revision`**, a SHA-256 of the canonical JSON of
  what `me.client_versions` and `me.client_defaults` would say now. Where it moved, or
  there was none yet, the daemon fetches both, checked against the pin as at a link.

Thirty seconds so that a change lands "within a minute" with room for one missed poll. The
revision keeps the cost of a poll at one `initialize` and no OpenBao call: signing both
answers every half minute for every signed-in machine would be two transit calls each, for
nothing changed. The revision is not signed and is no word on anything: forged, it makes a
daemon ask or not ask, and what it acts on is still only what the pinned key signed. A
plane from before the revision names none, and is asked at its links, as before.

**What changes, and what is said.** A changed organisation's document is kept as at a link
(the copy, the signature, `config.changed` with scope `org` to every client), and every
session running on the machine is resolved again (`Troupe.Session.Organisation`), from the
same workspace and overrides it started with (`Troupe.Session.reconfigure/2`). Where a value
the organisation sets, or holds a layer to, came out different, the session's root agent
takes the new configuration as its next turn begins, never during one, and logs
`config_note` with key `organisation`: "Your organisation's settings changed: max_tokens
holds from this turn." The clients already show a `config_note` as a line. Its children are
started with its configuration and follow; the budget keeps its use so far and its limits
are held to what is now enforced, and a looser one is had by asking, as before. What the
session set up as it started, its approval mode, MCP servers and watchers, holds until it is
started again, and the line names those keys apart. `troupe config --explain --session` and
`context.get` read the resolved layers through `Troupe.Session.resolved/1`, which returns
the new ones, so what explains a session is what it runs with from its next turn (Decision
918). A changed version policy is told as `config.changed` with scope `versions`, and the
desktop app asks its two questions again then rather than at the next day's round.

**Not chosen: re-reading the document at every turn.** Every session would read and verify
the copy at every turn; a change is rare, and the poll knows when one happened. **Not
chosen: a plane-side push to the daemon** over a new standing connection: a second
long-lived connection per laptop, for a change measured in minutes.

## `update_required` is signed

The plane signs a refusal as it signs the policy: `data.signed`, kind `update_required`,
its body the refusal's fields, for an hour rather than a week (a refusal is the plane's
word on one handshake, asked again at the next). Every client that pinned the plane's key
acts on a refusal only as that key signed it, for its own component and version
(`Troupe.PlaneKeys.held_refusal/5`, and its twin in `update.ts`): the daemon's handshake, the
terminal's plane connection and the desktop app. One unsigned, signed by another key, past
its hour or for another version is logged or said and not acted on: the client goes on as
with a plane that could not be asked, told to update by nothing it cannot check. A plane
nothing is pinned for, which signs nothing, is taken at its word as before.

## Releases mirrored into the plane

`admin.releases.mirror {version}` (a platform admin's, on the console's Integrations page),
rather than a Mix task: a plane runs as a release with no Mix, and an administrator mirrors
from the console. `Troupe.Plane.Releases` fetches the release's `manifest.json` and its
signature from GitHub's release downloads (or the deployment's `:releases` `source`), checks
them against the release keys the plane was built with, read from the same
`release-keys.txt` every client is built with and settable by nothing at run time, and
refuses a manifest they did not sign, or one naming another version, with a sentence and
nothing copied. Then, in the background, since a release is a few hundred megabytes, each
file the manifest names is fetched, held to its size and sha256, and put under
`releases/v<version>/`, the signature and the manifest last: a release is **mirrored** once
its manifest is there, and a copy that stopped half way names none. `admin.releases.list`
says which are mirrored and which are being copied on this replica. Audited as
`release.mirror`, and the copy's end as `release.mirrored` or `release.mirror_failed`.

To check the manifest the plane needs the release verifier, which lived in the core; the
plane may not call the core (`mix troupe.boundaries`). `Troupe.Release.Minisign` and
`Troupe.Release.Manifest` move to the protocol app, under the same names, as
`PlaneSignature` is there: the plane checking a release and the clients checking it must
agree. `Troupe.Release.Keys` stays in the core. The plane checking the release changes
nothing about who checks it: every client checks it again before it installs.

## `/downloads` says nothing about the policy

It handed out a version some component was served and 404'd one every component refused,
so anybody without a sign-in could probe which versions were blocked. It now hands out a
file that is in the store and answers a bare 404, with no body, for anything else, whatever
the policy says: the list of refused versions comes only from the signed, signed-in
`me.client_versions`. A blocked version that is mirrored is handed out, as GitHub hands it
out; no client installs a version the policy it holds refuses.

## Proof

- `clients/gui/apps/desktop/src-tauri`: `cargo test` — `plane_word`: the shared vector
  through the Rust verifier, a policy naming where releases are, one signed by another key
  (named), edited, of another kind, expired or unreadable refused with the sentence, the pin
  taken only for its plane; `update`: a release URL taken only from a policy the pinned key
  signed, the manifest then fetched from `<url>/v<version>/` and held to the release key, a
  forged policy and a missing pin or daemon refused before anything is fetched, a release
  URL needing a version; `daemon`: `identity.get` asked over the daemon's socket.
- `clients/gui/apps/desktop/test/updates.test.tsx`: the signed policy handed to the shell as
  it came, beside the page's fields; a `config.changed` with scope `versions` asks again.
- `clients/gui/packages/client/test/client-update.test.ts`: the signed policy kept for the
  shell; a refusal acted on as signed, and not when unsigned or signed by another key.
- `apps/troupe_gateway/test/troupe/gateway/policy_test.exs`: a limit changed on the plane
  reaching a running session at its next turn with the line, and every client hearing it; a
  changed version policy told, an unchanged revision fetching nothing; an unsigned refusal
  from a pinned plane not taken, a signed one taken and shown in `identity.get`.
- `apps/troupe_core/test/troupe/session/organisation_test.exs`: a running session resolved
  again, the change taken at the next turn and not before, the keys held until a restart
  named apart, the same document again saying nothing, every session resolved.
- `apps/troupe_core/test/troupe/plane_keys_test.exs`: `held_refusal/5` against signed,
  unsigned, other-key, edited, other-version and expired refusals, and a plane with no pin.
- `clients/tui/test/troupe/plane_version_test.exs`: a signed refusal said in HQ's sentence,
  an unsigned one from a pinned plane not taken.
- `apps/troupe_plane/test/troupe/plane/signing_test.exs`: the refusal signed as
  `update_required` for an hour, the revision moving when either answer does, `/downloads`
  answering the same bare 404 for blocked, too-old and served versions not kept.
- `apps/troupe_plane/test/troupe/plane/releases_test.exs`: a release mirrored against the
  development object store from a stand-in for GitHub serving the shared release vectors,
  every file and the manifest last, listed, audited and handed out at `/downloads`; a
  manifest signed by another key, changed, of another version or missing refused with
  nothing copied; a file that is not the manifest's stopping the copy with no manifest
  written. `admin_parity_test` and `console_coverage_test` hold the two methods to the
  table, the MCP tools and Integrations; `clients/gui/apps/console/test/integrations.test.tsx`
  the card, the mirror, the refusal's sentence and a team admin reading only.
