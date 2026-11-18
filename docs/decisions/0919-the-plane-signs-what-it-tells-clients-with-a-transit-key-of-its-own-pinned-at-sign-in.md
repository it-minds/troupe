---
number: 919
title: "The plane signs its version policy and its organisation's document with an Ed25519 transit key of its own, made on first use and never exportable; the terminal, the daemon and through it the desktop app pin that key per plane at sign-in, take only what it signed, and take a changed key only when a person accepts its fingerprint; the plane names where releases are and can hand out their files itself, the release key still the check"
date: 2026-10-18
status: accepted
issue: 657
paths:
  - apps/troupe_protocol/lib/troupe/protocol/plane_signature.ex
  - apps/troupe_protocol/lib/troupe/kms/policy.ex
  - apps/troupe_plane/lib/troupe/plane/signing.ex
  - apps/troupe_core/lib/troupe/plane_keys.ex
  - apps/troupe_core/lib/troupe/update.ex
symbols:
  - Troupe.Protocol.PlaneSignature
  - Troupe.Plane.Signing
  - Troupe.PlaneKeys
  - Troupe.KMS.Policy.plane_signing/2
gist: "Plane key: transit ed25519, made on first use, never exportable, not the release key; clients pin per plane, take only what it signed; a new key only by a person's yes"
---

The maintainer decided the shape on 2026-10-18: a non-exportable transit key per plane in
OpenBao signs what the plane tells clients, the versions it serves and recommends and the
defaults and limits; clients pin its public key at sign-in, and the console shows it; it
is separate from the release key.

## The key

`Troupe.Plane.Signing`: a transit key `troupe-plane-signing` (the deployment may name
another, `:plane_signing_key` in the plane's `:transit` configuration), type **`ed25519`**,
`exportable: false`, `allow_plaintext_backup: false`, created the first time anything asks
for it. Ed25519 because it is what minisign-style verifiers check, it is what transit
offers among its signing types, and `:crypto`, WebCrypto and Rust all verify it with
nothing added. The signature is **plain Ed25519 over the document's bytes** (RFC 8032),
which is exactly what transit's `sign` makes of an `ed25519` key's input; not minisign's
own file format, which would need a second transit call for its trusted comment and gains
nothing here, since what is signed is a JSON answer, not a file somebody checks with the
`minisign` program.

Its public half is served at `GET /.well-known/troupe-signing-key` (algorithm, base64 of
the 32 bytes, fingerprint, version, when transit made it), anonymous as the JWKS is, and
`/.well-known/troupe` names it as `plane.signing_key`. The fingerprint is `SHA256:` and
the unpadded base64 of the key's SHA-256, as `ssh-keygen -l` writes one, so a person
comparing it with what their machine says compares the same string. The OpenBao policy is
`Troupe.KMS.Policy.plane_signing/2`: create, read and update on the key, update on its
`rotate`, create and update on its `sign`; no `export`, `backup` or `config` path, so not
even the plane can make it exportable later.

**Not the release key.** The release key signs releases in CI and is compiled into every
client (Decision 865); nothing at run time adds a release key. This one is learned from the
plane at sign-in and is the plane's word only about what a client should do. A plane can
hold a fleet back or name a version; signed or not, it cannot make a client install
anything the release key did not sign, and every check of Decisions 865 and 868 stands.

## What it signs, and how

`me.client_versions` and `me.client_defaults` (`Troupe.Plane.Harness`) carry `signed`
beside their fields, which stay as they were for clients from before:

```json
"signed": {"algorithm": "ed25519", "fingerprint": "SHA256:...",
  "document": "<canonical JSON text>", "signature": "<base64 of 64 bytes>"}
```

`document` is canonical JSON (`Troupe.Protocol.Canonical`) of `kind` (`client_versions`
or `client_defaults`), `plane` (its base URL, or null), `signed_at`, `expires_at` and
`body`. It is the text that was signed, shipped as text: a verifier checks the bytes it was
sent and parses them afterwards, so the Elixir, TypeScript and any later verifier never
have to agree on an encoding, only on bytes. `kind` is checked, so one signed answer cannot
stand in for the other. The window is **a week**: long enough for a laptop that is not
signed in every day, short enough that an answer copied from a cache is not the plane's
word for long.

- `client_versions`'s body is `{versions: {tui, daemon, desktop}, release: {url}}`; the
  top-level answer is the components as before, with `release` and `signed` beside them
  (an older client reads components by name and never sees either).
- `client_defaults`'s body is the whole answer, old fields, `defaults` and `enforced`.

`Troupe.Protocol.PlaneSignature` is the one reading of it on the Elixir side, in the
protocol app because the plane building it and the core checking it must agree, and the
plane may not call the core (`mix troupe.boundaries`). `planeSignature.ts` is its twin, and
both are held to one vector, a fixed seed and time, checked in each suite.

An answer the plane cannot sign, because OpenBao does not answer, goes out **unsigned** and
is logged. Clients that pinned the key refuse it; that is the right failure, since an
attacker stripping the signature must not get further than OpenBao being down.

`initialize` is not signed. Its `client_update` and `update_required` stand on the
connection, as Decision 868 has them: a refusal is a service to the person, and what a
client acts on, what to install and what to hold a machine to, comes from the two signed
answers.

## Pinned per plane, as SSH pins a host key

`Troupe.PlaneKeys` keeps, per plane URL (a trailing slash aside), the key this machine
holds it to, in `<state>/plane-keys.json`, written whole through a rename. **One file for
the terminal and the daemon**, and the desktop app reads the daemon's (`identity.get`'s
`plane_key`), so a key accepted in one is accepted in all three; the desktop app has no
store of its own, and a daemon always runs beside it.

- **At sign-in.** `troupe login` fetches the served key and pins it where none is, saying
  its fingerprint. The daemon does the same after every `identity.link` that brings a token
  and is not refused (Decision 868), which is when the desktop app signs in, so the desktop
  app's sign-in pins through it. A machine that signed in before this pins at its first
  link or `troupe update` after it, from the key the plane serves: trust on first use, as
  SSH's is.
- **Every answer.** `check/4`: a signed answer is the body the pinned key signed, as the
  kind asked, not expired; one signed by another key names that key, one changed after it
  was signed is forged, and once a key is pinned an **unsigned answer is refused** too. Each
  refusal is a sentence (`PlaneSignature.refusal/3`), and the answer is not acted on:
  `troupe update` goes on as without a plane, which is what a plane that could not be asked
  already did (Decision 868), and the daemon keeps the copy of the document it had.
- **A changed key** is kept beside the pin as `offered` and trusted for nothing. It is
  taken only when a person accepts it by the fingerprint they were shown, which must be the
  offered key's or the one the plane serves at that moment: `troupe plane-key accept
  FINGERPRINT`, the daemon's new `identity.accept_plane_key`, or the desktop app's banner,
  which shows both fingerprints and says to check the new one with the plane's
  administrators first. `troupe plane-key` shows the pin and an offered key.
- **A plane that signs nothing**, from before this, serves no key path: nothing is pinned
  and its answers are taken as they always were, said in a line (the terminal on screen,
  the daemon and the desktop app in their logs; on the desktop app's banner it would be
  said every day to anybody on an older plane, which is noise rather than news).

The pin file is in the person's own state directory, as the copy of the document is
(Decision 869): it stops an answer from anywhere but the plane signed in to, a mirror, a
copy carried to another machine or an edited cache, and is not a lock against the person on
a machine they administer. The managed file stays the strong form.

## The kept copy is checked whenever it is read

`Troupe.Config.Org.save/4` keeps the signature in `organisation.json` (format 1 still: an
older Troupe reads the copy and ignores `signed`). `read_cache/1` checks it against the pin
on every read: a copy whose signature does not hold, or whose `defaults` and `enforced` are
not the signed body's, was changed on this machine and is **refused with a sentence**, and
the organisation's layer is then a warning, as any unreadable copy is; an unsigned copy of a
plane whose key is pinned is refused too. This is #657's "an edited cached organisation
document is refused with a sentence". A signed copy **past its time still holds**, its
limits and its defaults, with a warning: the plane's word does not lapse because a laptop
was offline for a week, and a fresh copy replaces it at the next sign-in. Expiry is a check
on answers as they arrive, where a replayed old answer is what it stops.

## Where releases are, and the plane serving them

- **The setting.** `client_release_url` (a new *Where people's machines get releases*
  group, shown on the console's Policy page): an http or https URL under which each release
  is at `v<version>/`, as GitHub lays them out, so a mirror is a copy of GitHub's release
  assets and GitHub's own download URL is one too. Empty is GitHub's. It goes out as
  `release.url` in the signed version policy.
- **`troupe update`** (`Troupe.Update`) installs from there when signed in, after
  `TROUPE_RELEASE_URL`, which is the person's own and wins: the version asked for under
  `v<version>/`, held to the manifest naming that version, so a mirror serving an older
  signed release under a newer number is refused as before. A mirror has no "latest", so
  with no version recommended or named it asks for one.
- **The plane's own `/downloads`.** `GET /downloads/v<version>/<file>` answers a 302 to a
  five-minute presigned URL for `releases/v<version>/<file>` in the plane's object store,
  for a version it serves to some kind of client, and 404 for one every component blocks or
  is below, for a name that is not a release file's, and for anything else. A redirect
  rather than the bytes keeps the plane out of the path of a download as session.presign`n  keeps it out of a session's, and machines already reach the store for private sessions. Anybody may fetch, as from GitHub: the release key's signature on the manifest
  is the check on every file, and the plane serving them changes nothing about that. The
  files get there by an administrator copying a release's assets into the bucket; the docs
  say so.

## The console

The Integrations page has *The plane's signing key*: its fingerprint, algorithm, when it was
made, its version and public half, and the earlier versions. `admin.signing.get` (either
admin) and `admin.signing.rotate` (platform admin, `destructive`, confirmed by typing the
current fingerprint) are the methods, audited as `signing.rotate` with the fingerprints and
versions, placed on Integrations (`Troupe.Plane.Admin.Console`). A rotation makes a new
transit version, which signs from then on; every machine that pinned the old one refuses
what it signs until its person accepts it.
