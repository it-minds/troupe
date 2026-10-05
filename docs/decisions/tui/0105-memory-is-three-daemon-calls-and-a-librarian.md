---
number: 105
title: "`/memory` is three daemon calls and a librarian branch"
date: 2026-09-20
status: accepted
paths:
  - clients/tui/test/troupe/memory_client_test.exs
gist: "`/memory` is three daemon calls and a librarian branch"
---

The brief itself is the daemon's (troupe-remote Decision 649): it reads `.troupe/memory.md` into every prompt and `remember` writes it, so the TUI keeps only what a person does about it. `/memory` asks `memory.get` and says the status, when it was built and which sections it has; `/memory forget` is `memory.forget`; `/memory refresh` starts the `librarian` as a branch of this session (Decision 103) — in the checkout itself, `worktree: "never"`, because the one file it writes is the brief at the repository's root and a worktree would only put it somewhere to be merged out of. The refresh a session used to start with lives here too, since starting a session is the client's: `create_session` asks `memory.get` and, when the brief is `absent` or `stale` and the workspace config has `memory_auto_refresh` (the default), starts that same branch with a prompt that says which of the two it found. Tests turn the refresh off in the fake's config, so a session in the suite is one agent unless a test asks for the librarian.
