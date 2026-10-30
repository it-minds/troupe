# Updating Troupe

`troupe update` replaces what the installers put on your machine with a newer release:
`troupe`, `troupe-daemon`, and the desktop app and the VS Code extension where you
installed those, after checking that the release is one Troupe's release key signed.
Nothing it cannot check is installed. The desktop app's own update does the same the other
way round, replacing `troupe-daemon`, `troupe` and the extension beside it. An install
picks its components once; from then on one update, from either side, moves all of them.

```sh
troupe update --check            # what is installed, the release, and what an update would do
troupe update                    # install the version your plane recommends, or the latest release
troupe update --latest           # install the newest release that supports your plane
troupe update --version 0.13.0   # install that release, older or newer
troupe update --rollback         # put back what the last update replaced
```

`troupe update` on its own is `troupe update --recommended`: signed in to a plane, the
version its administrators recommend. That is the one to run unless you know you want
something newer ([below](#recommended-or-latest)).

## What it does

1. **Finds the release.** The latest is the one GitHub's releases page calls the latest;
   `--version` names another. `TROUPE_RELEASE_URL` points it at a mirror instead: one
   release's files, at an `https://`, `http://` or `file://` address, as the installers read
   it.
2. **Checks its signature.** It downloads the release's `manifest.json` and
   `manifest.json.minisig` first. The manifest names every file of the release, with its
   size and its sha256, and the signature has to be by a key this build of troupe carries.
   A release with no manifest, no signature, or another key's, is refused, and so is a
   manifest of another version than the one asked for. Releases before 0.13 and pre-releases
   are not signed, so `troupe update` does not install them; their own installers do.
3. **Downloads and checks each file.** The troupe and the troupe-daemon built for your
   machine, each next to what it replaces and each held to the manifest. One that is not as
   the manifest says stops the update before anything is replaced.
4. **Waits for the daemon.** The daemon is replaced only once it has stopped, and it stops
   only between turns. If a session has a turn at work, `troupe update` says which project it
   is in and waits for it, asking again every two seconds; Ctrl-C while it waits leaves
   everything as it was. Sessions that are idle, or waiting for your answer, are not at work:
   they pick up where they were when the daemon next starts, which the next client does. A
   daemon a running `troupe` started inside itself belongs to that `troupe`, and is left
   alone.
5. **Swaps them in.** The new `troupe` takes the old one's place in one step, and the old
   one is kept as `troupe.previous` (`troupe.exe.previous` on Windows, where a running program
   is moved aside rather than replaced). The daemon's release directory is unpacked next to
   the old one and renamed into its place; the old one is kept as `troupe-daemon.previous`.
6. **Then the rest the installers put here.** The desktop app, where `install.sh` or
   `install.ps1` installed it: on Linux the release's AppImage replaces the one beside the
   programs (`~/.local/bin/troupe-desktop`, the old one kept as `troupe-desktop.previous`);
   on macOS the app in the release's disk image replaces `~/Applications/Troupe.app` (the
   old one kept as `Troupe.app.previous`); on Windows the release's setup runs silently, per
   user, as the installer ran it, and closes the app if it is running. A desktop app that is
   running on Linux or macOS keeps running the old build until you restart it, and
   `troupe update` says so. The VS Code extension, where `code` lists it: installed again
   from the release's `troupe.vsix` with `code --install-extension`; open VS Code windows
   take it when they restart. Each of these is held to the signed manifest as the rest. One
   that cannot be replaced is said and left as it is, and `troupe` and `troupe-daemon` stay
   installed; a release with no desktop app for your computer leaves yours alone.

`troupe update --rollback` swaps each back: the troupe and the troupe-daemon from before the
last update, the daemon again only between turns, and the desktop app's AppImage or app
bundle kept as `.previous`. The Windows setup and the extension keep no previous: that
release's own setup, or `code --install-extension` with its `.vsix`, moves them back. Run
again, it swaps forward.

The latest release replaces only what is older than it; `--version` replaces either way. It
updates what the installers installed, where they installed it (`TROUPE_BIN_DIR` and
`TROUPE_LIB_DIR` move it, as they move the installers'). A machine with the daemon and no
`troupe` is updated by the desktop app, when it has one (below), and otherwise by running
its installer again.

## The desktop app

The desktop app updates itself, and the `troupe-daemon`, the `troupe` and the VS Code
extension the installers put beside it, from the same signed releases. It looks when it
starts and once a day after:

- **What it looks for.** Signed in to a plane, the version the plane recommends for the
  desktop app, from where the plane says releases are (GitHub's unless it names another);
  otherwise the latest release. The app checks the plane's signature on that itself, against
  the key this computer pinned, before it fetches anything: a policy that key did not sign
  is said in a sentence and not followed. `TROUPE_RELEASE_URL` points it at a mirror, as it
  points `troupe update`, over `https`, and wins over the plane's.
- **What it checks.** The release's `manifest.json` and its signature, against the release
  keys the app was built with, before anything else; then the update itself, which Tauri's
  updater holds to its own signature by the same key, and the app holds to the size and
  sha256 the manifest names. A release it cannot check is refused with a sentence saying
  why, and nothing changes.
- **When it installs.** Only when you say so: **Update** downloads and checks it, and
  **Restart now** installs it. A turn at work in a session on this computer is waited for
  first, and so is the daemon, which is asked to stop between turns, as `troupe update`
  asks it, when its release is replaced too. Sessions on the plane run on their pods
  whatever the window does. On Windows the setup restarts the app; on macOS and Linux the
  app restarts into the new one.
- **The daemon beside it.** Where the installers put a `troupe-daemon` older than the
  release (`%LOCALAPPDATA%\Programs\troupe-daemon`, `~/.local/lib/troupe-daemon`), it is
  replaced with the release's daemon in the same step, the old one kept as
  `troupe-daemon.previous`, as `troupe update` keeps it, so `troupe update --rollback` and
  the installers find it. A daemon a running `troupe` started inside itself is that
  `troupe`'s, and is left running.
- **The terminal and the extension beside it.** Where the installers put a `troupe` older
  than the release (`%LOCALAPPDATA%\Programs\troupe`, `~/.local/bin`), it is replaced in
  the same step and the old one kept as `troupe.previous`, as `troupe update` keeps it; a
  terminal already open keeps the old one until it is started again. Where `code` lists
  the VS Code extension older than the release, it is installed again from the release's
  `troupe.vsix` first of all, since `code` failing changes nothing else; open VS Code
  windows take it when they restart. The offer says which of these go with it, or why one
  is left as it is: a plane that blocks the release's `troupe`, or a release with none for
  this computer.
- **Never backwards.** A release older than the app is not offered. On a version the plane
  has blocked whose recommended one is older, the app says so and leaves the choice to you:
  that release's own installer moves you back.

Signed in to a plane that does not serve this version of the desktop app, below its
minimum or on a version it has blocked, the app says so in one sentence, keeps to the
sessions on this computer as it does when the plane is not answering, and offers
**Update now**:

```text
This plane needs the desktop app 0.15.0-beta or later, and this is 0.14.0-beta: update it now, which installs 0.15.1-beta.
```

A newer version the plane recommends is a quiet line with an **Update** beside it. The
terminal says the same in a line where it meets the plane, in HQ and after `troupe login`
and `troupe whoami`, with the command to run:

```text
This plane recommends troupe 0.15.1-beta, and this is 0.15.0-beta: run troupe update.
```

Desktop apps from before 0.15 have no updater: their installer, or `install.ps1 -Gui` and
`install.sh --gui`, installs the release once, and the app keeps itself current from then
on.

## Signed in to a plane

Your organisation's plane can say which versions of `troupe` and `troupe-daemon` it serves:
a recommended version, a minimum, and versions it has blocked. Signed in (`troupe login`),
`troupe update` asks it first:

- it installs the plane's **recommended** version rather than the latest, and leaves a
  newer one you already have alone;
- it never installs a version the plane **blocks**, or one older than its **minimum**, even
  with `--version`;
- it never moves you backwards on the plane's word alone. On a blocked version whose
  recommended one is older, it says so and names the `troupe update --version` that moves
  you back, for you to run.

The release is checked against the release key exactly as without a plane: the plane can
hold a version back or name one, and cannot make `troupe update` install anything the key
did not sign, nor walk your machine back to an old release. A plane that cannot be reached
is said in a line, and `troupe update` goes on as without one.

A `troupe` older than the plane's minimum, or on a version it has blocked, is refused when
it connects, with one sentence saying what to run:

```text
This plane needs troupe 0.13.0-beta or later, and this is 0.12.0-beta: run troupe update, which installs 0.13.1-beta.
```

HQ, `troupe whoami` and the plane's commands say that rather than that the plane is
unreachable. Sessions on this machine are not affected. A `troupe-daemon` the plane refuses
says the same in its log and in `identity.get`, and stops syncing private sessions until it
is updated, or the plane serves it again. A refusal is the plane's word only as its key
signed it, for that client and that version: one it did not sign is said in a line and not
acted on.

**A change on the plane reaches you within a minute**, without signing in again. While you
are signed in, `troupe-daemon` asks the plane again every thirty seconds whether its version
policy or your organisation's settings changed. A changed setting is applied to your running
sessions as their next turn begins, with a line saying which (`Your organisation's settings
changed: max_turns holds from this turn.`); a changed version policy is passed to the
desktop app, which looks for its update again.

### Recommended or latest

The recommended version is the one your organisation's IT has chosen and supports: the
right one for nearly everybody, and what `troupe update` and the desktop app's **Update**
install. A newer release may already work with your plane; `--latest` is for the person
who wants it before IT recommends it.

```text
$ troupe update
0.34.0-beta, the version https://plane.example.com recommends
$ troupe update --latest
0.36.0-beta, the newest release that supports https://plane.example.com (it recommends 0.34.0-beta)
```

- **What "supports" means.** Each release says, in its signed manifest, which plane
  versions it works with. `--latest` looks at the newest releases first, at most twenty,
  and takes the first that says it supports the version your plane runs. One that says
  nothing (older releases do not) is passed over, and said; so is one that
  supports other planes. Without a newer one it installs the recommended version and says
  why.
- **The plane's minimum and blocked list still hold.** `--latest` never installs a version
  the plane blocks or one below its minimum, any more than `--version` does: the plane
  would refuse it when it connects. A blocked release is passed over for the next; one
  below the minimum ends the look.
- **Not signed in**, `--latest` is simply the newest release.
- **`troupe doctor`** says, in a line that is never a failure, when a release newer than
  the recommended one supports your plane:

  ```text
  ok    update  0.36.0-beta supports this plane; `troupe update --latest` installs it
  ```

- **The desktop app** offers the recommended version as before, and beside it, more
  quietly, **Newest supported (0.36.0-beta)** where there is one.

`--latest` reads GitHub's list of releases, or the one release `TROUPE_RELEASE_URL` names.
A plane that serves its own releases lists none, so there, name the version.

### The plane's word is signed

The plane signs what it tells your machine, its version policy and your organisation's
settings, with a key of its own. `troupe login` pins that key, as SSH pins a host key, and
says its fingerprint:

```text
the plane signs what it tells clients with the key SHA256:/oEsEvOrTOasXbaaw1L5BssbEe9D+zPiUu9/9VImOIk; pinned
```

From then on a policy the pinned key did not sign, one changed after it was signed or one
past its time is refused in a sentence, and `troupe update` goes on as without a plane. If
the plane's administrators rotate the key, your machine says so and trusts the new one for
nothing until you accept it. Check the fingerprint with them first (their console shows it
under Integrations), then:

```text
troupe plane-key                        # the key pinned, and the one the plane offers now
troupe plane-key accept SHA256:...      # trust the new one
```

The desktop app asks the same in its banner. A plane from before 0.22 signs nothing, and
its word is taken as it always was, said in a line.

### Updating from the plane

Where the plane says releases are (its administrators set it, under Policy), `troupe update`
and the desktop app install from there rather than from GitHub, so a machine on a closed
network updates without reaching it. That may be the plane itself, which hands out the
releases its administrators mirrored into its object store (the console's Integrations
page). The files are checked against the release key exactly as they are from GitHub: the
plane can serve a release or not, and cannot change one. With no recommended version there,
name one: `troupe update --version 0.22.0-beta`; the desktop app needs the plane to
recommend one.

## What the signature proves, and what it does not

Each release's `manifest.json` is signed with Troupe's release key, an Ed25519 key in
[minisign](https://jedisct1.github.io/minisign/)'s format that only the release workflow can
use, and every `troupe` and `troupe-daemon` is built with its public half.

**It proves** that the files you install are the ones the release workflow built and
published for that version, byte for byte. A mirror, a proxy or a changed file on the
release page cannot hand `troupe update` anything else: a file whose sha256 is not the
signed one, a manifest someone edited, or one signed by any other key, is refused.

**It does not prove**

- that the code is free of bugs or safe to run: only that it is what the release built;
- that the release is the newest. Somebody who controls a mirror can keep serving an older
  signed release. `troupe update` never moves you backwards unless `--version` asks it to,
  but it cannot tell that a newer one exists if it is never shown one. Signed in to a plane
  it is told: the plane's recommended version is the one asked for, and a mirror serving an
  older one is refused (`the release at … is 0.13.0-beta, not 0.13.1-beta`). The plane's
  word comes over your signed-in connection to it, so this holds for as long as the plane
  itself is not the one holding you back;
- anything about a release's build machine, or about what is already on your machine;
- anything about a pre-release or a release before 0.13, which are not signed.

The installers (`install.sh`, `install.ps1`) check the same signature when
[minisign](https://jedisct1.github.io/minisign/) is installed. Without it they say they can
check only the release's `SHA256SUMS`, which comes from the same place as the files: it
catches a broken download, not a changed release. Install minisign first, or check the
signature by hand:

```sh
minisign -Vm manifest.json -P <the release key>
```

The release key is in `apps/troupe_core/priv/release-keys.txt` in the repository, and in the
`install.sh` and `install.ps1` attached to each release.
