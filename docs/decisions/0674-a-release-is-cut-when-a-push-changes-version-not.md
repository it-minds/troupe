---
number: 674
title: A release is cut when a push changes `VERSION`, not whenever `VERSION` has no tag
date: 2026-09-21
status: accepted
paths:
  - .github/workflows/release.yml
gist: A release is cut when a push changes `VERSION`, not whenever `VERSION` has no tag
---

Cutting any version without a tag would have released and deployed the 0.2.0
that `VERSION` had said for weeks when this repository became the monorepo, below
what production was running, with nobody having asked for a release. The job reads
two commits and cuts only when the pushed commit changed `VERSION` from its first
parent — the previous `main` — and the version still has no tag, so a re-run of a
release's own run cannot cut it twice.
