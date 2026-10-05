---
number: 123
title: Plain `troupe` asks the daemon whether the first run is done before it asks its own questions, and `troupe doctor` prints the harness's checks
date: 2026-09-27
status: accepted
issue: 76
paths:
  - clients/tui/lib/troupe/cli/config_setup.ex
  - clients/tui/lib/troupe/cli/doctor.ex
  - clients/tui/test/troupe/config_setup_test.exs
  - clients/tui/test/troupe/doctor_test.exs
gist: Plain `troupe` asks the daemon whether the first run is done before it asks its own questions, and `troupe doctor` prints the harness's checks
---

Issue #76's
second slice (root Decision 705). A first run finished in the desktop app is
recorded by the daemon, and `before_session/2` now reads `setup.get` first: a
daemon that says `needed: false` gets no questions, and one from before the
method — which answers `method_not_found` — gets the questions of Decision 113 as
before. `troupe config`'s own questions are unchanged: an explicit command asks.
The full-screen flow (`troupe setup`) is a later slice. `troupe doctor` is
`Troupe.Doctor`, the same lines `troupe-daemon doctor` prints, plus what only
this client knows — the planes it is logged in to, each asked for its discovery
document; it needs no daemon, and exits 1 on a failure. `Troupe.Doctor` joins the
harness modules the TUI may call (`mix troupe.xref`), since the checks read the
files a daemon may not be running to answer about. Proof:
`test/troupe/config_setup_test.exs` ("a first run done in the desktop app means no
questions here", "a daemon from before setup.get still gets the questions") and
`test/troupe/doctor_test.exs`.
