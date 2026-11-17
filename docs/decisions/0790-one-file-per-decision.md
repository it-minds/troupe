---
number: 790
title: A decision is a file of its own, naming the paths it governs and what must not be undone there
date: 2026-10-05
status: accepted
issue: 437
paths:
  - apps/troupe_protocol/lib/mix/tasks/troupe.decisions.ex
  - scripts/split-decisions.exs
gist: One file per decision, never an appended log or a committed index; paths must match; --check needs no compile, so CI runs it on every change
---

- **A file per decision.** `docs/decisions/<number, four digits>-<slug>.md` for the
  repository's, `docs/decisions/tui/` and `docs/decisions/daemon/` for the two that were
  numbered on their own, which they still are: a number is unique within its directory,
  and `tui/108` and `108` are two decisions, as `TUI Decision 108` and `Decision 108`
  were. A number is reserved for a fixer before work starts, so two pull requests that
  each decide something add two files and touch nothing in common.
- **A front matter an agent can scan.** `number`, `title`, `date`, `status`, `paths` and
  `gist`, and optionally `issue`, `pr`, `supersedes` and `symbols`. `paths` are globs of
  what the decision governs; `gist` is at most about 150 characters of what someone
  changing those paths must not undo, so that `mix troupe.decisions --for <path>` (number,
  gist and file, newest first, a superseded one marked with what replaced it) is enough to
  decide whether to read the body. The direction is #422's: the decision names the code it
  governs, and a glob that stops matching fails CI, so a move or a rename breaks the
  decision's check instead of silently its meaning.
- **No committed index.** The site's index of each log is made by the documentation
  site's hook as it builds, from the files' front matter, where the log's README says
  `<!-- decisions:index -->`; in the repository the directory listing is the index. An
  index the mix task wrote and CI held current would be the one file every pull request
  that decides something regenerates, and two such pull requests would conflict there,
  which is the problem this solves. The individual pages are left out of the nav
  (`not_in_nav`); the hook gives each its title as the heading, a line of number, status,
  date and issue, a note naming what superseded it, and the paths it governs.
- **The check runs on every change, so it needs nothing compiled.** `--check` fails on a
  front matter YAML would read otherwise, a missing field, a number used twice in one log,
  a missing body, a file name that does not carry the number, or a glob that matches
  nothing. A glob breaks when any file moves, whatever the change was, so CI runs it in
  `versions`, the job that runs on every pull request and checks the documentation's links
  for the same reason, and not in `lint`, which runs only when an umbrella app changed: a
  pull request that only changed `clients/vscode` would otherwise add a decision nobody
  checked. So that a bare `elixir` can load it there, the task uses no dependency and
  reads the front matter itself, as the part of YAML a decision is written in, refusing
  what YAML would read differently from how it looks (an unquoted value with `: `, a
  leading backtick, a title YAML would cut at ` #` or read as a number), so that what
  passes is what MkDocs reads.
- **Not chosen.** Files grouped by area, as #422 first had it: two decisions about one
  area would conflict again. An issue per decision: the record would leave the
  repository and could not be read offline or reviewed beside its code. `merge=union` in
  `.gitattributes`: GitHub's mergeability check and merge button do not use it.
