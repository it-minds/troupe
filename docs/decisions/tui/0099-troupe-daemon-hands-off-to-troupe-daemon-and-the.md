---
number: 99
title: "`troupe daemon` hands off to `troupe-daemon`, and the installers left with it"
date: 2026-09-19
status: accepted
paths:
  - install.ps1
  - install.sh
gist: "`troupe daemon` hands off to `troupe-daemon`, and the installers left with it"
---

The local daemon is now a binary of its own — `troupe-daemon`, released from the `troupe` repository and built from the harness in `troupe-remote` — and this binary is a client of it in the making: phase 2 of the daemon plan deletes the harness here and embeds the daemon's. Until then `troupe daemon [run|status|config|models|version]` finds the binary the way every client does (`TROUPE_DAEMON_COMMAND`, then the `PATH`) and passes the arguments through untouched, so a person has one command to reach for and the answer to "is a daemon running?" is the same one the GUI gets. Without a binary it says how to install one and exits 1. `install.sh` and `install.ps1` moved to the `troupe` repository, adapted to install `troupe-daemon`, because `github.com/it-minds/troupe/releases` — the URL they always pointed at — is where releases now live and the daemon is what gets installed first; this binary's own installation is the TUI's release job, unchanged, and the two CI jobs that exercised the installers went with the scripts.
