---
number: 1025
title: A decision is at most forty lines and names at most eight paths of code, and a log's number is never taken twice
date: 2026-11-17
status: accepted
issue: 1011
supersedes: [790]
paths:
  - apps/troupe_protocol/lib/mix/tasks/troupe.decisions.ex
  - docs/decisions/README.md
  - docs/decisions/tui/README.md
  - docs/decisions/daemon/README.md
  - docs/developer/conventions.md
  - docs/developer/fixing-issues.md
gist: Body <= 40 non-blank lines, <= 8 paths, no test path, from 2026-11-18; each log's README says its next number
---

A decision says what was decided, what was not chosen and why, and what breaks if it is
undone, in at most 40 lines that are not blank. The tests that prove it, the issue's
history and a restatement of the code stay out: the pull request and the code carry them,
and a reader asked to read the decisions that bear on a change reads all of them.

`paths` are where the decision would be undone: at most eight globs, never a test file or
directory. A test is never where a decision is undone, and a decision that names twenty
paths, or every page that mentions it, comes up in `mix troupe.decisions --for` for
changes it has nothing to do with, until the list is too long to read. A page under
`docs/` is a path only when the decision is about that page's own shape; the check cannot
tell, so it holds the count and the test ban, and the README says the rest.

`--check` holds decisions dated 2026-11-18 or later to that shape. The day is a constant
in the task rather than read from this file, so the rule does not move when this file is
trimmed or deleted; it is the day after this lands, because decisions written earlier that
day were already over the cap. The older ones pass as written and `--report` lists them,
over the cap, over eight paths, with a test path or superseded, for trimming by hand.

Each log's README carries `<!-- next: N -->`, and `--check` fails unless N is above every
number in the log. Once a decision can be deleted, the highest file no longer says which
numbers were used, and a reused number makes an old citation point at the wrong decision.
The marker is the first number not yet reserved: a chunk's coordinator moves it past the
block reserved for the chunk on the chunk's branch, and a fixer never edits it, so two
fixers' pull requests do not both change one line.

This replaces 790's "the body is written as an entry was" and its paths naming every page
that mentions the log; the rest of 790 stands.

Not chosen: a cap on every decision at once, which fails the tree until the log is
trimmed; a warning instead of a failure, which nobody reads; the highest file's number as
the next, which a deletion lowers.
