---
number: 739
title: The documentation is one site, built from `docs/` and the documents its nav names elsewhere, and each document stays where whatever reads it looks for it
date: 2026-09-30
status: accepted
issue: 51
paths:
  - .github/dependabot.yml
  - docs/developer/ci.md
  - docs/developer/repo-structure.md
gist: The documentation is one site, built from `docs/` and the documents its nav names elsewhere, and each document stays where whatever reads it looks…
---

Issues #51
and #188. The docs were thorough and had no front page a reader could navigate:
nothing was published, and a reader browsing the repository met the tracks, the root
documents and the clients' own READMEs as three unrelated heaps. Now `mkdocs.yml` at
the root builds a site with MkDocs Material, which #51 names, and
`.github/workflows/pages.yml` builds it on every pull request and publishes it from
`main` to GitHub Pages, at `it-minds.github.io/troupe` until the product site (#189)
gives it a domain. The build is strict: a link to a page that is not there, a
`#fragment` naming no heading of it, a nav entry to a missing file, or a page left
out of the nav fails it. Heading anchors are spelt as GitHub spells them, so one
`#fragment` works in both places. The nav is by
reader — using Troupe, running a deployment, contributing, writing a client — each in
the order to read it, and `docs/README.md` says the same in prose for whoever reads
the repository on GitHub. MkDocs and its theme are pinned in `docs/requirements.txt`
and Dependabot moves them monthly, but not MkDocs to 2: that drops the plugin and
theme systems the site is built on, and Material requires 1, so leaving MkDocs 1 is a
choice for the product site (#189) to make, not a bump.

*Where documents live.* MkDocs builds one directory, and several documents a reader
needs are read where they are by something else: the TUI's tests read
`PROTOCOL.md`'s error table, the core's config test reads the YAML in the TUI's and
the daemon's READMEs, GitHub finds `CONTRIBUTING.md`, `SECURITY.md` and
`CODE_OF_CONDUCT.md` at the root, and code cites `ARCHITECTURE.md`, `PROTOCOL.md` and
decisions by number. So none of them moved. A nav entry that names no file in `docs/`
names one by its path from the root, and `docs/overrides/hooks.py` puts that file on
the site at the same path. Links stay written for GitHub, relative to their file, and
`scripts/doc-links.exs` keeps checking them; the hook rewrites each one for the site,
to the page where the site has it and otherwise to the file on GitHub at `main`, and
one that names nothing in the repository fails the build. A copy in `docs/` would be
a second version to drift, a symlink fails on a Windows checkout, and a plugin for it
would be a dependency doing what a page of Python does. The hook also reads `VERSION`
into the banner every page carries, so the site says which release it describes.

*The root.* It holds what somebody arriving at the repository needs, and what a tool
reads there. `.github/CI.md` is contributor documentation and moved to
`docs/developer/ci.md`; `.console-rig.exs`, a screenshot rig, moved to `scripts/`.
No reports, audits or programme briefs remained after #54. The three `DECISIONS.md`
files stay where they are: append-only records that changes add to while others are
in flight, cited by number, and a reader gains nothing from their moving. The two
plans under `docs/plans/` and `docs/program/` stay too, because #56, open, names them
by path. The clients' READMEs stay as each directory's front page, and are the
user's and the contributor's pages for their client on the site.

*Diagrams are Mermaid in the source.* The topology and the order of a sign-in and a
session (`ARCHITECTURE.md` §6), the session lifecycle (§4), the daemon on a person's
machine (`docs/user/README.md`), the sign-in alone (`docs/admin/roles-and-permissions.md`
§1), the supervision trees of a session and of the TUI's remote client
(`docs/developer/architecture.md` §3 and §6, which were drawn in text), and a turn
through the log (`docs/developer/tour.md`). The GUI README's path of a client, drawn
in box characters, is a sequence diagram. No diagram is a checked-in image;
`repo-structure.md`'s annotated tree is a listing and stays text. Contributors get a
tour of their own, `docs/developer/tour.md` — where things live, running the suite,
adding a tool, how the event log works — so neither they nor an operator reads the
other's track. Proof: `mkdocs build --strict` in `pages.yml` on this change, and
`doc-links.exs` and `check-neutral.exs` passing over the moved files.
