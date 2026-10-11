# Updating Troupe

`troupe update` replaces the `troupe` and the `troupe-daemon` the installers put on your
machine with a newer release, after checking that the release is one Troupe's release key
signed. Nothing it cannot check is installed.

```sh
troupe update --check            # what is installed, the latest release, and what an update would do
troupe update                    # install the latest release
troupe update --version 0.13.0   # install that release, older or newer
troupe update --rollback         # put back what the last update replaced
```

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

`troupe update --rollback` swaps each back: the troupe and the troupe-daemon from before the
last update, the daemon again only between turns. Run again, it swaps forward.

The latest release replaces only what is older than it; `--version` replaces either way. It
updates what the installers installed, where they installed it (`TROUPE_BIN_DIR` and
`TROUPE_LIB_DIR` move it, as they move the installers'). A machine with the daemon and no
`troupe` is updated by running its installer again.

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
  but it cannot tell that a newer one exists if it is never shown one;
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
