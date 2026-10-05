---
number: 668
title: One `VERSION` for everything this repository releases, and the TUI builds against the harness of its own commit
date: 2026-09-21
status: accepted
issue: 37
paths:
  - apps/troupe_protocol/lib/mix/tasks/compile.troupe_version.ex
  - clients/tui/mix.exs
  - docs/developer/build.md
  - docs/developer/repo-structure.md
  - docs/overrides/hooks.py
  - scripts/version.exs
gist: One `VERSION` for everything this repository releases, and the TUI builds against the harness of its own commit
---

Four version numbers with no relation, and a live
plane whose version only a deploy script knew, were what issue #37 named as the
thing to end. The root `VERSION` is the version of the images, the chart, the
daemon and the TUI, and a release is cut by changing it (669). `clients/tui` stays
a Mix project of its own and depends on the three harness apps by path, `override:
true`, since they also name each other as siblings. What two Mix projects cannot
share is a lock: the TUI's `mix.lock` and the umbrella's each lock the packages
they have in common, and a harness built against one version on a laptop and
another in a pod is the drift this was meant to end, so `scripts/locks-agree.exs`
fails when any of them differ and CI runs it.
