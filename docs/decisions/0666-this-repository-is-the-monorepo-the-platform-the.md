---
number: 666
title: "This repository is the monorepo: the platform, the daemon, and the default GUI and TUI"
date: 2026-09-21
status: accepted
paths:
  - .github/workflows/ci.yml
  - mix.exs
gist: "This repository is the monorepo: the platform, the daemon, and the default GUI and TUI"
---

Decided by the team on 2026-09-21. Before it, a client was a separate
release from a separate repository and the daemon was built elsewhere by pinning
this one by git ref, which produced four repositories and three pins: the TUI and
the daemon each named a `troupe-remote` commit by hand, seventeen commits behind
main by the time anybody looked, and a protocol change was three or four pull
requests in three repositories with a version bump in the middle. The GUI and TUI
are now the defaults; a client somebody else writes against `PROTOCOL.md` is
exactly as supported as it was.

Three repositories came in with their history, each rewritten by `git filter-repo`
under its new prefix and merged as unrelated history: `it-minds/troupe-gui` under
`clients/gui`, `it-minds/troupe-tui` under `clients/tui`, and the umbrella
repository — `daemon/` and the installers. Their GitHub-generated references to
their own pull requests, "Merge pull request #N" and a squash title's "(#N)", were
rewritten to name that repository, because a bare `#N` here links to this
repository's #N; the umbrella repository's are written as
`it-minds/troupe-program#N`.

The clients sit under `clients/`, not `apps/`. Mix treats every directory in
`apps/` as an umbrella application and warns about any without a `mix.exs`, which
the GUI's pnpm workspace would be; and the TUI as an umbrella application would put
ExRatatui, Burrito and `rustler_precompiled` into the shared lock, into every image
build and into `mix check`. As its own Mix project it costs the server nothing. The
daemon is the opposite case: its dependencies are three umbrella applications and
nothing else, so it becomes one (667).
