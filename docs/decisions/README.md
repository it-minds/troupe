# Decisions

The decisions that still shape this repository, each with the reasoning a reader would
otherwise have to reconstruct, one file per decision. Code and documents cite them by
number (`Decision 660`). The TUI's own are in [tui/](tui/README.md) and the daemon's in
[daemon/](daemon/README.md), each numbered on its own, so `Decision 60` in the TUI's code
and `TUI Decision 60` elsewhere are `tui/0060-*.md`.

## Before changing a file

```
mix troupe.decisions --for apps/troupe_gateway/lib/troupe/gateway/private.ex
```

lists the decisions that govern the path, newest first: the number, a line saying what
someone changing it must not undo, and the file. A superseded one says what replaced it.
Read the ones that bear on the change; a change that undoes one says so.

## Writing one

A decision is a new file here, `<number, four digits>-<slug>.md`, numbered one past the
highest ever used (a chunk's coordinator reserves one for each fixer), so two pull
requests that each decide something never touch the same file. It starts with a front
matter:

```yaml
---
number: 790
title: A decision is a file of its own, naming the paths it governs and what must not be undone there
date: 2026-10-05
status: accepted
issue: 437
paths:
  - docs/decisions/
  - apps/troupe_protocol/lib/mix/tasks/troupe.decisions.ex
gist: One file per decision, never an appended log or a committed index; paths must match
---
```

- **`title`**: the decision, in one sentence.
- **`paths`**: globs, from the repository root, of the files and directories the
  decision governs. A glob that no longer matches anything fails CI, so a move or a
  rename breaks the decision's check rather than, silently, its meaning.
- **`gist`**: at most about 150 characters, what someone changing those paths must not
  undo. It is what `--for` prints, so an agent can tell without reading the body whether
  the decision matters to what it is about to change.
- **`status`**: `accepted`, or `superseded` once a later decision replaces this one
  whole; the later one says `supersedes: [N]`, which it says too when it replaces only a
  part.
- Optional: `issue`, `pr`, `symbols` (modules and functions), `supersedes`.

Then the body: the reasoning, the choices not made and why, and the proof. A `title` or
`gist` that starts with a backtick or holds `: ` goes in double quotes, as YAML wants.

A decision that is superseded or reversed, or whose reasoning now lives in the code it
governs, is marked `superseded` or deleted. Numbers are never reused, so a citation keeps
meaning what it meant. `git log -p -- docs/decisions` has every one ever written; the
three logs they were split from (`DECISIONS.md`, `clients/tui/DECISIONS.md` and
`apps/troupe_daemon/DECISIONS.md`) are in the history before Decision 790, and
`elixir scripts/split-decisions.exs` turns the entries a branch still appends to one into
files.

`mix troupe.decisions --check`, which CI runs on every pull request, fails on a front
matter YAML would read otherwise, a missing field, a number used twice in one log, or a
`paths` glob that matches nothing.

## The decisions

On the documentation site the list is below, newest first, read from the files as the
site is built; in the repository, this directory is the list.

<!-- decisions:index -->
