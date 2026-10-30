---
number: 972
title: "troupe update and the desktop updater choose between two targets: the version the plane recommends, the default, and with --latest the newest release whose signed manifest says it supports the plane's version, still never one the plane blocks or holds below its minimum"
date: 2026-10-29
status: accepted
paths:
  - COMPATIBILITY
  - scripts/release-manifest.exs
  - scripts/release
  - apps/troupe_protocol/lib/troupe/release/manifest.ex
  - apps/troupe_core/lib/troupe/update.ex
  - clients/tui/lib/troupe/cli.ex
  - clients/tui/lib/troupe/cli/doctor.ex
  - clients/tui/lib/troupe/remote/discovery.ex
  - clients/gui/apps/desktop/src-tauri/src/release.rs
  - clients/gui/apps/desktop/src-tauri/src/update.rs
  - clients/gui/apps/desktop/src/updates.ts
  - clients/gui/apps/desktop/src/views/Update.tsx
  - docs/user/updating.md
symbols:
  - Troupe.Release.Manifest.compatibility/1
  - Troupe.Release.Manifest.supports?/2
  - Troupe.Update.doctor_check/1
gist: "The release says which planes it supports, signed in its manifest from COMPATIBILITY; --recommended stays the default; --latest passes over unknown, unsupported and blocked releases and stops at the minimum"
---

Extends 865 (releases are signed, and nothing unverified is installed) and 868 (a plane
holds each kind of client to a recommended version, a minimum and a blocked list). Under
868 a person signed in to a plane could install the recommended version, or name one with
`--version` and hope: nothing said whether a newer release worked with their plane, so a
developer who wanted to run ahead of IT's recommendation learnt it from the plane's
refusal, or from a method that was not there, after the install.

- **The release says what it supports, in its signed manifest.** `manifest.json` gains
  `"supports": {"plane": "<requirement>", "protocol": "1"}`, written by
  `scripts/release-manifest.exs` from the root `COMPATIBILITY` file and signed with the
  rest, so a client takes it on the release key's word, as it takes the files. Format
  stays 1: the field is added, and a manifest without it encodes to the bytes it always
  did. A requirement is comparisons joined by `and`, each `>=`, `>`, `<=`, `<` or `==` and
  a version, ordered as SemVer orders them, a subset small enough that the Elixir
  (`Version.match?/3`) and the Rust (`release::requirement_holds`) readers agree on every
  answer. The plane's version is its discovery document's `plane.build.version`.
- **A manifest without `supports` is unknown, not universal.** Every release before this
  has none; reading that as "supports every plane" would make `--latest` install exactly
  the releases nobody checked. They are passed over, said, except the recommended one,
  which the plane's word already covers, so `--latest` can always fall back to it.
- **`--recommended` is the default.** A person who never thinks about versions runs
  `troupe update`, or presses **Update**, and lands on the one their IT supports.
  `--latest` and the desktop app's quieter **Newest supported (X)** are asked for.
- **`--latest` is still held to the plane's minimum and blocked list.** The plane
  refuses such a client at `initialize`; checking before the install is the only time the
  check helps. A blocked release is passed over for the next; one below the minimum ends
  the look, since every older one is too. It never looks past the recommended version:
  from there down the plane's word is the better one. It looks at twenty releases at most,
  and says so when it stops.
- **`--version X` is unchanged**: still refused where the plane blocks X or holds it
  below its minimum. There is no `--force`, and this adds none.
- **`troupe doctor` says it, never as a failure.** Being on the recommended version is
  where a person should be; a newer supported one is information.
- **Where the list comes from.** GitHub's releases list (drafts out, pre-releases in, since
  a beta is published as one), or the one release `TROUPE_RELEASE_URL` names. A plane's
  own mirror is found by version and lists nothing, so there `--latest` asks for a version.

**Raising the minimum plane** is the change that needs it: when a client starts calling a
method or reading a field an older plane lacks, the same pull request raises `plane >=`
in `COMPATIBILITY` (docs/developer/ci.md, "What a release supports").

Choices not taken:

- **A compatibility file on GitHub beside the releases, outside the signed manifest.**
  Easier to correct after the fact, but anybody who can change a release page, or a
  mirror, could then say an old or broken release supports a plane; the manifest is the
  one thing every client already verifies, so the claim lives there.
- **`--latest` as the default.** It would put a person who never asked on a version their
  IT has not chosen; the recommendation exists to be the default.
- **Letting `--latest` ignore the plane's minimum and blocked list.** The plane would
  refuse the client when it connects, after the old one was replaced; a person asking for
  the newest still wants one that works.
