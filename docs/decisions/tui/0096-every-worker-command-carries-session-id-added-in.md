---
number: 96
title: Every worker command carries `session_id`, added in one place
date: 2026-09-19
status: accepted
paths:
  - clients/tui/lib/troupe/remote/worker.ex
gist: Every worker command carries `session_id`, added in one place
---

The worker's schema requires it on seventeen methods — `input.send`, `turn.cancel`, `approval.respond`, `todo.edit`, `fs.*`, `blob.get`, `presence.set` and the rest — and answers `invalid_params` without it, which is what the first input sent over a finally-open socket got. This client opens one socket per session, so the id was implicit everywhere and spelled out in three places by hand; it is now put on every command as it enters `Troupe.Remote.Worker` (`addressed/2`, under `activating/4` and `command/4`), with `Map.put_new` so the three that already named it are unchanged. The `FakeRemote` refuses an unaddressed command with the same error, so the suite would have caught this.
