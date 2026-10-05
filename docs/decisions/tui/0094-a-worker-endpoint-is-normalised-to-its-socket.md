---
number: 94
title: A worker `endpoint` is normalised to its socket URL before the upgrade
date: 2026-09-19
status: accepted
paths:
  - clients/tui/lib/troupe/remote/discovery.ex
gist: A worker `endpoint` is normalised to its socket URL before the upgrade
---

The plane hands out whatever the pod enrolled with, which is an origin, not a socket path; the client upgraded at `/` and the pod's router answered 404, so an attach that had been granted a perfectly good token never came up. `Troupe.Remote.Discovery.worker_url/1` applies the reference clients' rule — `ws(s)://` as it is, `http(s)://` scheme-swapped with `/v1/socket` where the path is empty, a bare host as `wss://<host>/v1/socket` — at the one place the socket is opened, so a moved session's new endpoint gets the same treatment.
