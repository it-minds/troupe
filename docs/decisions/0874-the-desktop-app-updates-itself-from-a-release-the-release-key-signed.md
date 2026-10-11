---
number: 874
title: The desktop app updates itself and the daemon beside it only from a release the release key signed, follows the plane's recommended version and says its update_required, and asks before it restarts; the terminal says the plane's suggest in a line
date: 2026-10-12
status: accepted
issue: 66
paths:
  - .github/workflows/release.yml
  - .github/workflows/native.yml
  - scripts/release-desktop-update.exs
  - apps/troupe_core/lib/troupe/release/manifest.ex
  - apps/troupe_protocol/lib/troupe/protocol/client_update.ex
  - clients/gui/apps/desktop/src-tauri/src/release.rs
  - clients/gui/apps/desktop/src-tauri/src/update.rs
  - clients/gui/apps/desktop/src-tauri/tauri.conf.json
  - clients/gui/apps/desktop/src-tauri/Cargo.toml
  - clients/gui/apps/desktop/src/updates.ts
  - clients/gui/apps/desktop/src/views/Update.tsx
  - clients/gui/packages/client/src/update.ts
  - clients/tui/lib/troupe/remote/plane.ex
  - clients/tui/lib/troupe/ui/hq.ex
  - docs/user/updating.md
symbols:
  - Troupe.Protocol.ClientUpdate.suggestion/2
gist: "One release key signs the desktop update too; the app trusts only keys compiled in, checks the manifest first, never moves back, asks before restarting"
---

#66 slice 2, after slice 1 made releases signed and `troupe update` install only what the
release key signed (Decision 865), and gave the plane a version policy it says at
`initialize` (Decision 868). The maintainer decided the shape on 2026-10-12: the release
minisign key also signs the desktop app's update, so there is one key and one rotation
story; the desktop app updates itself, and the daemon it runs, only from a signed release;
it follows the plane's recommended version when signed in, never a blocked one and never
below the minimum; it asks the person before it restarts; and it calls the plane's
`initialize` and shows `update_required` as a sentence. This records how.

## One key: Tauri's updater takes the release key as it is

Tauri's updater checks an update with minisign, through the `minisign-verify` crate: its
public key is minisign's `.pub` file, base64-encoded, and an update's signature is a
minisign signature, base64-encoded, read as minisign reads one, hashed (`ED`) or not. The
release key is a minisign key (Decision 865), so the updater takes it with nothing to
convert and **no second key is needed**. What Tauri's own tools add — a password on the
secret key, `tauri signer sign` — is not used: the signature is made by the same Elixir
signer that signs the manifest (`Troupe.Release.Minisign`), in the publish job, which alone
holds the key. The trusted comment names the file and the version (`version:0.15.0-beta`),
which the updater holds the version it is offered to, so an older signed update served
under a newer number is refused by the updater too.

## What a release carries

`scripts/release-desktop-update.exs`, run in the publish job before the manifest, writes a
`.sig` beside each file the desktop app updates itself from — the per-user setup on Windows
(`Troupe_<v>_x64-setup.exe`), the app archive on macOS (`Troupe_<v>_universal.app.tar.gz`,
which `native.yml` packs beside the disk image) and the AppImage on Linux — and
`latest.json`, the document the updater reads. These are what the installers put on a
machine, so each updates what is there. The manifest is written after them and names them
like any other file (`latest.json` is the desktop app's), so one signature chain covers
everything a client installs. The script refuses as the manifest's does: no key, an
encrypted key, or a key that is not the first in `release-keys.txt`, and the release stays
a draft.

**A key rotation.** The updater checks one key, the first block of a signature. The apps
that update *to* a rotation release were built before it and trust the old key alone, and
an app built from it trusts both, so during a rotation the update is signed with
`RELEASE_MINISIGN_KEY_PREVIOUS`, the key being retired, and with the current key otherwise.
The app gives the updater whichever of its own compiled-in keys made the signature.

## What the app checks, and in what order

`src-tauri/src/release.rs` is the Elixir verifier's twin, held to the same answers by the
shared vectors in `test/fixtures/release/`, and trusts the keys `release-keys.txt` held when
the app was compiled, and no others: `tauri.conf.json`'s `plugins.updater.pubkey` is empty
on purpose, so nothing but `update.rs`, which names the key for each update, can make the
updater accept one. `update_check` fetches the release's `manifest.json` and its signature
first and nothing else until the signature holds and the manifest names the version asked
for (or the tag `/releases/latest` named); then the update's `.sig`, held to the manifest's
size and sha256. `update_download` has the updater download and check the update against
that key, and checks it again against the manifest's size and sha256. A release that fails
any of it is refused with a sentence, and nothing changes. The page is granted none of the
updater plugin's own commands, and the shell's three take no URL, path or key from it.

**Where from.** Signed in to a plane, the version `me.client_versions` recommends for
`desktop`; otherwise, or with none recommended, the latest release. `TROUPE_RELEASE_URL`
and `TROUPE_REPO` move it as they move `troupe update`; over `https` only, since the
updater reads nothing else in a release build. The download is from wherever the manifest
was found, not the URL `latest.json` names. A version the plane blocks, or one below its
minimum, is never installed; nothing older than the app is offered, and on a blocked
version whose recommended one is older the app says so and leaves the move back to the
person (Decision 868's rule).

## When it checks, and when it restarts

On start and once a day: the plane's `initialize` (as `troupe-gui`, with the version as
releases are numbered, not the bundle's numeric one), then the release check, which waits
for the plane's answer so that it never offers a version the plane would not serve.
Nothing is downloaded until the person presses **Update**, and nothing restarts until they
press **Restart now**. Then the app waits for every turn at work in a session on this
computer; a team session runs on its pod whatever the window does, and is not waited for.
On Windows the setup restarts the app (Tauri's `/R`); elsewhere the app restarts into the
new bundle.

## The daemon beside the app

The desktop app does not carry a daemon inside its bundle: the installers put
`troupe-daemon` beside it (`%LOCALAPPDATA%\Programs\troupe-daemon`, `~/.local/lib/troupe-daemon`,
`TROUPE_LIB_DIR`). So the update replaces that one, from the same verified release, where
it is older than the release and the plane serves the release's daemon. Its archive is
checked against the manifest and unpacked beside it as `troupe-daemon.new`; before the
install the page asks the daemon to stop between turns with `daemon.stop`, asking again
every two seconds while it names a turn at work (Decision 865's rule), and the shell
waits for it to be gone, then renames it to `troupe-daemon.previous` and the new one into
its place: the installers' names, so `troupe update --rollback` and
`install-local.ps1 -Rollback` find them. If the app's own install fails after that, the
daemon goes back as it was. A daemon a terminal runs inside itself says so and is left
running.

**A machine with only the desktop app's daemon** — the desktop app and `troupe-daemon`, no
`troupe` — had no updater (D122): `troupe-daemon` cannot replace the directory it runs
from on Windows. It has one now, the desktop app, which runs from elsewhere. A machine
with the daemon alone is still updated by its installer.

## The plane's word

Signed in, below the minimum or on a blocked version, the app says the refusal as a
sentence with **Update now**, worded from the refusal's fields as the terminal words its
own (`This plane needs the desktop app 0.15.0-beta or later, and this is 0.14.0-beta:
update it now, which installs 0.15.1-beta.`), and keeps to the sessions on this computer,
as it does when the plane is not answering: the plane is not asked for the team's. The
plane's own `reason` for the desktop app now says "update the desktop app", since it has an
updater; `data.run` stays `null`, there being no command. Served with `action: "suggest"`,
the app says the plane's recommended version in the update's quiet line. A plane from
before the policy says nothing either way.

**The terminal.** `suggest` is one quiet line where the terminal meets the plane — HQ
under the lockup, and after `troupe login` and `troupe whoami` — with the command to run
(`This plane recommends troupe 0.15.1-beta, and this is 0.15.0-beta: run troupe update.`),
never a warning or an exit status. `Troupe.Protocol.ClientUpdate.suggestion/2` is that
line, read the same way from the plane's map or its JSON. The terminal does not ask the
plane at start; it says the line when it connects, which is when the plane answers.

## Not in this slice

OS code signing and notarisation (the setup is still unsigned on Windows and macOS, and
the release key does not change that); the plane serving the release's files
(`/downloads/*`); re-judging a client already connected when the policy changes; and the
terminal's own daily check.

## Proof

- `clients/gui/apps/desktop/src-tauri`: `cargo test` — the shared signature and artifact
  vectors through the Rust verifier, a key as the updater takes it, the manifest fetched
  over HTTP and refused when changed, another key's, another version's or missing, the
  update's signature naming the key the updater is given, the daemon unpacked beside and
  swapped in with the old kept and back, a plane's blocked or too-old version never
  installed.
- `apps/troupe_core/test/troupe/release/desktop_update_test.exs`: the script run as CI
  runs it with throwaway keys, each `.sig` checked with the clients' verifier and its
  trusted comment naming the version, `latest.json`, the manifest naming both, the
  refusals, and the rotation signed with the retiring key; the publish job runs it before
  the manifest.
- `clients/gui/apps/desktop/test/updates.test.tsx`: against the fake plane with a policy,
  `initialize` as `troupe-gui` with the version; `update_required` as a sentence with
  **Update now**, and the plane not used; `suggest` quiet; the check on start and again;
  the restart asked for, held while a turn is at work, and the daemon asked to stop. On
  the tip before this the app never called `initialize` and never checked for a release.
- `clients/gui/packages/client/test/client-update.test.ts`: `askPlane` and the sentences.
- `clients/tui/test/troupe/plane_version_test.exs`: `suggest` as one line in the status,
  `troupe whoami` and HQ, and nothing at the recommended version. On the tip before this
  `suggest` said nothing anywhere.
