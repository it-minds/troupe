---
number: 737
title: In gitops mode a repository holds the triggers too, as `Trigger` resources the plane reads; a trigger's key, runs and revisions stay the plane's
date: 2026-09-30
status: accepted
issue: 186
paths:
  - ARCHITECTURE.md
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/gitops.ex
  - apps/troupe_plane/lib/troupe/plane/gitops/triggers.ex
  - apps/troupe_plane/lib/troupe/plane/triggers.ex
  - apps/troupe_plane/lib/troupe/plane/triggers/trigger.ex
  - apps/troupe_plane/lib/troupe/plane/web/live/layout.ex
  - apps/troupe_plane/lib/troupe/plane/web/live/triggers.ex
  - apps/troupe_plane/lib/troupe/plane/web/live/workers.ex
  - apps/troupe_plane/priv/repo/migrations/20260930000036_gitops_triggers.exs
  - apps/troupe_plane/test/troupe/plane/gitops_triggers_console_test.exs
  - apps/troupe_plane/test/troupe/plane/gitops_triggers_test.exs
  - charts/troupe/crds/trigger.yaml
  - charts/troupe/templates/plane-rbac.yaml
  - docs/admin/bundles-and-triggers.md
  - docs/admin/profiles-and-policy.md
gist: In gitops mode a repository holds the triggers too, as `Trigger` resources the plane reads; a trigger's key, runs and revisions stay the plane's
---

Issue #186. A
gitops plane's profiles were reviewed files and its triggers were rows somebody typed
into a console, so what fires unattended, as whom and with what prompt was the one
part of the fleet no repository could restore. Now a `Trigger` CRD, one resource per
trigger in the plane's namespace, is the second source of 736's pass, read after the
profiles so a trigger and the profile it names can land in one commit. Its name is
`<team>.<trigger>`: a trigger's name is unique in its team and a resource's in its
namespace, a dot is in neither, and a team said once has no second field to disagree
with. Its spec is the trigger's document in the CRD's spelling (`promptTemplate`,
`notifyUrl`, and `budgetMicros`, `maxTurns`, `wallClockSeconds` in `terms`), the
principal by subject; a field left out is its default, not what the row said. A
resource is used only if `admin.trigger.put` would have saved it and what it names is
here — the team, a service principal of that team, and a profile, which `put` never
checked and which a trigger fails on at every firing without. A spec key a `Trigger`
has not got is refused too, and the CRD keeps unknown fields so that a misspelt
`promptTemplate` reaches the plane instead of being pruned into a trigger that asks for
nothing. Otherwise 736 holds: reported and not used, a changed one left at the last
version that passed and still firing, a removed one deleted with its runs as
`admin.trigger.delete` did, each audited as `system:gitops` with the revision it made,
a row the cluster never had kept as `missing`. The row is changed in place, so its id,
URL and key survive every commit, and a row from direct mode is adopted by the
resource of its name. `admin.trigger.put` (enabling and disabling included) and
`admin.trigger.delete` refuse as `managed_by_gitops`, audited, the delete again except
for a `missing` row; switching a trigger off is a commit, or in a hurry a patch while
the applier is suspended, or disabling its principal. `admin.trigger.run` and
`admin.trigger.key.rotate` keep working: firing is something done with a trigger, not
what it is, and a key is not configuration. The key stays plane-held rather than a
Secret reference because the plane mints it and keeps only a salted hash, so a
resource has nothing to carry; a reference would give an internet-facing plane a
grant on Secrets its Role deliberately lacks, to hash a value it could mint; and a
rotation answers a leak, which cannot wait for a review and an applier's interval.
Teams, their grants and service principals stay the plane's database's, and a
trigger names them. Taking them into a repository later would need a `Team` resource
(the group it maps, its budget, retention and grants, with enabling and disabling
following it, and a prune that disables a team a decision rather than an accident)
and a `ServicePrincipal` resource without its secret, which would stay plane-minted
as a trigger's key does, applied before the profiles and triggers that name them.
`admin.triggers.list` carries `gitops` per trigger and lists a refused resource of the
team by name, and one naming no team here to a platform admin; the Triggers page is
locked with `Layout.locked/1`, which the profile editor now shares, and keeps run,
key and revisions. `admin.profiles.export` gives every trigger as
`triggers/<team>/<trigger>.yaml`, without the plane's own fields. The chart's gitops
Role gets `get`, `list`, `watch` on `triggers` and nothing else; the plane migrates
(`triggers.resource_generation`). Proof: `gitops_triggers_test.exs` (made, changed,
switched off, defaults, unchanged, removed, a failed list, a profile and a trigger in
one pass; refused for a team, a principal, a profile, a name, `put`'s checks and an
unknown key; a failed change still firing; the refusals over the API and MCP; a key
that survives a change; a run by hand; a `missing` row kept and deleted; the export
and its round trip keeping the id, revision and key; the CRD against the plane's
fields; direct mode) and `gitops_triggers_console_test.exs`.
