---
number: 695
title: On Windows the desktop app installs into `%LOCALAPPDATA%\Programs\troupe-desktop`, and a setup moves an install out of the daemon's state directory
date: 2026-09-26
status: accepted
issue: 185
paths:
  - clients/gui/apps/desktop/src-tauri/installer-hooks.nsh
gist: On Windows the desktop app installs into `%LOCALAPPDATA%\Programs\troupe-desktop`, and a setup moves an install out of the daemon's state directory
---

Issue #185, D15
in docs/developer/defects.md. Tauri's per-user NSIS setup installs into
`$LOCALAPPDATA\<productName>`, `%LOCALAPPDATA%\Troupe`, which NTFS reads as the
daemon's `%LOCALAPPDATA%\troupe`: the app and its uninstaller sat beside the
sessions and `identity.json`, one recursive delete of "the app's folder" from losing
them.
- **Where.** Under `%LOCALAPPDATA%\Programs`, where per-user programs go, but not in
  `Programs\Troupe`: that is `Programs\troupe`, which `install.ps1` puts on the
  `PATH`, and an `uninstall.exe` on the `PATH` is a command to type by accident.
  `troupe-desktop` is named for the binary and sits beside `troupe-daemon`.
- **How.** An installer hook, `installer-hooks.nsh`, rather than a copy of Tauri's
  template that would have to follow every Tauri release. It moves `$INSTDIR` when
  it is `$LOCALAPPDATA\<productName>`, whether that is the default or the registry's
  record of the last install: as the window opens, so the directory page shows the
  new place, and again before the files are copied, which is all a silent setup
  (`install.ps1 -Gui`) runs. Once the app is in, the old install's Start menu,
  desktop and taskbar shortcuts are pointed at it, and the old install's two files
  are deleted by name. The directory stays. The uninstaller is Tauri's, unchanged: it
  deletes its own files by name and its directory only when that is empty.
- **Kept.** `install.ps1 -Uninstall -Purge` still runs the app's uninstaller before
  it deletes the state, for an install from before 0.5.2 that no newer setup has
  moved. A silent setup on a machine without the state directory still creates it,
  empty, because the template enters the default directory before the hook runs; the
  daemon would create it anyway.
- **Proof.** On this machine, with the product renamed (`TroupeD15`, binary
  `troupe-desktop-d15`) so no setup could touch the installed app, and a stand-in
  state directory at `%LOCALAPPDATA%\TroupeD15`. The chunk tip's setup installed
  beside the stand-in state. The fixed one moved that install to
  `Programs\troupe-desktop`, repointed its shortcuts and left the state byte for
  byte: silent, silent with no shortcuts of its own (`/NS`), silent while the old
  app ran, and through the window choosing "Do not uninstall". The directory page
  showed the new place for that upgrade and for a fresh install; `/D=` naming the
  state directory was overridden; a reinstall of the same version kept the new
  install; its uninstaller left the state. Not run: the real product's setup, which
  would have replaced the maintainer's install.
