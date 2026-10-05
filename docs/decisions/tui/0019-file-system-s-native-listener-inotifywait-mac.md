---
number: 19
title: "`file_system`'s native listener (inotifywait / mac_listener / inotifywait.exe) is the one OS process not started through reaper"
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: "`file_system`'s native listener (inotifywait / mac_listener / inotifywait.exe) is the one OS process not started through reaper"
---

The spec mandates the `file_system` dependency, which owns that Port itself; it is linked to the Watcher and dies with it, and the polling backend spawns nothing.
