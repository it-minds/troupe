# Installing the desktop GUI, while it is unsigned

The installers are **not signed**. That is a decision, not an oversight: signing costs
money and weeks of identity validation, and neither is worth spending before the app is
worth installing. Every hook signing needs is already in the repository and switched off —
see *Turning signing on*, at the end.

Until then every operating system will object, and the objection is correct. An unsigned
installer carries no proof of who built it. The installers are attached to each release
of this repository (the `desktop` job of `native.yml`, which the root `release.yml`
calls), beside a `SHA256SUMS` over everything in the release: check the SHA-256 against it
before you run one, and do not hand these to anyone outside the team.

```sh
# what the release says it contains, against what you downloaded
shasum -a 256 ~/Downloads/Troupe_0.1.0_universal.dmg     # macOS, Linux
certutil -hashfile Troupe_0.1.0_x64-setup.exe SHA256     # Windows
```

---

## Windows

SmartScreen shows **"Windows protected your PC"** and hides the Run button behind a link.

1. Right-click the downloaded `.exe` → **Properties** → tick **Unblock** → OK.
   This clears the mark-of-the-web and is usually enough on its own.
2. If SmartScreen still appears: **More info** → **Run anyway**.

From PowerShell, step 1 is:

```powershell
Unblock-File .\Troupe_0.1.0_x64-setup.exe
```

The installer is per-user (`installMode: currentUser`), so it needs no administrator. It
installs into `%LOCALAPPDATA%\Programs\troupe-desktop`. One from before 0.5.2 installed
into `%LOCALAPPDATA%\Troupe`, which Windows, ignoring case, reads as the daemon's state
directory `%LOCALAPPDATA%\troupe`; a newer one moves the app out of it and leaves the
sessions where they are. It will fetch the WebView2 runtime if Windows does not already
have it; every Windows 11 and most Windows 10 machines do.

## macOS

Gatekeeper refuses an unsigned, un-notarised app, and on recent macOS the old
Control-click-and-Open shortcut no longer works for one.

1. Open the `.dmg` and drag **Troupe** to Applications as usual.
2. Launch it once. macOS says it cannot verify the developer, and refuses.
3. **System Settings → Privacy & Security**, scroll to the bottom, and click
   **Open Anyway** next to the message about Troupe. Confirm.

If the app reports that it is **damaged and should be moved to the Bin**, that is the
quarantine attribute rather than a real problem, and this removes it:

```sh
xattr -dr com.apple.quarantine /Applications/Troupe.app
```

Run that only on a build whose checksum you have checked. It is exactly the step
notarisation exists to make unnecessary.

## Linux

Nothing blocks an unsigned build here; there is no signature to miss.

```sh
# AppImage — self-contained, needs only the executable bit
chmod +x Troupe_0.1.0_amd64.AppImage
./Troupe_0.1.0_amd64.AppImage

# Debian, Ubuntu
sudo apt install ./Troupe_0.1.0_amd64.deb

# Fedora, RHEL
sudo dnf install ./Troupe-0.1.0-1.x86_64.rpm
```

The build targets Ubuntu 22.04's glibc and WebKitGTK 4.1. It runs on anything that old
or newer; on anything older it will not start, and the AppImage is the only format that
might be made to.

---

## What you get and what you do not

Working: everything the browser build does, plus the one thing it cannot — the refresh
token kept outside the page, in `credentials.json` in your Troupe config directory
(`~/.config/troupe`, `%APPDATA%\troupe` on Windows), readable by your account alone, so
a relaunch does not mean signing in again. It is the file `troupe login` writes, so the
terminal client and the desktop app share one sign-in, and a machine signed in by the
installer opens the app signed in and at that plane. A sign-in an earlier release kept in
the operating system's credential store is moved there at the next launch. The sign-in
screen says where it is kept, so there is no guessing.

The shell also runs the *device* grant rather than the browser build's authorization-code
flow: a desktop app has no redirect to come back from, and the device grant is exactly
right for one.

From 0.15.0 the app updates itself, only from a release the release key signed
([updating](../../../docs/user/updating.md#the-desktop-app)); one older than that is
updated once by its installer.

---

## Turning signing on

Nothing in the build needs to change. `src-tauri/tauri.signing.conf.json` holds the
signing configuration and is applied only when CI passes `--config` at it: in a release
(`native.yml` with `sign: release`) where the matching secret exists in the `release`
environment, `AZURE_ENDPOINT` turning Windows signing on and `APPLE_CERTIFICATE` macOS's,
and in the self-signed test of it (`signing.yml`). On Windows its sign command is
`scripts/signing/sign-windows.ps1`. What to buy and what each needs first are in
[code-signing.md](../../../docs/developer/code-signing.md); every secret and the day's
runbook in [signing-day.md](../../../docs/developer/signing-day.md). Which
releases are signed is said in one place,
[security.md §6](../../../docs/admin/security.md#6-the-apps-are-not-os-code-signed). Expect
SmartScreen to keep warning for the first signed releases: reputation accrues from
downloads, not from a certificate.

On macOS, signing turns on the hardened runtime and `entitlements.plist`, which gives
WKWebView back the JIT the hardened runtime takes away. Nothing else is in that file, and
nothing else should be.

### The updater

It needs no key of its own: the release key signs the update payloads too
([Decision 874](../../../docs/decisions/0874-the-desktop-app-updates-itself-from-a-release-the-release-key-signed.md)).
On Linux it updates the AppImage; it cannot replace a file `apt` or `dnf` owns.
