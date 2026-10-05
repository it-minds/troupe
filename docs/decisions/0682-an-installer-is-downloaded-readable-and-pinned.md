---
number: 682
title: An installer is downloaded, readable and pinned to its release, and it asks before it acts
date: 2026-09-24
status: accepted
paths:
  - docs/user/vscode.md
gist: An installer is downloaded, readable and pinned to its release, and it asks before it acts
---

A pipe from `curl` into `sh`, or from `irm` into `iex`, runs whatever
arrives. A cut-off download runs as far as it got, nobody reads the script first, and
`iex` leaves the script's variables and `$ErrorActionPreference` in the person's
session.
- **Attached and pinned.** Each release now attaches `install.sh` and `install.ps1`,
  covered by its `SHA256SUMS`. `scripts/release-installers` writes the release's
  version into both, so the copy on a release page installs that release, a release
  candidate or a pre-release included, without `TROUPE_VERSION`.
- **Download, read, run.** The notes and READMEs say to download the script, read it
  if you like, and run it. On Windows that is `powershell -ExecutionPolicy Bypass
  -File`, because the default policy runs no script.
- **It asks.** In a terminal, with neither `--tui` nor `--gui`, the installer asks
  about each client: yes by default on a fresh machine, otherwise yes for what is
  already installed. It then prints a plan (downloads, processes to stop, what it
  replaces, removes and adds to PATH) and asks before doing any of it. `-y` asks
  nothing. Without a terminal nothing is asked, and naming neither client needs `-y`,
  as before.
- **Next steps.** It ends with the model settings (682) and what to do next.
- **Clean install.** `--clean-install` (`-CleanInstall`) removes the current install
  once the downloads check out, keeping config and state unless `--purge` is given.
- **The TUI's payload.** A running TUI is stopped with the daemon, and Burrito's payload
  is cleared on every TUI install, as `install-local` does. Otherwise a release of the
  version a local build carried would run the build.
- **Fixes found on the way.**
  - The PATH line goes to the file the person's shell reads. A fresh Mac has no
    `~/.zshrc`, and zsh never reads `~/.profile`.
  - Windows waits for the desktop app's NSIS uninstaller by its registry entry,
    because the uninstaller returns before it is done.
  - Windows PowerShell's progress bar is off, because it made the downloads many
    times slower.
  - Burrito reads `TROUPE_INSTALL_DIR` as where to unpack the TUI, so the bin
    directory's override is now `TROUPE_BIN_DIR`. `install.sh` still reads the old
    name and unsets it.
- **Proof.** The installers pinned to `v0.3.3-pre.1`, on Linux x86_64 in a scratch
  home and on Windows 11 in scratch directories:
  - fresh, update and clean installs;
  - a running daemon stopped, and `.previous` kept on update, gone after a clean
    install;
  - the questions answered through a pseudo-terminal (Linux) and stdin (Windows),
    including "no" at "Go ahead?";
  - refusals without a terminal or with a stray `--purge`;
  - `--uninstall --purge` leaving no file, and the user PATH untouched with
    `-NoModifyPath`;
  - `troupe --version` passing, the old variable name included.
- **Not tested:** the macOS branch, and `-Gui` on Windows (the desktop app's setup
  and uninstaller run per user, against the real machine).
