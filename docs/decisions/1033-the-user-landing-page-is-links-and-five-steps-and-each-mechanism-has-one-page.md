---
number: 1033
title: The user landing page is the first run in five steps and a line per page, each mechanism a person meets is explained on one user page, and a moved section leaves no stub behind
date: 2026-11-17
status: accepted
issue: 1013
supersedes: [940]
paths:
  - docs/user/
  - mkdocs.yml
gist: docs/user/README.md is <=150 lines of first run, ways in, page list, promises; one page per mechanism, both clients' screens for it there; no stub headings
---

**The decision.** On the pages under `docs/user/`:

- **The landing page explains nothing at length.** `README.md` is what Troupe is in a
  paragraph, the first run in five steps, the ways in, a line per page saying when to read
  it, and what Troupe never does; at most 150 lines.
- **Each mechanism is explained on one page**, the one named for it, and every other page
  links there in a sentence: a session's life, Local only, steering, goals, approvals and
  budgets on `sessions.md`; inviting by name on `sessions-shared.md`; a transcript and the
  scratchpad on `transcript.md`; `troupe setup`, `troupe config` with no file, `troupe
  doctor` and signing in on `setup.md`; a profile on `profiles.md`; artifacts and where a
  file goes on `artifacts.md`; memory on `memory.md`; what a turn costs on `models.md`.
  A client's screen for one of them is on that page, both clients together, so
  `terminal-screen.md` keeps only what is the terminal's alone: keys, colours, the
  observer, the palette, the settings page, watch mode, the agent picker and the
  new-session screen.
- **No stub section**, as Decision 1032 has it for the admin pages: a heading followed only
  by a link goes, and the link is folded into the parent's prose. This replaces, for these
  pages, Decision 940's remedy of leaving a stub under each moved heading; the 400-line
  rule and the split along headings stay as 940 has them. Where a link from a page this
  change may not edit points at a removed heading, an `<a id>` keeps the anchor until that
  page moves its link.

**Not chosen.** A section per mechanism on the landing page and on the terminal's page as
well as on the mechanism's own: the three copies had drifted apart (the landing page said
the desktop app's profile page lists the agents a session will not have, which only the
terminal does, and that the desktop app shows Mermaid as source, which it draws).
Merging `configuration-layers.md` and `configuration-settings.md` back into
`configuration.md`: the merged page would pass 400 lines, so each stays a page with its own
introduction, and `configuration.md` says in its prose what each holds.

**What breaks if this is undone.** The landing page grows back into the whole manual, and a
mechanism explained three times is right in at most one of them.
