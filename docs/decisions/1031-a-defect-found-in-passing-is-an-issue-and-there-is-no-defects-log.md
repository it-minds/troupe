---
number: 1031
title: A defect found in passing is a GitHub issue with its component label; the repository keeps no log of known defects
date: 2026-11-17
status: accepted
issue: 1010
supersedes: [940]
paths:
  - AGENTS.md
  - docs/developer/fixing-issues.md
  - scripts/doc-size.exs
  - mkdocs.yml
gist: No defects log; a defect found in passing is an issue (component label, bug if wrong behaviour), one per mechanism
---

**The decision.** A defect someone finds while working on something else is filed as a
GitHub issue: where, what and how bad, worded neutrally, with its component label
(`plane`, `harness`, `tui`, `gui`, `documentation`) and `bug` when it is wrong behaviour.
One issue covers one mechanism, not whatever one chunk happened to leave behind. The
repository keeps no list of known defects. This replaces the part of Decision 940 that
kept `docs/developer/defects.md` as an index, kept the entries on pages under
`docs/developer/defects/` and had `scripts/doc-size.exs` check that they matched. The
400-line rule in Decision 940 still stands.

**Why.** The log had 88 open entries and 383 items. 37 of the entries were titled by the
release or chunk that left them, so the only way to find a file's defects was to `rg` for
its path. Lines went in faster than they came out, the defects were tracked twice (in the
log and in the issue tracker, which is already triaged by rank), and CI had about 90 lines
of checks that existed only to keep the log consistent. For #1010 every item was checked
against the code. The ones still true are filed as issues #1041 to #1071, and the pull
request lists what happened to each of the others.

**Not chosen.** Keeping the log and regrouping it by component: it would still be a second
tracker, and its items would still miss the triage the issues get. One issue per entry:
it would keep the chunk-shaped titles. A `found-in-passing` label: the component label
already says where a defect is, and the issue's text says how it was found.

**If undone.** A second list grows beside the issues again, ranked by nobody. An agent
would also need to read it before every change, on top of searching the issues.
