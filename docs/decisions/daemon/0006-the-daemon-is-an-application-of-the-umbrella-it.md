---
number: 6
title: The daemon is an application of the umbrella it used to pin, and entry 3 is over
date: 2026-09-21
status: accepted
supersedes: [3]
paths:
  - apps/troupe_daemon
gist: The daemon is an application of the umbrella it used to pin, and entry 3 is over
---

Entry 3 pinned the three harness apps to one `troupe-remote` commit and gave the daemon
a version of its own. With `troupe-remote` now the monorepo (its DECISIONS.md 666 and
667), the daemon is `apps/troupe_daemon`: its harness is the checkout it is built in, its
version is the umbrella's `VERSION`, and the release is still defined in this directory.
What entries 1, 2, 4 and 5 decided is unchanged — a plain release per platform, the
reaper built for the host into the release, `ezstd` from the fork. Numbering here
stops; later decisions about the daemon go in the root `DECISIONS.md`.
