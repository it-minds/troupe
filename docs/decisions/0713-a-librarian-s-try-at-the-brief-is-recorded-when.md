---
number: 713
title: A librarian's try at the brief is recorded when it starts, and one that built nothing holds off the next automatic refresh for `memory_max_age_days`
date: 2026-09-27
status: accepted
paths:
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/session/memory.ex
  - apps/troupe_core/test/troupe/tools/remember_test.exs
  - apps/troupe_gateway/test/troupe/gateway/memory_test.exs
gist: A librarian's try at the brief is recorded when it starts, and one that built nothing holds off the next automatic refresh for `memory_max_age_days`
---

Amends
696, which left a run that failed, was cancelled or ran out of budget to be tried
again by the next session: with `memory_auto_refresh` that was every new session
until one got through, and in a repository whose librarian writes nothing and has
no brief to stamp, every session for good, each paying for it (defects D24).
- **The try is the start.** A `librarian` agent given something to do records the
  time before it asks a model anything (`Troupe.Session.Memory.attempted/3`), so a
  run that crashes, is closed with its session or is still going when the next
  session opens counts as well as one that failed. It is kept in the state
  directory, `librarian.json`, filed under the brief's path, never in the
  repository.
- **The daemon says whether a refresh is due.** `memory.get` answers `refresh_due`:
  the brief is `absent` or `stale`, and no librarian has started on it in the last
  `memory_max_age_days` without its being built since. A try the brief was built
  after holds nothing off, so a brief a librarian stamped that went stale because
  the repository grew is refreshed at once, as before. `status` is unchanged, so
  `/memory` still says what the brief is. `memory.forget` forgets the try with the
  brief, so a person who clears it gets a new one at the next session. The TUI
  starts its librarian only when the refresh is due (TUI Decision 127);
  `/memory refresh` is a person asking and is never held off.
- **The librarian stops copying the instruction files.** Decision 706 put
  `AGENTS.md` and its aliases into every prompt ahead of the brief and left the
  librarian's prompt folding them into the brief. It now reads them to leave out
  what they say, and describes the brief as Troupe's own notes on the repository.
- **Proof:** `Troupe.Tools.RememberTest` (a librarian whose request failed, and one
  that wrote nothing where there was no brief, each leave the refresh not due; the
  hold's length, a build after the try, and `forget`), `Troupe.Gateway.MemoryTest`
  (`refresh_due` over the wire), and the TUI's `Troupe.MemoryClientTest` (a session
  after a failed librarian starts none), which failed on the chunk's tip; and the
  installed build, where three sessions on a repository whose librarian fails start
  it once, on the pull request.
