---
number: 959
title: "One update moves every component the installers put on a machine: troupe update replaces the desktop app and the VS Code extension after troupe and troupe-daemon, and the desktop app's update replaces troupe and the extension beside the daemon"
date: 2026-10-27
status: accepted
paths:
  - apps/troupe_core/lib/troupe/update.ex
  - clients/gui/apps/desktop/src-tauri/src/update.rs
  - clients/gui/apps/desktop/src/shell.ts
  - clients/gui/apps/desktop/src/views/Update.tsx
  - clients/tui/lib/troupe/cli.ex
symbols:
  - Troupe.Update.desktop_version/2
  - Troupe.Update.extension_version/2
gist: "troupe update and the desktop updater each replace every installed component (daemon, terminal, desktop app, extension), extras after the core, said when left; AppImage and app bundle roll back"
---

maintainer asked that any update move every installed component.

- **`troupe update` takes the extras.** Beside troupe and troupe-daemon, two more
  candidates where the installers put them: the desktop app, found as the installers leave
  it (`~/.local/bin/troupe-desktop` with its `.version` file or the menu entry's
  `Comment=... release X`, `~/Applications/Troupe.app`'s `Info.plist`, the per-user
  setup's uninstall entry `HKCU\...\Uninstall\Troupe` on Windows), and the VS Code
  extension where `code` (found as the installers find it) lists `objective-mj.troupe`.
  Each is replaced from the release's own file for the installers' kind, the AppImage, the
  disk image or the setup, never the updater's bundle beside them, and the `.vsix`, held
  to the signed manifest as every file is. The desktop app's version drops the pre-release
  part, as its files are named (`scripts/version.exs`), so it is compared against the
  release's version before its first dash. The plane's `desktop` policy is honoured as
  `tui`'s and `daemon`'s are; the extension has none. - **After the core, each on its
  own.** troupe and troupe-daemon are downloaded, quieted and swapped in together as
  before, all or nothing. Then each extra: the AppImage renamed into place with the old
  one kept as `.previous` and its version written beside both and into the menu entry; the
  app bundle copied out of the mounted image beside the old one and renamed in, the old
  kept as `Troupe.app.previous`; the Windows setup run silently as the installer runs it,
  which closes a running app itself; the extension installed with `code
  --install-extension --force`. An extra that fails is said and left, troupe and
  troupe-daemon stay installed, and the command exits 1 saying which was not replaced and
  that the rest is. A release with no desktop app for the machine (Linux on arm64) leaves
  it with a line, where no troupe or daemon for the machine still stops the update. A
  running AppImage or app bundle keeps the old build until restarted, and is told so. -
  **`--rollback`** puts the AppImage or the app bundle back from `.previous`, the version
  files beside the AppImage trading places with it. The Windows setup and the extension
  keep no previous, and `--rollback` and the update say so: the release's own setup, or
  `code --install-extension` with its `.vsix`, moves them back. - **The desktop app's
  update takes the terminal and the extension.** `update_check` reads `troupe --version`
  where the installers put the terminal (`TROUPE_BIN_DIR`,
  `%LOCALAPPDATA%\Programs\troupe`, `~/.local/bin`) and `code --list-extensions
  --show-versions`, off the async runtime, and offers each where it is older than the
  release and, for the terminal, the plane serves the release (`tui` policy); the page
  shows a line per component, or why one is left. `update_download` stages the terminal
  beside the old as `troupe.new`, executable, and the `.vsix` in the temporary directory,
  each held to the manifest. `update_install` installs the extension first, since `code`
  failing changes nothing else and is "nothing changed"; then swaps the daemon in, then
  the terminal as `troupe update` swaps it (Unix: the old linked to `.previous` and the
  new renamed over it; Windows: the running one moved aside, one still held set aside
  under a stamped name for a later update to remove), undoing the daemon when the terminal
  cannot follow; then hands the app to Tauri's updater, undoing both when it cannot.
