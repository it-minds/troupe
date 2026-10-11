---
number: 865
title: A release's manifest is signed with one minisign key held by CI, every client is built with its public half, and troupe update installs only what that key signed, replacing the daemon between turns
date: 2026-10-11
status: accepted
issue: 66
paths:
  - .github/workflows/release.yml
  - scripts/release-manifest.exs
  - scripts/release-vectors.exs
  - scripts/release-installers
  - apps/troupe_core/lib/troupe/release/
  - apps/troupe_core/lib/troupe/update.ex
  - apps/troupe_core/priv/release-keys.txt
  - apps/troupe_gateway/lib/troupe/gateway/idle.ex
  - install.sh
  - install.ps1
  - test/fixtures/release/
symbols:
  - Troupe.Release.Minisign
  - Troupe.Release.Manifest
  - Troupe.Release.Keys
  - Troupe.Update
gist: "Release keys are compiled in from priv/release-keys.txt, never added at run time; nothing unverified is installed; the daemon is replaced only once it stops between turns"
---

#66 slice 1a. Until now a release carried one `SHA256SUMS`, which comes from the same place as
the files it sums: it catches a broken download, not a changed release. Nothing updated
itself, either. The maintainer decided the shape on 2026-10-11: releases are signed with a
minisign key, one Ed25519 key held by CI in the `release` environment; each release gets a
signed `manifest.json`; the clients carry the public key and check the manifest and each
file's sha256 before they swap a binary; a key rotation is a release signed with both keys;
and nothing unverified is ever installed. This records how.

## The release key

- **Where it lives.** The secret half is the `release` environment's secret
  `RELEASE_MINISIGN_KEY`: the key file as `minisign -G -W` writes it, unencrypted, since the
  environment is its protection and a password would be a second secret beside it. Only the
  release workflow's `publish` job runs in that environment. Nothing in this repository
  creates, stores or prints a real key.
- **The public half** is a line in `apps/troupe_core/priv/release-keys.txt`, the first line
  being the current key. `Troupe.Release.Keys` reads the file when it is compiled, so a
  client trusts exactly the keys of the commit it was built from. No setting, environment
  variable or file read at run time adds a key, and a test hands its own throwaway key to the
  function it calls. That is the line not to undo: a knob to trust another key is a knob for
  whoever can turn it.
- **Before the maintainer created it**, the list was empty: a build trusted no key,
  `troupe update` installed nothing, saying why, and the release workflow refused to
  publish. The maintainer created the key on 2026-10-11, and it is the first line of
  `release-keys.txt`. A build from before then still trusts none, so it is updated by its
  installer, not by `troupe update`.

## The manifest

`manifest.json` is format 1: the version, then every file the release publishes, one to a
line, with its `component` (`daemon`, `tui`, `desktop`, `installer`, `chart`, `vscode`,
`licence`, `other`), its `target` (`linux_x86_64`, `linux_aarch64`, `macos_x86_64`,
`macos_aarch64`, `windows_x86_64`, `macos_universal` for the desktop app, or `null`), its
`file` name, its `size` and its `sha256`. `Troupe.Release.Manifest` writes it the same way
every time, so a shell installer finds a file's line with `grep`. A later format is a new
number, which an older client refuses by name.

`scripts/release-manifest.exs` writes it in the `publish` job over everything attached, and
signs it into `manifest.json.minisig`. It is Elixir, loading `Troupe.Release.Minisign` and
`Troupe.Release.Manifest` from source, rather than the `minisign` program, so the signer is
the same code the clients verify with and is tested here with throwaway keys
(`release_workflow_test.exs`); minisign's own program verifies what it writes (the
installers use it). The script refuses, and the release stays a draft, when the secret is
not set, is encrypted, or is not the first key in the list; and it checks its signature with
the clients' verifier against the list before it writes anything. `SHA256SUMS` is written
after it and covers it too.

## A key rotation

A `.minisig` holds one signature block; this one may hold several, one per key, the current
key's first. The `minisign` program reads the first block only, so it checks the current
key, which is the key the installers attached to that release carry. The verifier accepts a
manifest when at least one block is by a key it trusts and every block by a key it trusts
holds; a block by a key it does not know is passed over. To rotate:

1. Put the new public key first in `release-keys.txt` and keep the old one below it.
2. Set `RELEASE_MINISIGN_KEY` to the new key and `RELEASE_MINISIGN_KEY_PREVIOUS` to the old.
3. Release. That release is signed by both: a client built before it checks the old key's
   block, one built from it either.
4. In the next release take the old key out of the list and the `_PREVIOUS` secret away.

A client that skips the rotation release cannot check the one after it, and says so; it
updates to the rotation release first (`troupe update --version`). Separate signature files
per key were the other way, and would have had every client look for a file named after its
own key.

## `troupe update`

- **Where from.** `TROUPE_RELEASE_URL`, when set, is one release's assets, as the installers
  read it; `file://` works too. Otherwise GitHub's: the latest release is the tag
  `/releases/latest` redirects to, `--version X` is `vX`. The plane serving the assets is
  later work (#66 slice 1b and after).
- **What is checked.** The manifest and its signature are fetched first, and nothing else
  until the signature holds and the manifest names the version asked for (or the tag the
  redirect named): an older signed manifest served in a newer one's place is refused. Each
  artifact is downloaded beside what it replaces and checked, size then sha256, before
  anything is replaced. The latest release replaces only what is older; a version asked for
  by name replaces whatever is not it.
- **The swap.** The TUI's binary: on Unix the old file is hard-linked to `troupe.previous`
  and the new one renamed over it, so `troupe` is never missing; on Windows the running
  `troupe.exe` is renamed aside to `troupe.exe.previous` first, as `install-local.ps1` does,
  and a `.previous` a terminal still runs is set aside as `.in-use-<time>` for a later update
  to remove. The daemon's release directory is unpacked beside the old one and renamed into
  its place, the old one kept as `troupe-daemon.previous`; a directory cannot be swapped in
  one rename, so for a moment between two renames it is not there. These are the installers'
  names, so `install-local.ps1 -Rollback` and `troupe update --rollback` agree. `--rollback`
  swaps each back, and again forward.
- **The daemon, never under a running turn: the update waits.** It is replaced only once it
  has stopped, and it is asked to stop with `daemon.stop`, which stops it when no session has
  a turn at work and otherwise names the sessions that do. `troupe update` asks again every
  two seconds, saying what it waits for when that changes, until none has; Ctrl-C while it
  waits changes nothing, since nothing is replaced before the daemon has gone. Waiting rather
  than asking: a turn ends on its own, and an update that asked would ask a question whose
  only safe answer is to wait. "At work" is the session sweep's own reading (Decision 848):
  idle, done, or waiting on a person is not at work, because each is durable in its log.
  The daemon a TUI runs inside itself is that TUI's and says so; it is left running, and the
  installed release is replaced under it. A daemon from before `daemon.stop` cannot be stopped
  between turns from here, so the update stops with nothing changed and says what to do. The
  restart and resume beyond that is #66's next slice.
- **Not here.** Pre-releases are not signed (their workflow runs on any branch, by hand), so
  `troupe update` refuses them. A machine with the daemon and no `troupe` has no updater yet:
  `troupe-daemon` runs from the directory it would replace, which Windows does not allow.
  The desktop app's updater and OS code signing are later slices.

## The installers

`install.sh` and `install.ps1` attached to a release carry its current key
(`scripts/release-installers` writes it in, as it writes the version). Where `minisign` is on
the PATH they check the manifest's signature with it and then each file against the manifest
as well as `SHA256SUMS`, and a release with no manifest is refused. Without a key or without
minisign they say plainly that only `SHA256SUMS` is checked, and what that does not catch.
`scripts/check-installers` and `scripts/check-installers.ps1` cover both, with minisign
stand-ins.

## Proof

- `test/fixtures/release/` holds the shared vectors (`scripts/release-vectors.exs`, keys made
  and thrown away as it runs): a rotation read by an old client, a new one and one trusting
  both; a changed manifest, another key, a changed trusted comment, an empty and a broken
  `.minisig`, a client with no key; a changed and a short artifact. `vectors_test.exs` runs
  them; a separate verifier written from minisign's format in Python agreed on all of them,
  and the Elixir verifier and signer agreed with it the other way, including a secret key
  with minisign's own checksum.
- `update_test.exs` installs, rolls back and forward on both swaps, and refuses a changed
  artifact, a changed manifest, another key, no signature, no manifest, no key and the
  wrong version, each with nothing changed. `daemon_stop_test.exs` and
  `update_stop_test.exs` hold the daemon to stopping only between turns.
