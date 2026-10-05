---
number: 675
title: A machine's model settings are the daemon's to read and write, and the plane never hands out a key
date: 2026-09-21
status: accepted
paths:
  - apps/troupe_daemon
gist: A machine's model settings are the daemon's to read and write, and the plane never hands out a key
---

A person picks a provider, pastes a key and chooses models in the
desktop app; the TUI pulls the organisation's defaults with `troupe config pull`.
Both go through the daemon — `config.get`, `config.models`, `config.set` — rather
than writing `config.yaml` themselves, because the daemon is the process whose
environment decides which file a session reads: a client computing `%APPDATA%` on
its own could edit a file nobody reads, and the desktop app has no filesystem
permission to do it with anyway. The methods edit only the user's file, report what
overrides it (a project's `.troupe/config.yaml`, `TROUPE_*`, the opencode fallback)
instead of hiding it, and never return the key. They are the daemon's alone; a
worker answers `method_not_found`, because a pod's provider is its profile's. The
plane offers defaults — provider, URL, auth style, models — as `me.client_defaults`
from a *Client defaults* settings group with no secret in it: anybody signed in can
read it, so a shared key there would be a key everybody has. The file is rewritten
rather than edited, which loses comments; the previous file is kept as
`config.yaml.previous`, and one that does not parse is never overwritten.
