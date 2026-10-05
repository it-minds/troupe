---
number: 681
title: The installers take the same flags as `scripts/install-local`, and install the desktop app too
date: 2026-09-23
status: accepted
paths:
  - apps/troupe_core/lib/troupe.ex
  - install.ps1
  - install.sh
  - scripts/install-local
gist: The installers take the same flags as `scripts/install-local`, and install the desktop app too
---

`install.sh` and `install.ps1` installed `troupe` and `troupe-daemon`, with
`--no-tui` for the daemon alone (671), while `scripts/install-local` built the same
things from a checkout and asked for them by name: `--tui`, `--gui`. A person handed
both had two vocabularies, and no remote way to get the desktop app without
choosing among six installers on the releases page. Now the release installers speak
the local one's: the daemon always, `--tui` / `-Tui` and `--gui` / `-Gui` for the
clients (naming neither: 681; `--no-tui` still means the daemon alone). `--gui`
installs the release's AppImage on Linux x86_64 as
`~/.local/bin/troupe-desktop` with a menu entry, where `install-local --gui` puts its
build; `Troupe.app` from the `.dmg` in `~/Applications` on macOS; and the per-user NSIS
setup, run silently, on Windows. A daemon running from the directory being replaced
is stopped first, as `install-local` does, so an update reaches the next session
rather than the one after a reboot. `install.ps1` uses `return` where it used `exit`,
which closes a terminal the script was piped into. Proof: `install.sh` against
`v0.3.3-pre.1` in a scratch home on Linux x86_64: `--tui --gui` installed all three
with the AppImage's icon, a reinstall kept every `.previous` and stopped the running
daemon, a tampered TUI was refused with nothing replaced, no flags without a terminal
refused, `--no-tui` installed the daemon alone, and `--uninstall --purge` left no file.
The macOS branch and `install.ps1` are untested here: no Mac and no PowerShell.
