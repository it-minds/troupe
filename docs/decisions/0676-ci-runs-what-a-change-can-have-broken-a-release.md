---
number: 676
title: CI runs what a change can have broken; a release runs everything; a pre-release runs nothing
date: 2026-09-21
status: accepted
paths:
  - .github/workflows/prerelease.yml
  - .github/workflows/release.yml
  - docs/developer/ci.md
  - docs/developer/deployment.md
  - scripts/release
gist: CI runs what a change can have broken; a release runs everything; a pre-release runs nothing
---

One pipeline for every pull request and every merge cost a merge to
`main` an hour whatever the change was. `ci.yml` plans each run from what changed:
umbrella apps from the dependency graph their own `mix.exs` files declare (a change
tests the app and every app that depends on it), each app a parallel leg, the
clients only when they or what they build against changed. The soak and the cluster
suite are where they are owed: `nightly.yml` and `release.yml`, which call the same
`ci.yml` with `full: true`, so a release still passes every job on exactly the
commit it ships and builds its images from it. A build to try does not wait for a
release: `prerelease.yml`, by hand, builds any commit without the suite and
publishes it as a GitHub pre-release `<VERSION>-pre.<n>` — the installers' default
never picks one — keeping the newest five. The native builds are `native.yml`, and
`images.yml` is the one definition of the five images for all three. `release.yml`
can be started by hand to retry a version whose run failed after its VERSION change
merged, which 674 alone would leave with no way out but a new version.
`docs/developer/ci.md` has the picture.
