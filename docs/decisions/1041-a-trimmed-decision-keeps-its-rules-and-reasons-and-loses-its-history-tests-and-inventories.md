---
number: 1041
title: The logs were trimmed once, by deletion only, to the live decisions; a trimmed body keeps every rule and reason and loses its history, tests and inventories, and its paths name at most eight globs of code
date: 2026-11-18
status: accepted
issue: 1012
paths:
  - apps/troupe_protocol/lib/mix/tasks/troupe.decisions.ex
  - docs/decisions/README.md
  - docs/decisions/tui/README.md
  - docs/decisions/daemon/README.md
gist: Superseded files deleted, no stub; old bodies cut by deleting only (rules and reasons kept even past 40); paths code only, <= 8, hubs only where the rule is written
---

The three logs were brought to the shape Decision 1025 sets for new decisions, once, by
hand, under these rules.

- **A superseded decision is deleted, and leaves no stub.** `--check` reads `supersedes`
  only to mark the decision it names, so the later decision keeps the number in its front
  matter and the `next` marker keeps the number taken.
- **A decision the code contradicts is corrected in its title and gist, with one first line
  saying what changed and which decision changed it**, when that decision is in another log
  or replaced only part of it. Otherwise it is marked superseded by the later one.
- **A body is cut by deletion only.** What stays is the decision, what was not chosen and
  why, and what breaks if it is undone. Test lists, proofs, issue and chunk history,
  measurements, inventories of files and fields, and follow-up lists go. A sentence that
  stays is not reworded. A paragraph may be re-wrapped.
- **Meaning beats the cap for a decision dated before 2026-11-18.** A rule the code relies
  on, a limit, a refusal, an ordering or a reason stays, even when that leaves the body
  past 40 lines. `--report` lists those, and `--check` does not fail them. Splitting such a
  decision, or moving the rules into the module's own documentation, is a later change
  that each has to argue for.
- **`paths` name code where the decision would be undone:** at most eight globs, never a
  test, and a prose page only in a decision about that page's own shape. A file many
  decisions touch (the agent server, the plane's admin module, the protocol schema, a
  whole client directory) is named only by a decision whose rule is written in that file.
  Otherwise `--for` on it lists everything and tells a reader nothing.

Not chosen: cutting every body to 40 lines whatever it held. That would have deleted rules
that no other page states, and a decision log that loses its rules is worse than a long one.
Not chosen either: a summary of each decision in new words. A reworded decision can say
something its author never decided, and nobody would see the change in review.

Undoing this would bring back superseded files beside their replacements and paths that
make `--for` list a hundred decisions. A body cut by rewording would no longer be what was
decided.
