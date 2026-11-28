# Decisions

The decisions that still shape this repository, each with the reasoning a reader would
otherwise have to reconstruct, one file per decision. Documents cite them by number
(`Decision 660`); new code does not, and states its invariant in its own words instead,
while a decision names the code it governs in its `paths` (Decision 882). The TUI's own
are in [tui/](tui/README.md) and the daemon's in [daemon/](daemon/README.md), each
numbered on its own, so `Decision 60` in the TUI's code and `TUI Decision 60` elsewhere
are `tui/0060-*.md`.

## Before changing a file

```
mix troupe.decisions --for apps/troupe_gateway/lib/troupe/gateway/private.ex
```

lists the decisions that govern the path, newest first: the number, a line saying what
someone changing it must not undo, and the file. A superseded one says what replaced it.
Read the ones that bear on the change; a change that undoes one says so.

## Writing one

A decision is a new file here, `<number, four digits>-<slug>.md`, numbered above every
number this log has used and below the line that says which number is next. That line is
the first number not yet reserved: a chunk's coordinator reserves a block of numbers for
the chunk and moves the line past the block on the chunk's branch, and a fixer never
edits it, so two pull requests that each decide something touch no file in common:

<!-- next: 1130 -->

A decision is short: what was decided, what was not chosen and why, and what breaks if it
is undone, in at most 40 lines that are not blank. It does not list the tests that prove
it, retell the issue's history or restate the code; the pull request and the code carry
those. Its `paths` are where it would be undone, at most eight globs of code; never a test,
which is not where a decision is undone, and a page under `docs/` only when the decision is
about that page's own shape. It starts with a front matter:

```yaml
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
```

- **`title`**: the decision, in one sentence.
- **`paths`**: globs, from the repository root, of the code where the decision would be
  undone. A glob that no longer matches anything fails CI, so a move or a rename breaks
  the decision's check rather than, silently, its meaning.
- **`gist`**: at most about 150 characters, what someone changing those paths must not
  undo. It is what `--for` prints, so an agent can tell without reading the body whether
  the decision matters to what it is about to change.
- **`status`**: `accepted`, or `superseded` once a later decision replaces this one
  whole; the later one says `supersedes: [N]`, which it says too when it replaces only a
  part.
- Optional: `issue`, `pr`, `symbols` (modules and functions), `supersedes`.

A `title` or `gist` that starts with a backtick or holds `: ` goes in double quotes, as
YAML wants.

A decision that is superseded or reversed, or whose reasoning now lives in the code it
governs, is marked `superseded` or deleted. Numbers are never reused, so a citation keeps
meaning what it meant: the `next` line stays above every number a file ever had. `git log -p -- docs/decisions` has every one ever written; the
three logs they were split from (`DECISIONS.md`, `clients/tui/DECISIONS.md` and
`apps/troupe_daemon/DECISIONS.md`) are in the history before Decision 790, and
`elixir scripts/split-decisions.exs` turns the entries a branch still appends to one into
files.

`mix troupe.decisions --check`, which CI runs on every pull request, fails on a front
matter YAML would read otherwise, a missing field, a number used twice in one log, a
number at or above its log's `next`, or a `paths` glob that matches nothing, and, for a
decision dated 2026-11-18 or later, a body over 40 lines, more than eight `paths` or a
test among them. `--report` lists the older ones over those limits, and the superseded.

## The decisions

On the documentation site the list is below, newest first, read from the files as the
site is built; in the repository, this directory is the list.

<!-- decisions:index -->
