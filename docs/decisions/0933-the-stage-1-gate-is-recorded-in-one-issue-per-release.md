---
number: 933
title: The Stage 1 gate is recorded in one public issue per release, a row is walked again on a new release only where a change since its pass touched it, a failure fixed is a new release and that row walked again, and live-plane evidence stays in the deployment's private records
date: 2026-10-24
status: accepted
issue: 765
paths:
  - docs/developer/gate-walk.md
  - docs/developer/gate-walk-rows.md
  - scripts/gate-check
  - scripts/gate-check.ps1
gist: One issue per release, Stage 1 gate v<version>; carry a PASS only if nothing since touched the row; a fix is a new release; private evidence never in the issue
---

**Why.** The gate's runbook (`docs/developer/gate-walk.md`) has existed since 0.16.0, and
`scripts/gate-check` has passed on every release since, but nobody had walked the gate as
a record. The first walk at a desk, on 0.24.0-beta, found that a record needs rules the
runbook had in one sentence: where the walk is written, what a later release may keep of
an earlier walk, what a failure costs, and where the evidence from the live plane goes
when the repository is public. 1.0 needs all eight rows to pass on one tagged release
(#765), and the live rows take a person an hour each, so whether a pass carries from one
release to the next decides how often that hour is spent.

**The decision.**

- **One issue per release**, titled `Stage 1 gate: v<version>`. Its body is the runbook's
  table with a result column for that release. Each row walked on it gets one comment:
  **PASS** or **FAIL**, the date, the machine, what was run and what it printed, and the
  issue filed for each failure. The issue is the record; the runbook says how to walk, not
  what happened.
- **A row is walked again only where a change touched it.** On a new release, a row that
  passed on an earlier one is walked again when a pull request merged since then changes
  what the row's steps run or what the decisions under its "Behind it" govern, or fixes a
  failure filed from that row. Otherwise its result is carried: the comment says so and
  links the comment it was walked in. `gate-check` runs on every release whatever is
  carried, because it takes a minute.
- **A failure fixed is a new release, and that row walked again on it.** A row never
  passes on a fix that is only merged: the release it passes on is the one somebody
  installs. A failure is fixed or filed before the record moves on, never left as known.
- **Private evidence stays out of the public issue.** The repository is public. Output
  from the live plane goes in with host, cluster, account and identity-provider names
  replaced by `example.com`, and the comment says that the raw output and any recording
  are kept in the live deployment's private records, without naming where. Nothing from a
  person's real home, keychain or configuration goes in at all.

**Choices not made.**

- *Every row walked on every release.* Honest, but the live rows cost a person an hour
  each, and most releases touch one or two of them. The cost would push the walk to be
  skipped, which is worse than carrying a pass whose ground has not moved.
- *A pass carried until something fails.* Cheaper still, but a pass would then outlive the
  code it was walked on. Tying the carry to what changed keeps it checkable: the merged
  pull requests and the decisions' `paths` say whether a row was touched.
- *The record in a file in the repository.* A file needs a pull request per walk and mixes
  the record with the runbook; an issue takes comments from the person walking, links the
  failures it filed, and closes when the release is tagged.

**The proof.** The 0.24.0-beta desk walk (rows 1, 3, 5, 6 and 7's local halves, and 8) was
recorded this way in the draft of `Stage 1 gate: v0.25.0-beta`, with the live rows' steps
for the maintainer. Its failures were fixed in the same pull request (the Linux
`gate-check` reading Burrito's lines over `--version`, two quick start lines, the
installers' word "unsigned", two runbook labels) or handed on to be filed, so 0.25.0-beta
walks rows 1, 3, 5, 6 and 7 again and carries none of them.
