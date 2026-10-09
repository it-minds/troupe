---
number: 818
title: The installers offer to start the daemon at login once it is installed, Enter and -y meaning no, and an uninstall takes the entry back before it removes anything
date: 2026-10-09
status: accepted
issue: 76
paths:
  - install.ps1
  - install.sh
  - scripts/check-installers
  - scripts/check-installers.ps1
gist: A yes runs the installed troupe-daemon login on, and Enter, -y alone or no terminal write nothing; an uninstall runs login off first
---

#76 asked whether the daemon-at-login step belongs in the installer. Decision 762 answered
that the entry is the daemon's, so an installer that offers it runs `troupe-daemon login
on`, and that its uninstall should run `login off` first; neither did. Now both do.

- **When.** After the daemon is installed and the model settings, under a heading of its
  own, before the closing list. The installer asks the installed daemon (`login status`)
  whether an entry is there and where, so the paths stay the daemon's alone: the
  installers know none of them.
- **The question** is the one `troupe config` asks, and Enter is no, as there (762). An
  entry starts something at every login, so it is written only when somebody says so.
- **Where an entry is there already, nothing is asked.** The installer says where it is
  and that `troupe-daemon login off` takes it back. A yes would write the same file again
  (the entry starts the `troupe-daemon` a client finds, the installers' shim or the
  release's own wrapper, both at paths an upgrade keeps), and a no does nothing, so no
  answer would change anything. It is also why a person who said yes in `troupe config`,
  which the installer hands over to, is not asked a second time.
- **The flags** are `--start-at-login` and `--no-start-at-login` (`-StartAtLogin`,
  `-NoStartAtLogin`), each answering without the question. Both together are refused
  before anything happens, and so is `--start-at-login` with `--uninstall`.
- **`-y` (`-Yes`) alone is not a yes.** Decision 682's `-y` asks nothing and does what the
  flags name: alone, it installs the daemon and no client. Here, likewise, it turns
  nothing on, and the step says which command would. A run without a terminal is the
  same.
- **A no is nothing**, not `login off`: an entry already there stays, and the step says
  `troupe-daemon login on` turns it on later.
- **A refused `login on`** is a warning with the daemon's reason, and the install stands,
  as a failed VS Code extension is said rather than thrown.
- **What the entry starts is left to `login on`** (762's order: `TROUPE_DAEMON_COMMAND`,
  the `PATH`, the release's wrapper). The installer does not set `TROUPE_DAEMON_COMMAND`
  for the call, so the entry starts what every client on the machine would.
- **Uninstall.** `login off` is the first thing done once the plan is agreed, while the
  daemon that knows where its entry is is still there, before anything is stopped or
  removed; otherwise the entry would go on starting a program that is gone. The plan
  names the entry when `login status` reports one, and `login off` runs whenever a daemon
  is installed, because on Linux it also removes the other kind of entry, which `status`
  does not report. A daemon from before `login` answers "unknown arguments" and wrote
  none, so that answer is passed over in silence. Any other failure is a warning and the
  uninstall goes on: stopping would leave the entry and the daemon both.
- **`--clean-install` leaves the entry**, since it puts the daemon back where the entry
  expects it.
- **The installers have checks of their own**: `scripts/check-installers` runs
  `install.sh` under `sh` and `bash`, and
  `scripts/check-installers.ps1` runs `install.ps1` under whichever PowerShell runs it,
  each against a release of stand-ins in a scratch directory. The stand-in `troupe-daemon`
  writes down what it is asked and keeps its entry in a file, so no check writes a real
  login entry; a download is a copy, and nothing reaches the real install, the `PATH` or
  (on Windows) the desktop app's registry entry, which reads as absent. `install.sh`'s
  questions are answered through a pseudo-terminal; `install.ps1`'s need a console, so
  `Set-StartAtLogin` is lifted out of the script with the parser and run with Read-Host
  answering.
- **Proof.** Both checks failing on the chunk's tip (21 of 40 under each of `sh` and
  `bash`, 17 under each of Windows PowerShell 5.1 and PowerShell 7: the flags unknown or
  ignored, nothing asked, an uninstall leaving the entry behind) and every one passing on
  this change, in WSL Ubuntu and on Windows 11. Not run: macOS; the installers against a published release, which has no
  copy of them yet; the real `troupe-daemon login on` through an installer, which a check
  must not do; and a person answering at a Windows console.
