# Signing a release, the day the certificates exist

The operator's runbook for the day the organisation's Apple and Microsoft certificates
exist: what to put where, how to check the first signed release, and what to do when a
service refuses it. What to buy and how long it takes is [code-signing.md](code-signing.md).

Everything but the certificates is in the repository and runs on every change to it
([Decision 938](../decisions/0938-os-signing-is-wired-off-until-the-secrets-exist-and-signs-everything-a-payload-unpacks.md)).
On the day, a repository admin puts the twelve secrets below into the `release`
environment, and the next release is signed. No workflow, script or document changes
first; afterwards one paragraph of the docs does ([below](#after-the-first-signed-release)).

## What signs what

`release.yml` calls `native.yml` with `sign: release`. Each macOS and Windows build then
signs every executable and library its artifact holds or unpacks, because Gatekeeper and
Smart App Control check each one, then signs the artifact, then checks what it made.

| `native.yml` job | what is signed, and how | checked in the job by |
| --- | --- | --- |
| `daemon`, macOS | every Mach-O in the release (the ERTS programs, `beam.smp`, every NIF), with the hardened runtime, a secure timestamp and [`beam.entitlements`](../../scripts/signing/beam.entitlements), by `Troupe.Release.OSSigning` before `:tar` packs it; then the tree is notarised | `sign-macos.sh --verify` on the unpacked archive; the smoke test runs the signed files |
| `daemon`, Windows | every PE file in the release that carries no valid signature yet, before `:tar`, with `artifact-signing-cli`; the Erlang runtime's own are Ericsson AB's already, so about three are signed | `sign-windows.ps1 -Verify` on the unpacked archive |
| `tui`, macOS and Windows | every Mach-O or PE file in Burrito's payload, after Burrito's patch phase puts the target's ERTS in it and before it is packed (on Windows the unsigned ones, about five); then the `troupe` binary; on macOS it is notarised | the same, on the binary and on the payload it unpacks on its first run |
| `desktop`, macOS | Tauri: the app with the hardened runtime and `entitlements.plist`, notarised and stapled; the updater's `Troupe_<version>_universal.app.tar.gz` is packed afterwards, from the stapled app, and is the only app archive kept | `codesign --verify --deep --strict`, `spctl --assess`, `xcrun stapler validate` |
| `desktop`, Windows | Tauri, through the sign command in `tauri.signing.conf.json`, which is `sign-windows.ps1`: the app's executable, the NSIS setup and its uninstaller, the MSI | `sign-windows.ps1 -Verify`; what the setup unpacks is listed beside it |
| Linux targets | nothing: Linux has no OS signature to add | — |

The scripts are in `scripts/signing/`. The order around them
does not change: `publish` writes `manifest.json`, the desktop update's `.sig` files and
`SHA256SUMS` over what `native.yml` attached, which is the OS-signed files, and the release
key signs the manifest
([Decision 865](../decisions/0865-releases-are-signed-and-troupe-update-installs-only-what-the-release-key-signed.md)).
OS signing is in addition to the release key, and Troupe's own check is still the release
key's.

Until the secrets exist, a release builds unsigned and its run's summary says so, one line
per artifact (`troupe-daemon macos_aarch64: unsigned: APPLE_CERTIFICATE not set`); it never
fails for that. A platform whose first secret is set and another is not fails the release,
naming what is missing, so half a set is fixed rather than shipped unsigned. To release one
platform signed and the other not, leave the other's first secret out.

## How it is tested without Apple or Microsoft

[`signing.yml`](../../.github/workflows/signing.yml) runs `native.yml` with `sign:
self-signed` on a pull request that changes the signing scripts, `Troupe.Release.OSSigning`,
`tauri.signing.conf.json` or `native.yml`: the daemon, the TUI and the desktop app on one
Mac and on Windows, through exactly the release's steps, with a certificate made in the job
(`macos-keychain.sh self-signed`, `test-certificate.ps1`), `codesign` and `signtool` in place
of the services, and no notarisation. Every check above runs. Then the manifest a release
would publish is made over those files with a throwaway release key and held to what each
build recorded it signed (`scripts/signing/check-manifest.exs`). Two things only the first
real release proves: notarisation, and that the BEAM runs under the hardened runtime with
`beam.entitlements` alone (the test adds `disable-library-validation`, because its
certificate has no Apple team).

## The secrets

Each goes into **Settings → Environments → release → Environment secrets**, beside
`RELEASE_MINISIGN_KEY`, never into repository secrets.

| secret | what goes in it | where it comes from |
| --- | --- | --- |
| `APPLE_CERTIFICATE` | the base64 of the Developer ID Application `.p12`; turns macOS signing on | [code-signing.md §2](code-signing.md#the-certificate), steps 1 to 3 |
| `APPLE_CERTIFICATE_PASSWORD` | the `.p12`'s export password | the same export |
| `APPLE_SIGNING_IDENTITY` | `Developer ID Application: <legal name> (<team id>)` | `security find-identity -v -p codesigning` |
| `APPLE_API_ISSUER` | the Issuer ID above the Team Keys table | [code-signing.md §2](code-signing.md#notarisation): App Store Connect, Users and Access, Integrations |
| `APPLE_API_KEY` | the team key's Key ID | the same page |
| `APPLE_API_PRIVATE_KEY` | the text of the key's `.p8` file, which downloads once | the same page |
| `AZURE_ENDPOINT` | the Artifact Signing account's regional endpoint, such as `https://weu.codesigning.azure.net`; turns Windows signing on | [code-signing.md §3](code-signing.md#setting-up-artifact-signing), step 3 |
| `AZURE_CODE_SIGNING_NAME` | the Artifact Signing account's name | step 3 |
| `AZURE_CERT_PROFILE_NAME` | the Public Trust certificate profile's name | step 5 |
| `AZURE_TENANT_ID` | the Entra tenant's ID | step 1 |
| `AZURE_CLIENT_ID` | the app registration's client ID | step 6 |
| `AZURE_CLIENT_SECRET` | the app registration's client secret | step 6 |

## Once, before the first signed release

- **Apple:** the organisation's Developer ID Application certificate exported with its key
  ([code-signing.md §2](code-signing.md#the-certificate)), and a team API key with the Developer access
  ([notarisation](code-signing.md#notarisation)). Nothing on a runner: each macOS job makes a keychain of
  its own from the `.p12` (`scripts/signing/macos-keychain.sh release`) and removes it at
  the end.
- **Microsoft:** the Artifact Signing account, a completed identity validation, the
  certificate profile, and the app registration with the **Artifact Signing Certificate
  Profile Signer** role and a client secret ([code-signing.md §3](code-signing.md#setting-up-artifact-signing)).
  The Windows jobs install `artifact-signing-cli` themselves.
- **GitHub:** the twelve secrets, in the `release` environment, which keeps its main-only
  rule.

## Checking the first signed release

1. **The run.** Its summary has a line per artifact with the number of files signed and
   by whom, and "notarised" for each macOS one. A build that signed nothing, or a file
   left out, fails its job, and the release stays a draft.
2. **A Mac that has never seen Troupe.** Download the `.dmg` in a browser, so that it is
   quarantined, and install as a person would. It opens after the usual question about an
   app from the internet. Then:

   ```sh
   spctl --assess --type execute --verbose=4 /Applications/Troupe.app   # accepted, source=Notarized Developer ID
   xcrun stapler validate /Applications/Troupe.app
   codesign -dv --verbose=4 ~/.local/bin/troupe 2>&1 | grep Authority   # Developer ID Application: <legal name>
   spctl --assess --type execute --verbose=4 ~/.local/bin/troupe
   ```

3. **A fresh Windows 11 virtual machine with Smart App Control on** (it is on only on a
   clean install). Download the setup in a browser and run it, then `install.ps1` for the
   daemon and the TUI, and run `troupe --version` and `troupe-daemon version`. Nothing is
   blocked. Then:

   ```powershell
   Get-AuthenticodeSignature $env:LOCALAPPDATA\Programs\troupe\troupe.exe,
     (Get-ChildItem $env:LOCALAPPDATA\Programs\troupe-daemon -Recurse -Include *.exe, *.dll),
     (Get-ChildItem $env:APPDATA\.burrito -Recurse -Include *.exe, *.dll) |
     Group-Object Status   # every one Valid, signed by the organisation
   ```

   SmartScreen may still warn about the setup for the first signed releases: its reputation
   grows from downloads, not from the certificate.

## After the first signed release

[security.md §6](../admin/security.md#6-the-apps-are-not-os-code-signed) says, in one
place, from which release on the apps are signed. Put that release's version there, and
drop the workaround paragraphs it points at: security.md §6's own, the "while it is
unsigned" parts of [the desktop app's install page](../../clients/gui/docs/install.md), and
the unsigned notes in [installing.md](../admin/installing.md#the-clients-people-install) and
[the quick start](../quick-start.md#1-install). The
installers need no change: they print their note only for a program that carries no
signature.

## When notarisation is rejected

The job fails with Apple's log of the submission (`notarytool log`), and the release stays
a draft: `publish` never runs.

- **What the log says** is per file. A file without the hardened runtime or a secure
  timestamp, or one not signed at all, is a file the signing missed: the job's `--verify`
  step should have failed first, so add the case to `sign-macos.sh` and its check. A
  `get-task-allow` entitlement is a debug build; none of ours carry one.
- **An invalid or revoked certificate, or an expired API key,** is fixed in the
  environment's secrets. Then re-run the failed jobs of the same run: the tag and the draft
  release are already there, and the build is the same commit.
- **A fix in the repository** is a new release, since the tag of this one is cut. Delete
  the draft release and its tag first, or leave the draft and release the next version.
- **The BEAM does not start once signed** (the smoke test after signing fails, often with a
  library refused or a JIT mapping denied): the entitlement it needs goes into
  `beam.entitlements`, `disable-library-validation` or `allow-unsigned-executable-memory`,
  one at a time and only as the smoke test proves it; say why in that file.
- **Apple's service itself** is slow or down: `xcrun notarytool history` with the same key
  shows the submissions; `submit --wait` gives up after 30 minutes, and a re-run of the
  failed jobs resubmits.

On Windows the same holds for a signing failure: `artifact-signing-cli` names the cause (a
role missing on the profile, an identity validation that lapsed, the endpoint of another
region), the fix is in Azure or in the secrets, and the failed jobs are re-run.
