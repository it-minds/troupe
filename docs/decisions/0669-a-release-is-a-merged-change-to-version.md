---
number: 669
title: A release is a merged change to `VERSION`
date: 2026-09-21
status: accepted
issue: 37
paths:
  - .github/workflows/release.yml
  - clients/gui/README.md
  - docs/developer/deployment.md
  - scripts/release
gist: A release is a merged change to `VERSION`
---

Four repositories delivered four
ways, nothing had ever been tagged, and the plane was deployed by hand from one
laptop. Issue #37 asked whether deploying should stay manual, and the team's answer
is no (Martin, 2026-09-21: "I want a deployment on releases too").

*Cutting one.* `scripts/release <version>` opens a pull request whose only change is
`VERSION` and its copies (`scripts/version.exs set`), and merging it is the release;
674 says exactly when a push cuts one. A tag pushed by hand is not a release.
`docs/developer/ci.md` has what a release runs and publishes.

*Deploying it* is not this repository's: a release publishes its images and chart
and ends, and a deployment follows the release from somewhere of its own (735).

*Worker images* are the part a chart cannot roll, because each profile names its
own; a profile whose image is `release` follows the chart's worker image (672).
