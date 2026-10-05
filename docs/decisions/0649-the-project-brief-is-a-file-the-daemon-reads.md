---
number: 649
title: The project brief is a file the daemon reads into every prompt, and `remember` is the one tool that writes unasked
date: 2026-09-20
status: accepted
paths:
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/test/troupe/tools/remember_test.exs
  - apps/troupe_gateway/test/troupe/gateway/memory_test.exs
  - clients/tui/lib/troupe/client/daemon.ex
gist: The project brief is a file the daemon reads into every prompt, and `remember` is the one tool that writes unasked
---

`.troupe/memory.md` is a YAML-fronted markdown
brief with `Overview`, `Layout`, `Commands`, `Conventions` and dated `Notes`,
prepended to every system prompt; `remember` appends to it and a `librarian`
profile writes it. There is no process: the brief is a file, a daemon has many
sessions on one repository, and a function over a path serialised by a VM-wide
transaction on that path (`:global.trans`) is what both want — re-read before
merging, replaced by rename, so two agents in one daemon cannot lose each other's
note and a hand edit between two calls survives. And the path is the repository's
*main checkout*, found through `git rev-parse --git-common-dir`: a branch in a
worktree writes the same brief as the session it branched from, and its note does
not vanish with the worktree. `remember` is `:auto` although it writes, because the
only file it can reach is the brief, the model cannot name a path, and a brief
nobody approves is a brief nobody writes. The brief is read at every prompt, not
once at start, so a note made in a session reaches the next agent to start in it.
What a client shows and does about it is on the wire: `memory.get` (status, path,
built time, section titles, text) and `memory.forget`; the auto-refresh is the
client's because starting a session is — `memory_auto_refresh` is the config key
that asks for it, and the client starts a `librarian` session when the brief is
`absent` or `stale`. Flat config keys, like every other setting: `memory`,
`memory_auto_refresh`, `memory_max_chars`, `memory_max_age_days`.
