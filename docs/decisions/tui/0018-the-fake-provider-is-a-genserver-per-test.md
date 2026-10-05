---
number: 18
title: "The Fake provider is a GenServer per test/session, selected with `provider: {Troupe.LLM.Fake, pid}`"
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: "The Fake provider is a GenServer per test/session, selected with `provider: {Troupe.LLM.Fake, pid}`"
---

Concurrent tests need isolated recordings; in a release `TROUPE_PROVIDER=fake` starts one named Fake from `TROUPE_FAKE_SCRIPT`.
