---
number: 109
title: The harness is a path, not a pin, and this project's version is the repository's
date: 2026-09-21
status: accepted
paths:
  - clients/tui/lib/mix/tasks/troupe.xref.ex
gist: The harness is a path, not a pin, and this project's version is the repository's
---

The TUI now lives at `clients/tui` in the monorepo (the root DECISIONS.md 666 and
668). `troupe_core`, `troupe_gateway` and `troupe_protocol` are path dependencies on
`../../apps/`, so the harness the TUI builds against is the one in its own commit,
and `@harness_git`, `@harness_ref`, the `TROUPE_VERSION` workaround and the three git
entries in `mix.lock` are gone with the bump procedure that went with them. The
version is read from the root `VERSION` (0.2.0 where it was 0.1.0), so the CLI test
that asserted `troupe 0.1.0` now reads the file. Erlang is 28.5.0.5, the umbrella's.
The TUI remains its own Mix project rather than an umbrella application: ExRatatui,
Burrito and `rustler_precompiled` stay out of the server's lock and images.
