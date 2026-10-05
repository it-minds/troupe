---
number: 77
title: What a remote session allows is a fold, not a question asked at render time
date: 2026-09-16
status: accepted
paths:
  - clients/tui/lib/troupe/ui/tui/model.ex
gist: What a remote session allows is a fold, not a question asked at render time
---

The worker publishes `Troupe.Remote.Capability.of/3` as a `:remote_status` event, the model keeps it, and the view greys out input and says why from model state alone. A window opened on a session that was already attached reads the capability once when it rebuilds, because it missed the events that carried it.
