---
number: 1035
title: PROTOCOL.md's admin method table is generated from the methods' declarations, in place between markers, and what no declaration says stays hand-written around it
date: 2026-11-17
status: accepted
issue: 1015
supersedes: [1009]
paths:
  - PROTOCOL.md
  - apps/troupe_plane/lib/mix/tasks/troupe.admin.reference.ex
  - apps/troupe_plane/lib/troupe/plane/admin/api.ex
  - apps/troupe_plane/lib/troupe/plane/admin/api/method.ex
  - .github/workflows/ci.yml
  - .github/workflows/dev-check.yml
  - scripts/ci
  - docs/developer/build.md
gist: Section 9's admin table is written by mix troupe.admin.reference from Admin.API's %Method{}s; never edit between its markers; a method declares its role
---

**The decision.** The table of admin methods in `PROTOCOL.md` section 9 is the part between
`<!-- admin-methods:begin -->` and `<!-- admin-methods:end -->`, written by
`mix troupe.admin.reference` from the `%Method{}` entries in `Troupe.Plane.Admin.API`: one
row per method, sorted by name, with its role, its risk (and the argument a destructive one
is confirmed by), the arguments it takes with their types, and its summary. `--check` fails
on drift in `ci.yml`'s `lint` job, `dev-check` and `scripts/ci`, and a plane test holds the
committed page to the render, so `mix check` fails too.

- **A method declares its role.** `role` is `:platform_admin` or `:admin` (a team admin
  too, for their teams). It is not enforced from the declaration; the handler's own check
  is, and the parity test holds the declaration to the checks the handler reaches.
- **Prose stays, once.** What no declaration says (membership is never editable, the shape
  of a refused team limit, `dry_run` on an older plane, where the GitHub and version pages
  are, `managed_by_gitops`'s data) is a few hand-written paragraphs beside the table. A
  method's answer and what it refuses go in its summary, which is also the MCP tool's
  description, so the page and a model read the same words.
- **This narrows Decision 1009** for this one table: 1009 let a table leave PROTOCOL.md
  only when a schema carried its meaning, onto a page of its own. The admin methods'
  declarations carry it (a summary and described arguments, which a model reads as the
  interface), and the table stays on the one page, so a client author still reads and
  searches one file. The rest of 1009 stands.

**Not chosen.** A generated page under `docs/protocol/` linked from section 9: a second
page for a reader to follow, for no gain over markers. Keeping the hand table: it had
drifted (runs.list's team, a GitHub App key it did not list, roles and risks nowhere), and
nothing compared it. Deriving the role from the handler's source in the task: the reference
would then depend on how `Admin` is written, not on what the method declares.

**If undone.** A hand edit between the markers is overwritten at the next run and fails CI
until then; dropping `role` leaves the table unable to say who may call a method.
