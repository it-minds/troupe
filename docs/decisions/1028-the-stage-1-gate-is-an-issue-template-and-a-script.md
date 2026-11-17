---
number: 1028
title: The Stage 1 gate is an issue template and a script, with no runbook pages; the template carries the rows and the record's rules, and scripts/gate-check is the desk half
date: 2026-11-17
status: accepted
issue: 1016
supersedes: [933]
paths:
  - .github/ISSUE_TEMPLATE/stage-1-gate.yml
  - scripts/gate-check
  - scripts/gate-check.ps1
gist: The gate is the stage-1-gate issue template plus scripts/gate-check; rows and record rules live in the template, no runbook pages to drift from it
---

**The decision.** A release's walk of the Stage 1 gate is one issue opened from
`.github/ISSUE_TEMPLATE/stage-1-gate.yml`. The template holds the eight rows as a table
with a result column, each row's desk half and what needs a person, and the record's
rules Decision 933 set: one comment per row walked, each failure an issue the comment
names, a pass carried only where no change since touched the row, a failure fixed is a
new release, private evidence kept out. `scripts/gate-check` and `gate-check.ps1` are
the desk half and say in their own headers what they check. There are no runbook pages.

**Why.** The two pages (447 lines) were recorded against twice in 41 releases; the
records were issues anyway, and each was written by copying the pages' table into one.
A template is that copy, made once, and is where a walker starts.

**Not chosen.** *Keeping the pages beside the template*: two places saying the rows, one
of which drifts. *A page of the steps in full*: the steps for the live rows change with
the plane and are the walker's, recorded in the row's comment.

**If undone.** A runbook page comes back as a second description of the rows; the
template and the script are what must stay in step with what the gate asks.
