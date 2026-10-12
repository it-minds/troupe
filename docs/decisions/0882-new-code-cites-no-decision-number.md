---
number: 882
title: New code cites no decision by number; it states its invariant in its own words, and a check on each change keeps it so
date: 2026-10-12
status: accepted
issue: 422
paths:
  - scripts/decision-citations.exs
  - .github/workflows/ci.yml
  - .github/workflows/dev-check.yml
  - docs/developer/conventions.md
gist: A change adds no `Decision N` to code (counted per file against the merge base); existing ones go when their file is touched; docs may cite
---

Issue #422. Code cited decisions by number: on the tip of `development-2026-10-12-2`,
`git grep -oE "Decision [0-9]+" -- apps clients` found 2,702 citations, and the pattern
below, which also reads `decision 7`, `Decisions 815 and 863` and a list wrapped across
comment lines, 2,983 in 714 code files, naming 260 decisions. Each one is a comment
reaching out of the code into a document, so the documents could not be renumbered,
merged or tidied without silently rotting the comments, and a reader of the code had to
leave it to learn why a line was there. Documentation depends on code, never the other
way round: a document may name a symbol or a path, and a symbol names no document.

- **The rule.** Code says why in its own words where the reason applies ("the write
  names its epoch; a sealer that lost the session is refused before it writes"), not
  "Decision 800". A decision names what it governs in its front matter (`paths`, and
  `symbols` where it helps; Decision 790), so `mix troupe.decisions --for <path>` finds it
  from the code's side. Documents, decision files included, may cite decisions as before.
- **Migration, not a purge.** The citations already in the code stay until their file is
  touched for another reason, when the one in the touched part is replaced by the
  invariant in words. A pull request that removed all of them would touch 714 files and
  conflict with every branch open at the time.
- **The check.** `scripts/decision-citations.exs --base <rev>` compares each changed code
  file (`.ex`, `.exs`, `.heex`, `.eex`, `.ts`, `.tsx`, `.js`, `.mjs`, `.cjs`, `.rs`,
  `.css`) with itself at the merge base and fails when it cites a number more often than
  before, naming the file, the number and the lines. Counting per file rather than reading
  added lines lets a comment be rewrapped, or a function moved within its file, without
  failing for a citation that was already there; a citation carried into another file is
  new there. Untracked files are read too, so it runs before a commit. The tools that
  handle decision numbers as data (`troupe.decisions`, its test, `split-decisions.exs`,
  this script) are exempt.
- **Where it runs.** In CI's `versions` job and in `dev-check.yml`'s decisions job, both
  of which run on every pull request whatever it changed, with two commits checked out
  and `--base HEAD^1`: a pull request's merge commit and its base. Not in `lint`, which
  runs only when an umbrella app changed, so a change to the TUI or the desktop app alone
  would not have been checked.
- **Not chosen.** A check over the whole tree, which fails until the last of the 2,983 is
  gone. A committed count that may only fall: every pull request that removes a citation
  would edit it, and two such pull requests would conflict there, as the decision logs
  did (Decision 790). A check of the diff's added lines: it fails a rewrap.

Proof: `apps/troupe_protocol/test/mix/tasks/troupe.decisions_test.exs` (a citation added
to a file fails, naming the file, the number and the line; the invariant written instead
passes; a citation rewrapped across comment lines and committed keeps its count and
passes; one moved to another file, untracked, fails for each number of its list; a
document citing anything passes), and the script run against the chunk's tip, shown in
the pull request.
