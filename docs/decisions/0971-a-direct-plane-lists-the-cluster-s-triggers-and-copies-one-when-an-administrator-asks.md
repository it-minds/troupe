---
number: 971
title: "A direct plane lists the `Trigger` resources in its namespace and never acts on one by itself: an administrator copies one into a row, which records the resource and its generation, and copies it again when it moves; drift reads both ways, and a removed resource leaves its row running"
date: 2026-10-29
status: accepted
issue: 857
paths:
  - apps/troupe_plane/lib/troupe/plane/gitops/trigger_copies.ex
  - apps/troupe_plane/lib/troupe/plane/gitops.ex
  - apps/troupe_plane/lib/troupe/plane/gitops/triggers.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/admin/api.ex
  - apps/troupe_plane/lib/troupe/plane/triggers.ex
  - apps/troupe_plane/lib/troupe/plane/triggers/trigger.ex
  - apps/troupe_plane/priv/repo/migrations/20261029000971_trigger_copies.exs
  - apps/troupe_plane/test/troupe/plane/trigger_copies_test.exs
  - charts/troupe/templates/plane-rbac.yaml
  - clients/gui/apps/console/src/views/Triggers.tsx
  - clients/gui/apps/console/test/trigger-copies.test.tsx
  - clients/gui/packages/client/src/admin.ts
  - docs/admin/gitops.md
  - docs/admin/bundles-and-triggers.md
symbols:
  - Troupe.Plane.Gitops.TriggerCopies
  - Troupe.Plane.Admin.triggers_repository/2
  - Troupe.Plane.Admin.trigger_copy/2
  - Troupe.Plane.Triggers.copy/5
gist: In direct mode the plane reads Trigger resources with the gitops pass's checks and acts only when an administrator copies one; a copy records copied_from and copied_generation (never resource_generation), keeps the row's id, key, runs and revisions, and nothing is removed or followed automatically
---

Issue #857. A deployment that kept its triggers in a repository and its plane in direct
mode had two copies of each trigger, the reviewed file and the row someone typed from it,
with nothing connecting them. This extends 736 and 737, which made a gitops plane's rows
follow the cluster, to a plane that does not follow it.

**What holds.** A direct plane lists the `Trigger` resources in its namespace
(`Gitops.list/1`, the pass's own listing) and reads each with the pass's own checks
(`Gitops.Triggers.read/2`), plus one a pass does not make: that the team is granted the
profile and the principal lists it. A pass leaves that to the firing, which reports it on
the run; a person about to press Copy is better told first. `admin.triggers.repository`
answers each resource with its generation, whether it passes and the reasons in words, and
where the team's row of its name stands. `admin.trigger.copy {resource}` makes the row, or
makes the row copied from it say what it says now. The row is changed in place, so it keeps
its id, URL, key, runs and revisions, and a document that moved is a revision as a put's
is. The copy is audited as `trigger.copy` with the diff and the revision, and a webhook
with no key is given one, shown once. A row of the resource's name that nobody copied is
taken over the same way, which is how a deployment's typed rows become copies.

**Two columns, not `resource_generation`.** `triggers.copied_from` and
`triggers.copied_generation` record the copy. 737's `resource_generation` means a row that
followed a resource, and its pass deletes such a row when the resource goes. A copied row
must not go by itself, so it carries none, and a gitops pass after a switch adopts it as it
adopts any row from direct mode: read into in place, `unchanged` where it is a clean copy.

**State is compared, not stored.** A row's state is taken at each listing by comparing its
fields with what the resource would make of them: `copied` where they agree, `changed`
where they differ and the generation moved past the copied one, `differs` where they differ
at the copied generation (a console edit), `gone` where the cluster has no resource of its
name. So drift shows both ways and a console put needs no hook. A resource that fails the
checks has no diff, since there is no row it would make.

**Its own method.** `admin.triggers.list` is unchanged in direct mode, as 737 left it. The
repository listing asks the cluster, which the list never needed, and a cluster that
cannot answer is said in the answer (`listed: false`) rather than taking the team's rows
off the page. Both methods are refused in gitops mode: the listing as `invalid_request`,
the copy as `managed_by_gitops`, audited, since there the rows follow the resources.

**RBAC.** The chart's direct-mode Role gets `get` and `list` on `triggers` and no write;
the gitops Role is as 737 left it.

**Not taken.** *Following the resources automatically in direct mode*: that is gitops mode,
which also locks the profiles, and a deployment may not be ready for that; a row that
changed under an administrator without their action is what direct mode exists to avoid.
*A per-deployment script turning a manifest into `admin.trigger.put`*: every deployment
writes and keeps its own, nothing records which file a row came from, and nothing says
when the two diverge. *A `recopy` method of its own*: a copy of a resource that has a row
is that row's re-copy, so one method with one argument does both, and the answer's `made`
says which it was. *Removing a copied row when its resource goes*: a removal is a decision,
and here the plane makes none.

Proof: `trigger_copies_test.exs` (listing with pass and fail reasons, a cluster that does
not answer, a copy with its generation and a key shown once, a refused copy, a team
admin's reach, a changed resource's diff and a re-copy keeping URL, key, runs and
revisions, a console edit that differs, a removed resource whose row keeps running, a
typed row taken over, a gitops plane refusing both and its pass unchanged, a switch that
changes nothing, the MCP tools, the chart's Role) and the console's
`trigger-copies.test.tsx`.
