---
number: 865
title: A release's manifest is signed with one minisign key held by CI, every client is built with its public half, and troupe update installs only what that key signed, replacing the daemon between turns
date: 2026-10-11
status: accepted
issue: 66
paths:
  - apps/troupe_core/lib/troupe/release/keys.ex
  - apps/troupe_core/lib/troupe/update.ex
  - scripts/release-manifest.exs
  - install.sh
  - install.ps1
symbols:
  - Troupe.Release.Minisign
  - Troupe.Release.Manifest
  - Troupe.Release.Keys
  - Troupe.Update
gist: "Release keys are compiled in from priv/release-keys.txt, never added at run time; nothing unverified is installed; the daemon is replaced only once it stops between turns"
---

The maintainer decided the shape on 2026-10-11: releases are signed with a minisign key,
one Ed25519 key held by CI in the `release` environment; each release gets a signed
`manifest.json`; the clients carry the public key and check the manifest and each file's
sha256 before they swap a binary; a key rotation is a release signed with both keys; and
nothing unverified is ever installed. This records how.

## The release key

- **Where it lives.** The secret half is the `release` environment's secret
  `RELEASE_MINISIGN_KEY`: the key file as `minisign -G -W` writes it, unencrypted, since
  the environment is its protection and a password would be a second secret beside it.
  Nothing in this repository creates, stores or prints a real key.
- **The public half** is a line in `apps/troupe_core/priv/release-keys.txt`, the first
  line being the current key. `Troupe.Release.Keys` reads the file when it is compiled, so
  a client trusts exactly the keys of the commit it was built from. No setting,
  environment variable or file read at run time adds a key, and a test hands its own
  throwaway key to the function it calls. That is the line not to undo: a knob to trust
  another key is a knob for whoever can turn it.

## The manifest

`scripts/release-manifest.exs` writes it in the `publish` job over everything attached,
and signs it into `manifest.json.minisig`. The script refuses, and the release stays a
draft, when the secret is not set, is encrypted, or is not the first key in the list; and
it checks its signature with the clients' verifier against the list before it writes
anything.

## A key rotation

A `.minisig` holds one signature block; this one may hold several, one per key, the
current key's first. The `minisign` program reads the first block only, so it checks the
current key, which is the key the installers attached to that release carry. The verifier
accepts a manifest when at least one block is by a key it trusts and every block by a key
it trusts holds; a block by a key it does not know is passed over.

## `troupe update`

- **What is checked.** The manifest and its signature are fetched first, and nothing else
  until the signature holds and the manifest names the version asked for (or the tag the
  redirect named): an older signed manifest served in a newer one's place is refused. Each
  artifact is downloaded beside what it replaces and checked, size then sha256, before
  anything is replaced.
- **The daemon, never under a running turn: the update waits.** It is replaced only once
  it has stopped, and it is asked to stop with `daemon.stop`, which stops it when no
  session has a turn at work and otherwise names the sessions that do. `troupe update`
  asks again every two seconds, saying what it waits for when that changes, until none
  has; Ctrl-C while it waits changes nothing, since nothing is replaced before the daemon
  has gone.
