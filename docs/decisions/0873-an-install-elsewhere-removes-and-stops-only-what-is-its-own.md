---
number: 873
title: An install whose programs TROUPE_BIN_DIR moves is one of its own, and its uninstall and clean install remove and stop only what is in its directories or names them, leaving what every install shares to the default one
date: 2026-10-11
status: accepted
issue: 506
paths:
  - install.ps1
  - install.sh
  - scripts/check-installers
  - scripts/check-installers.ps1
gist: Elsewhere (bin dir not the default), uninstall leaves the desktop app, Burrito payload and its TUIs, others' login entry, menu entry and PATH line
---

- **Which install is the default.** The one whose programs are in the default place:
  `%LOCALAPPDATA%\Programs\troupe`, or `~/.local/bin`. It is decided by the directory of
  the programs and not the daemon's, because what is shared follows the programs: the
  `troupe` there is what unpacks the payload, and its `troupe-daemon` is the one the desktop
  app and a login entry find. So moving only `TROUPE_LIB_DIR` leaves an install the
  default one, and its uninstall does what it always did.
- **The default install owns what every install shares**, exactly as before: the desktop
  app, the payload and the TUIs running from it, the login entry, the menu entry, the
  licence copies and the PATH line it wrote. Nothing changes for it, and the checks say so.
- **An install elsewhere owns what is in its two directories, and what names them.** Its
  daemon, shim, `troupe` (and the TUI process running from that file), and on Linux its
  `troupe-desktop`. The desktop app's entry, the menu entry, the login entry and the PATH
  line are its own only when they name it: the desktop app's program (`DisplayIcon`) under
  one of its directories, a menu entry whose `Exec=` is its `troupe-desktop`, a login entry
  that starts its shim or its release's `troupe-daemon`, a PATH line for its own directory.
  Anything else stays, and the plan says what stays and why, so a person is not surprised
  to find the desktop app still there.
- **`login off` runs elsewhere only for an entry the installed daemon reports and that names
  this install.** Decision 818's reason for running it unconditionally (on Linux it also
  removes the kind of entry `status` does not report) is the reason not to here: either
  kind may be the default install's. A stale entry of the other kind that starts this
  install is left; that is rarer than the harm it avoids.
- **The payload is never cleared elsewhere, by an install with `-Tui` either.** Burrito
  unpacks once per version into one place for every `troupe`, and nothing tells one
  install's payload from another's. A release's `troupe` is the same build as the payload of
  its version, so what clearing guarded against (a local build reusing a payload of the
  same version) is the default install's concern; an install elsewhere leaves a payload
  behind on uninstall, as the plan says, for the default install or a person to clear.
- **`-Purge` is unchanged**: it deletes the config and state directories the plan names,
  which are shared, because the person asked for exactly that.
- **Not chosen:** refusing an uninstall elsewhere outright (a second install could then not
  be removed); asking per shared item (a check, or `-Yes`, has nobody to ask); and telling
  which TUI running from the payload is this install's by its parent process (Windows
  PowerShell 5.1's `Get-Process` gives no parent). An install elsewhere stops the
  `troupe.exe` it is about to remove; what that one started from the payload may run on
  until its window is closed, and the payload it runs from stays anyway.
