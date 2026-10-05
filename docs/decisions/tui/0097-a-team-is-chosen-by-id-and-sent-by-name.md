---
number: 97
title: A team is chosen by id and sent by name
date: 2026-09-19
status: accepted
paths:
  - clients/tui/lib/troupe/client/remote.ex
gist: A team is chosen by id and sent by name
---

`session.create` on the plane filters the caller's teams by `name == wanted`, and this client had been sending the id — harmless against the fake, where the two differ only in case, and `forbidden: no team of yours may use dev` against the live plane, where an id is a GUID. HQ and the smoke keep addressing teams by id, because that is the stable handle; `Troupe.Client.Remote.create_session/2` translates a known id to its name from the identity this client already holds. `teams/1` now remembers that identity too (it was only `whoami` that did), so a wizard that listed teams has the names it needs without a second `me`.
