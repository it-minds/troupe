---
number: 322
title: A release publishes the chart at its own version
date: 2026-09-14
status: accepted
paths:
  - .github/workflows/release.yml
gist: A release publishes the chart at its own version
---

`helm package` runs with
`--version` and `--app-version` set to the release's version, and the tarball is
attached to the release — so an install of that file pulls the images the same run
published, rather than whatever `values.yaml` was last edited to say.
