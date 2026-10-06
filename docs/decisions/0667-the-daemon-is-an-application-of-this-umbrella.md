---
number: 667
title: The daemon is an application of this umbrella, released from its own directory
date: 2026-09-21
status: accepted
paths:
  - .github/workflows/native.yml
  - apps/troupe_daemon/mix.exs
  - mix.exs
  - scripts/install-local
  - scripts/install-local.ps1
gist: The daemon is an application of this umbrella, released from its own directory
---

`apps/troupe_daemon` depends on `troupe_protocol`, `troupe_core` and
`troupe_gateway` `in_umbrella`. Its `troupe_daemon` release — the host-triple
reaper and the `troupe-daemon` wrapper — is built from that directory rather than
from the root: a release defined at the root compiles every umbrella application
first, and on a Windows or macOS runner that is the plane's Postgres and Kubernetes
clients built for a machine that will never run them. Built from its own directory
it compiles the harness and nothing else, and its `lib/` holds none of the
platform's applications. Its runtime configuration is its own `config/runtime.exs`,
because the platform's reads a pod's environment and the daemon must boot without
it; its `rel/` turns distribution off. `mix troupe.boundaries` holds it to the
three harness apps.
