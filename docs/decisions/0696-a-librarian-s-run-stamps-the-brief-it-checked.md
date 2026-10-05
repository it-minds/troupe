---
number: 696
title: A librarian's run stamps the brief it checked, whether or not it rewrote any of it
date: 2026-09-26
status: accepted
paths:
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/session/memory.ex
  - apps/troupe_core/test/troupe/tools/remember_test.exs
  - clients/tui/test/troupe/memory_client_test.exs
gist: A librarian's run stamps the brief it checked, whether or not it rewrote any of it
---

The brief counts as built when a curated section is written (Decision 649),
one never built is stale, and a client with `memory_auto_refresh` starts a
librarian on a stale one. A librarian that found nothing to rewrite, or wrote only a
note, left the brief unbuilt or as old as it was: a brief of notes, or one a person
wrote by hand, stayed stale for good, and every new session in that repository
started another librarian and paid for it. Found in chunk 5; the TUI's test that said
a second session "starts nothing" listened for the librarian after it had started.
Now a `librarian` agent whose run ends as it meant to, by answering or with
`finish`, stamps the brief (`Troupe.Session.Memory.checked/1`: `built_at`, `head`
and `files`, and no word of the text), so the brief is stale again only when it is
older than `memory_max_age_days` or the repository has drifted. What is stamped is
the run, not what it wrote, because finding nothing to change is the librarian's
answer too; a run that failed, was cancelled or ran out of budget stamps nothing and
is tried again by the next session. The agent knows the profile by its name, as the
client does when it starts it, and the stamp makes no brief where there is none.
- **Proof:** `Troupe.Tools.RememberTest`: a brief of notes and a hand-written one,
  each left fresh and word for word as it was by a librarian that wrote nothing,
  while another agent's turn and a librarian's failed request stamp nothing. The
  TUI's `Troupe.MemoryClientTest`, whose second session now reads its own journal
  for the librarian. Both failed on the chunk's tip.
