---
number: 1042
title: ARCHITECTURE.md is a map under 150 lines, the design is told once on two pages that do not overlap, and a component README says what its directory is and how to build and test it
date: 2026-11-17
status: accepted
issue: 1017
supersedes: [940]
paths:
  - ARCHITECTURE.md
  - docs/developer/architecture.md
  - docs/developer/architecture-remote.md
  - clients/tui/README.md
  - clients/gui/README.md
  - clients/vscode/README.md
  - apps/troupe_daemon/README.md
  - mkdocs.yml
gist: ARCHITECTURE.md <=150 lines, parts/boundaries/transports/state only; harness+clients and plane+pods pages never overlap; READMEs build and test, product on user pages
---

**The decision.**

- **`ARCHITECTURE.md` is the map**, at most 150 lines: the shape and its three rules, the
  apps and releases, the boundaries the build enforces, the transports and where state
  lives. It explains no mechanism.
- **Two pages tell the design, each mechanism once.** `docs/developer/architecture.md` is
  the harness as a laptop and a pod both run it (a session, the agent, tools, the failure
  matrix, the wire, lifecycle, old logs) and the clients' internals;
  `docs/developer/architecture-remote.md` is the plane, the pods, the operator and what a
  session carries remotely, with their supervision trees. Neither keeps a stub of the
  other's sections; a page links the one that owns a mechanism. Code that cites the
  transition table or the failure matrix cites `docs/developer/architecture.md`. This
  replaces Decision 940's clause that `ARCHITECTURE.md` keeps section 2 and its
  stub-heading remedy for these three pages; the 400-line rule stays.
- **A component README** (`clients/tui`, `clients/gui`, `clients/vscode`,
  `apps/troupe_daemon`) says what its directory is, how to build, test and ship it, and
  links to the user or admin page that explains the product. The terminal client's and
  the daemon's product pages are `docs/user/terminal-client.md` and `docs/user/daemon.md`;
  VS Code's is `docs/user/vscode.md`. Where a page this change may not edit links an
  anchor that moved, an `<a id>` keeps it until that page moves its link.

**Not chosen.** One architecture page under 400 lines: the three held about 920 lines
with little repeated, so one page would have meant cutting mechanisms, not repeats.
Keeping `ARCHITECTURE.md` as the harness design with the map on top: it stays near 300
lines, and the code page beside it repeats its supervision order and transports.

**What breaks if this is undone.** A mechanism explained on the map and again on a page
drifts, as the session's supervision order already had (once in prose, once as a tree),
and a README that explains the product is a second user page nobody keeps in step.
