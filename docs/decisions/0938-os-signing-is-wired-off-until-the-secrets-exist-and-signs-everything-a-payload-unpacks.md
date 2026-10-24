---
number: 938
title: OS code signing is in addition to the release key's, off until the release environment holds the certificates, and signs every executable a payload unpacks, before the manifest is made
date: 2026-10-24
status: accepted
issue: 656
paths:
  - .github/workflows/native.yml
  - .github/workflows/release.yml
  - .github/workflows/signing.yml
  - .github/workflows/ci.yml
  - .github/workflows/dev-check.yml
  - scripts/signing/
  - apps/troupe_core/lib/troupe/release/os_signing.ex
  - apps/troupe_core/test/troupe/release/os_signing_test.exs
  - apps/troupe_core/test/troupe/release/signing_workflow_test.exs
  - apps/troupe_daemon/mix.exs
  - clients/tui/mix.exs
  - clients/gui/apps/desktop/src-tauri/tauri.signing.conf.json
  - install.sh
  - install.ps1
  - docs/developer/code-signing.md
  - docs/developer/signing-day.md
  - docs/admin/security.md
  - clients/gui/docs/install.md
symbols:
  - Troupe.Release.OSSigning
gist: "native.yml signs only with sign: release (release.yml), in the release environment; absent secrets build unsigned and say so; every Mach-O/PE a payload unpacks is signed before it is packed; signing.yml tests it self-signed"
---

#656 asks for the desktop app and the `troupe` and `troupe-daemon` binaries to be signed and
notarised on macOS and code-signed on Windows. The certificates are not procured yet, and
the maintainer decided on 2026-10-24 (on #765) that everything but them is built and tested
now, with signing off by default, so that the day the `release` environment holds the
secrets nothing else changes. Writing the procurement guide had found four things in the
way (#656's comment): the secrets did not reach the native builds, tauri-action wants the
App Store Connect key as a file, the Windows signing tool was renamed, and Smart App
Control checks every executable rather than only the one downloaded.

## In addition to the release key, never instead

Troupe's own check stays the release key's (Decision 865): every client verifies the
signed manifest before it installs anything. An OS signature tells macOS and Windows who
built a file; it is added on top. Signing changes a file's bytes, so it happens in
`native.yml`, before `publish` writes `manifest.json`, the desktop update's `.sig` files and
`SHA256SUMS` over what was attached: the release key signs the OS-signed files, and nothing
in the manifest's flow changes.

## Off unless a release asks, and the secrets reach only it

Environment secrets reach only a job that names the environment, and the `release`
environment takes jobs from `main` only. So `native.yml` takes a `sign` input:

- **empty** (the nightly, a pre-release, a pull request, a dispatch): no signing step runs
  and no secret is read; nothing names the environment.
- **`release`**, which `release.yml` alone passes: a small `signing` job and the macOS and
  Windows build jobs name `release`. The `signing` job sees which of the twelve secrets are
  set, never their values (`scripts/signing/ci.sh plan`). A platform whose first secret
  (`APPLE_CERTIFICATE`, `AZURE_ENDPOINT`) is absent builds unsigned and the summary says so,
  one line per artifact; that is every release until the certificates exist, and it never
  fails for it. A platform whose first secret is set and another is not fails, naming what
  is missing: half a set of secrets is a mistake, not a release to ship unsigned.
- **`self-signed`**, which `signing.yml` passes: the same steps with a certificate made in
  the job, on one Mac and on Windows (below).

A step that reads a signing secret asks for a release in its own condition or expression,
and the unsigned builds keep their own steps, so they cannot see the names at all (tauri-action
reads an empty `APPLE_CERTIFICATE` as one to import). `signing_workflow_test.exs` holds the
workflows to all of this.

## Everything a payload unpacks

Gatekeeper and Smart App Control check each program and library as it is loaded, so
signing the downloaded file is not enough: `troupe-daemon` carries about 25 PE files on
Windows and `troupe.exe`'s Burrito payload, unpacked under `.burrito` on first run, about 57.

- **`Troupe.Release.OSSigning`** runs the platform's script over a directory when
  `TROUPE_SIGN` names it: as a `mix release` step between the licences and `:tar` for the
  daemon, and as a Burrito step after the patch phase, once the target's ERTS is in the
  payload and before it is packed, for the TUI. Without `TROUPE_SIGN` a build is what it
  was.
- **The scripts find what to sign by its contents, not its name**: `sign-macos.sh` takes
  every file `file` calls Mach-O and signs it with the hardened runtime, a secure timestamp,
  and for programs `beam.entitlements`; `sign-windows.ps1` takes every file with a PE
  header and signs it with `artifact-signing-cli` (the renamed `trusted-signing-cli`) or,
  for the test, `signtool`. A file already validly signed, one Microsoft made say, is left
  alone. Then the binary itself is signed, and on macOS the binary and the daemon's tree are
  notarised; a standalone binary cannot carry a stapled ticket, so Gatekeeper looks it up.
- **The desktop app** is Tauri's to sign: the app with the hardened runtime and its own
  `entitlements.plist`, notarised and stapled, on macOS; on Windows the sign command in
  `tauri.signing.conf.json` is `sign-windows.ps1`, given in the object form because Tauri
  runs it without a shell (the old one passed `%AZURE_ENDPOINT%` to the tool unexpanded).
  The `.p8` key goes in as `APPLE_API_PRIVATE_KEY` and the job writes it to a file for
  `APPLE_API_KEY_PATH`.
- **Each build checks what a person unpacks**, not what it signed: the daemon's archive
  unpacked, and the TUI's binary with the payload it unpacked on its smoke run, every
  Mach-O carrying a hardened-runtime signature by the expected authority and every PE file a
  valid one. The count goes into the run's summary.

The BEAM needs `allow-jit` under the hardened runtime and nothing else that we know of:
every NIF is signed by the same Developer ID, which library validation asks. The self-signed
test adds `disable-library-validation` (`beam-test.entitlements`), since its certificate has
no team. Should the first signed release's smoke test, which runs the signed files, prove
another entitlement necessary, it goes into `beam.entitlements` then, with the reason.

## Tested without Apple or Microsoft

`signing.yml` runs on a pull request that changes `scripts/signing/`, `os_signing.ex`,
`tauri.signing.conf.json`, `native.yml` or itself, from `ci.yml` and from `dev-check.yml`.
It calls `native.yml` with `sign: self-signed`: a certificate made in the job
(`macos-keychain.sh self-signed`, falling back to an ad hoc signature where the runner's
codesign refuses an untrusted certificate, and saying so; `test-certificate.ps1 -Trust`,
which trusts it on that throwaway runner only), the stand-ins `codesign` and `signtool`,
and no notarisation. Every check of a release runs. Then
`scripts/signing/check-manifest.exs` makes the manifest over the uploaded files with a
throwaway release key, as `publish` does, verifies it, and holds it to what each build
recorded it signed: every signed file is in it with its signed sha256, and every Mac or
Windows file in it was signed. What only a real release proves is notarisation and the
BEAM under a Developer ID with `beam.entitlements` alone.

## The installers and the docs

`install.sh` prints its Gatekeeper note only for a program that is quarantined and has no
Developer ID signature, and `install.ps1` its SmartScreen note only when a program it
installed has no valid signature, so they are right before and after the first signed
release without an edit. The docs say which releases are signed in one place,
`docs/admin/security.md` §6 ("none yet"), and `docs/developer/signing-day.md` is the runbook
for the day: the secrets, the one-time setup, how to check the first signed release
on a fresh Mac and a fresh Windows machine with Smart App Control on, which paragraphs to
drop afterwards, and what to do when notarisation is rejected.
