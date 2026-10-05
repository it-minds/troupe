---
number: 256
title: The prompt crosses the control channel once and is stored nowhere on the plane
date: 2026-09-13
status: accepted
paths:
  - apps/troupe_plane
gist: The prompt crosses the control channel once and is stored nowhere on the plane
---

`session.create`'s `prompt` travels in the `session.activate` push and only on the
first activation; a later one replays the log, in which it is already the first
input. It is the one piece of session content the control channel carries, so it is
bounded at 64 KiB and the row never sees it — the tests assert the string is absent
from the session struct. The canary test for the channel is about what workers
*report*; a plane-to-pod push of a first input is deliberate, because the
alternative — a client attaching only to type the first line — is what makes a
trigger impossible. 497 is the one other time the plane holds a prompt.
