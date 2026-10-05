---
number: 76
title: "The client keeps a journal per remote session: the translated events as JSONL under `<state dir>/remote/<plane>/<session id>/`, with the highest `seq` as the cursor"
date: 2026-09-16
status: accepted
paths:
  - clients/tui/lib/troupe/remote/journal.ex
gist: "The client keeps a journal per remote session: the translated events as JSONL under `<state dir>/remote/<plane>/<session id>/`, with the highest…"
---

A local session's transcript survives a restart because it is on disk, and a remote one has to do the same or reattaching would show an empty pane. The journal is also where duplicates die: the events one durable event unfolds into are appended as a batch, and a batch whose `seq` the journal already has is dropped whole, so a replay overlapping what we have renders nothing twice and a `resync_required` costs nothing.
