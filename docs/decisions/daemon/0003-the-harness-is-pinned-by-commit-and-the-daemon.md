---
number: 3
title: The harness is pinned by commit, and the daemon has a version of its own
date: 2026-09-19
status: superseded
paths:
  - apps/troupe_daemon/mix.exs
gist: The harness is pinned by commit, and the daemon has a version of its own
---

`mix.exs` names one `troupe-remote` commit for all three apps and sets `TROUPE_VERSION`
to the harness version that commit declares, because a sparse checkout has no
`VERSION` file and the apps refuse to guess. `VERSION` here is the daemon's: a
packaging change is a daemon release without a harness change, and a harness change
is a bump of the pinned commit. `troupe-daemon version` prints both, and the protocol
major, so a support question can be answered from one line.
