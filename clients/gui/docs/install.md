# Installing the desktop GUI, while it is unsigned

The installers are **not signed**. That is a decision, not an oversight: signing costs
money and weeks of identity validation, and neither is worth spending before the app is
worth installing. Every hook signing needs is already in the repository and switched off —
see *Turning signing on*, at the end.

Until then every operating system will object, and the objection is correct. An unsigned
installer carries no proof of who built it. The installers are attached to each release
of this repository (the `desktop` job of the root `release.yml`), beside a `SHA256SUMS`
over everything in the release: check the SHA-256 against it before you run one, and do
not hand these to anyone outside the team.

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
token in the operating system's credential store, so a relaunch does not mean signing in
again. The sign-in screen says which store it got, so there is no guessing.

The shell also runs the *device* grant rather than the browser build's authorization-code
flow: a desktop app has no redirect to come back from, and the device grant is exactly
right for one.

Not here: automatic updates. Adding the updater means a minisign keypair, which is
a signing decision, so it waits for the same moment signing does. Until then a new version
means downloading a new installer.

---

## Turning signing on

Nothing in the build needs to change. `src-tauri/tauri.signing.conf.json` holds the
signing configuration and is applied only when CI passes `--config` at it, which happens
when the matching secret exists. Set the secrets and the next run is signed.

### Windows

Buy one of:

| | cost | catch |
| --- | --- | --- |
| Azure Artifact Signing (was Trusted Signing) | from $9.99/month | US, Canadian, EU or UK entities and self-employed individuals only; organisation validation wants three or more years of verifiable tax history, so a young entity does not qualify |
| an EV certificate on a token or HSM | $300–700/year | you hold the hardware, and CI needs a cloud HSM to reach it |

The repository assumes the first. `tauri.signing.conf.json` calls `trusted-signing-cli`,
which CI installs; the secrets are `AZURE_ENDPOINT`, `AZURE_CODE_SIGNING_NAME`,
`AZURE_CERT_PROFILE_NAME`, and a service principal's `AZURE_CLIENT_ID`,
`AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`. Setting `AZURE_ENDPOINT` is what flips the
workflow's `signed` flag.

Expect SmartScreen to keep warning for the first releases regardless. Reputation is
accrued from downloads, not bought with a certificate.

### macOS

Apple Developer Program, $99/year. Export the **Developer ID Application** certificate as
a `.p12`, base64 it, and set `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD` and
`APPLE_SIGNING_IDENTITY`. For notarisation use an App Store Connect API key rather than an
Apple ID and app-specific password: `APPLE_API_ISSUER`, `APPLE_API_KEY`,
`APPLE_API_KEY_PATH`. Setting `APPLE_CERTIFICATE` flips the flag.

Signing turns on the hardened runtime and `entitlements.plist`, which gives WKWebView back
the JIT the hardened runtime takes away. Nothing else is in that file, and nothing else
should be.

### The updater, whenever it arrives

A third key, unrelated to the two above: `pnpm tauri signer generate` produces a minisign
pair that signs the update payloads. Public half into `tauri.conf.json`, private half and
its password into `TAURI_SIGNING_PRIVATE_KEY` and `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`.
Keep the update feed public — an installer is not a secret, the plane's authentication is —
and remember that the Tauri updater cannot replace a file `apt` or `dnf` owns, so Linux
updates through the package manager or through the AppImage, not both.
