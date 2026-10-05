---
number: 196
title: A latency measurement gives each of its five clients a session of its own
date: 2026-09-11
status: accepted
paths:
  - clients/gui/packages/bench/src/main.ts
gist: A latency measurement gives each of its five clients a session of its own
---

Five
clients hammering one session measures how long a queue behind a busy agent takes to
drain, which is a property of the model's speed rather than of the transport. The
question is `input.send` to `input.accepted`, and that is the load under which that
number means something.
