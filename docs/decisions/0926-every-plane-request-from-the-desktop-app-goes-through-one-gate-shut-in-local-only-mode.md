---
number: 926
title: "Every request the desktop app makes to a plane goes through one gate, the `fetch` its sign-in is built with, which is shut while Local only is on and asks the setting at each request, so a call already on its way when the switch goes is refused rather than sent"
date: 2026-10-19
status: accepted
paths:
  - clients/gui/apps/desktop/src/mode.ts
  - clients/gui/apps/desktop/src/views/SignIn.tsx
  - clients/gui/apps/desktop/test/local-mode.test.tsx
symbols:
  - throughTheGate
  - newSession
gist: "Every AuthSession the desktop makes comes from newSession, whose fetch is throughTheGate: shut while Local only is on, asked per request, so nothing in flight reaches a plane"
---

# Every plane request from the desktop app goes through one gate

## Context

Local only promises that the app makes no plane call of any kind (`mode.ts`). The app
kept that promise by handing the screens no sign-in in local mode: each hook that calls
a plane runs only while it has one. That covers the next render, not what is already
under way. The full CI of chunk 39 caught a request to the plane's `/rpc` after the
switch: the version check (`useUpdates`) asks the daemon for the pinned key, then the
plane's `initialize`, then `me.client_versions`, and a chain that had begun before the
switch went on after it. Its `live` flag kept the answer off the screen, but the request
was still made. A poll that comes due, or a token renewal started for a timer set while
signed in, has the same shape.

## Decision

- Every `AuthSession` the desktop app makes is built by `newSession`, and its `fetch` is
  `throughTheGate(...)`. Everything a sign-in sends goes through that `fetch`: discovery,
  the identity provider's token endpoint, the exchange and `/rpc`. So it is the one gate.
- The gate reads the Local only setting at each request. The switch writes the setting
  before it changes any state, so the gate is shut before the next request is made,
  whatever was in flight, queued or on a timer.
- A refused request fails with a plain error, not the provider's 400 or 401, so the
  stored refresh token is kept and turning Local only off signs straight back in.
- Offline (the plane not answering) and a plane that refuses this version are not Local
  only. The gate stays open for them: the app keeps asking whether the plane is back, and
  what it says about updates.

Building an `AuthSession` anywhere else in the desktop app, or passing one a `fetch`
that does not go through the gate, undoes this.

## Proof

`local-mode.test.tsx`, "refuses what was already on its way to the plane when the
switch went", holds the plane's answer to `initialize` until after the switch. Without
the gate, its `me.client_versions` reached the plane twice. With the gate, nothing does.
