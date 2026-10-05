---
number: 71
title: The credential file is written even when this machine cannot restrict it, and says so
date: 2026-09-16
status: accepted
paths:
  - clients/tui/lib/troupe/remote/credentials.ex
gist: The credential file is written even when this machine cannot restrict it, and says so
---

`<config dir>/credentials.json` is `0600` on unix; on Windows `File.chmod/2` is a no-op, so the inherited ACL is replaced with one naming only the current user (`icacls /inheritance:r /grant:r %USERNAME%:F`, run through `Troupe.OS.Process` like every other OS process). If `icacls` is missing or fails, the login still completes and prints a warning — losing the sign-in would be worse than a file with a wider ACL, and a silent success would be worse than both.
