---
number: 730
title: On Windows the desktop app shows its notifications itself, so that a click on one opens its session, and it runs as one copy
date: 2026-09-29
status: accepted
paths:
  - clients/gui
gist: On Windows the desktop app shows its notifications itself, so that a click on one opens its session, and it runs as one copy
---

Defect D35, following 714 and 708.
- **The toast is the one the plugin shows underneath.** `tauri-plugin-notification`
  hands its toast to notify-rust and lets go of the handle that would hear a click
  (714). On Windows the shell's `notify_show` builds the same WinRT toast through
  `tauri-winrt-notification`, which notify-rust had already brought into the lock:
  the same app id (the bundle identifier, which the installer writes on the Start
  menu shortcut, and PowerShell's for a build run from `target`), silent and short
  like the plugin's, and an `Activated` handler that holds the session's id. A click
  sends `troupe://open-session` to the page, then brings the window forward. On
  macOS and Linux `notify_show` answers false and the page uses the plugin, as it
  does when the shell's toast fails.
- **The window coming back stays the answer where no click is heard** (714): macOS
  and Linux, a toast the shell could not show, and a click that Windows turns into a
  launch.
- **One copy.** `tauri-plugin-single-instance`, registered first and pinned `~2.4`
  (717). A second launch, from the Start menu or from a click, hands its arguments
  to the copy that is running and exits. The running copy comes forward, and opens
  the session a `--session=<id>` among those arguments names, as a click would. A
  toast from `tauri-winrt-notification` 0.8 carries no launch argument, so a copy
  that Windows starts for a click names nothing. The app has no COM activator, and
  whether Windows starts one at all is unsettled here. In that case the window coming
  forward is the answer. A debug build does not register the plugin: `tauri dev` has
  the installed app's identifier and would hand itself over to it.
- **Proof:** `cargo test` (the launch argument, and the app id for an installed
  build and a build run from `target`); the desktop app's `notify` test, where a
  reported click opens its own session and not the last one's; and a renamed
  installed build against a fake daemon. Its toast is in Windows' history under the
  build's id with the shell's two fields, where the plugin's has three. A second copy
  with `--session=` exits in about 40 ms, and the first comes back on that session,
  17 s after the last toast. A second copy with no arguments, just after a toast,
  brings the first back on the toast's session. No toast was clicked: this machine
  shows no banners, and its notification centre was not opened while in use.
