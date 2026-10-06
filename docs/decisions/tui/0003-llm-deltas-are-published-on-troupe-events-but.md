---
number: 3
title: LLM deltas are published on `Troupe.Events` but not persisted
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_core/lib/troupe/events.ex
gist: LLM deltas are published on `Troupe.Events` but not persisted
---

Persisting every token would bloat the JSONL log for no replay value; the completed `assistant_message` event carries the full content, so replay is exact without deltas.
