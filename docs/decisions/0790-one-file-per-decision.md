---
number: 790
title: A decision is a file of its own, naming the paths it governs and what must not be undone there
date: 2026-10-05
status: accepted
issue: 437
paths:
  - docs/decisions/
  - apps/troupe_protocol/lib/mix/tasks/troupe.decisions.ex
  - scripts/split-decisions.exs
  - docs/overrides/hooks.py
  - mkdocs.yml
  - .github/workflows/ci.yml
  - .github/workflows/dev-check.yml
  - AGENTS.md
  - docs/developer/fixing-issues.md
gist: One file per decision, never an appended log or a committed index; paths must match; --check needs no compile, so CI runs it on every change
---

Issue #437, a first slice of #422. Every pull request that decided something appended a
numbered entry to the end of `DECISIONS.md`, `clients/tui/DECISIONS.md` or
`apps/troupe_daemon/DECISIONS.md`, so any two open pull requests conflicted there, and a
chunk's pull requests were stacked, or merged by hand in number order, for that reason
alone. The logs were also the heaviest thing a contributor met: 5,960, 914 and 82 lines.
On the tip of `development-2026-10-05-3`, two branches that each appended one entry to
`DECISIONS.md` conflicted (`CONFLICT (content): Merge conflict in DECISIONS.md`); the same
two decisions as files merged cleanly, either into the other.

- **A file per decision.** `docs/decisions/<number, four digits>-<slug>.md` for the
  repository's, `docs/decisions/tui/` and `docs/decisions/daemon/` for the two that were
  numbered on their own, which they still are: a number is unique within its directory,
  and `tui/108` and `108` are two decisions, as `TUI Decision 108` and `Decision 108`
  were. A number is reserved for a fixer before work starts, so two pull requests that each
  decide something add two files and touch nothing in common. The body is written as an
  entry was; the old bold first line is the front matter's `title`.
- **A front matter an agent can scan.** `number`, `title`, `date`, `status`, `paths` and
  `gist`, and optionally `issue`, `pr`, `supersedes` and `symbols`. `paths` are globs of
  what the decision governs; `gist` is at most about 150 characters of what someone
  changing those paths must not undo, so that `mix troupe.decisions --for <path>` (number,
  gist and file, newest first, a superseded one marked with what replaced it) is enough to
  decide whether to read the body. The direction is #422's: the decision names the code it
  governs, and a glob that stops matching fails CI, so a move or a rename breaks the
  decision's check instead of silently its meaning. The code's `Decision NNN` citations
  stay; they resolve by number as before, and taking them out is #422's.
- **No committed index.** The site's index of each log is made by the documentation
  site's hook as it builds, from the files' front matter, where the log's README says
  `<!-- decisions:index -->`; in the repository the directory listing is the index. An
  index the mix task wrote and CI held current would be the one file every pull request
  that decides something regenerates, and two such pull requests would conflict there,
  which is the problem this solves. The individual pages are left out of the nav
  (`not_in_nav`); the hook gives each its title as the heading, a line of number, status,
  date and issue, a note naming what superseded it, and the paths it governs.
- **The check runs on every change, so it needs nothing compiled.** `mix troupe.decisions`
  lives in `troupe_protocol` with the repository's other tasks (`troupe.release.check`,
  `troupe.egress`). `--check` fails on a front matter YAML would read otherwise, a missing
  field, a number used twice in one log, a missing body, a file name that does not carry
  the number, or a glob that matches nothing. A glob breaks when any file moves, whatever
  the change was, so CI runs it in `versions`, the job that runs on every pull request
  and checks the documentation's links for the same reason, and not in `lint`, which runs
  only when an umbrella app changed: a pull request that only changed `clients/vscode`
  would otherwise add a decision nobody checked. It runs in `dev-check.yml` too, as a job
  of its own whatever changed, because a chunk's pull requests are where decisions are
  added, and in `scripts/ci`. So that a bare `elixir` can load it there, the task uses no
  dependency and reads the front matter itself, as the part of YAML a decision is written
  in, refusing what YAML would read differently from how it looks (an unquoted value with
  `: `, a leading backtick, a title YAML would cut at ` #` or read as a number), so that
  what passes is what MkDocs reads. All 345 split files were also read with PyYAML, the
  parser MkDocs uses, with no error.
- **The split is a script, kept.** `scripts/split-decisions.exs` reads whichever log is
  present and writes each entry as a file, its body as it was (only the list item's
  indentation taken off), and drafts the front matter: `title` from the bold line, `date`
  from the commit that first added the entry's line (with merges, since a few were first
  written while resolving one), `issue` from the first issue the entry names as its own,
  `status: superseded` where a later entry says it replaces this one whole (TUI 24 by 65,
  TUI 81 by 115, daemon 3 by 6, and daemon 4 by 5, which says so in words the script is
  told), `supersedes` on the later one, in part too (TUI 4, 22 and 86, root 669, which
  stay accepted), and `gist` from the title, cut at a clause near 150 characters. `paths`
  come from the files whose code or documents cite the number in its log's form (in
  `clients/tui` a bare number is the TUI's and `root Decision N` the repository's;
  elsewhere `TUI Decision N` is the TUI's), leaving out the defects list and the logs; for
  an entry nothing cites, from the files and modules it names; failing those, the
  directory of the component it talks about most. Of the repository's 196 entries, 121
  took their paths from citations, 30 from what they name and 45 fell back to a
  directory, of which a reviewed pass narrowed 33 to files (the budget ladder to
  `apps/troupe_plane/lib/troupe/plane/*budget.ex`, the ledger to `ledger.ex`, and so on);
  of the TUI's 143, 51, 41 and 51, the last `clients/tui`; of the daemon's 6, 2 and 4. A
  branch cut before the split that appended to a log catches up by keeping its log, running
  the script and committing the files: a number with a file already is not written again,
  and one whose body differs from its file's keeps the log in place and is named.
- **Not chosen.** Files grouped by area, as #422 first had it: two decisions about one
  area would conflict again. An issue per decision: the record would leave the
  repository and could not be read offline or reviewed beside its code. `merge=union` in
  `.gitattributes`: GitHub's mergeability check and merge button do not use it.

Proof: `apps/troupe_protocol/test/mix/tasks/troupe.decisions_test.exs` (a duplicate number,
a missing field, a glob that matches nothing and the YAML traps each fail `--check`; the
same number in two logs does not; `--for` lists a file's decisions through the
directories above it and marks superseded ones; the repository's own decisions pass; the
script splits a log, takes an entry appended after the split and refuses one that
differs), and the merge of two decision branches in a scratch clone, both ways, shown in
the pull request.
