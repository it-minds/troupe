---
number: 736
title: In gitops mode a repository holds the profiles and the policy, and the plane reads them from the cluster and never writes git
date: 2026-09-29
status: accepted
issue: 186
paths:
  - ARCHITECTURE.md
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/application.ex
  - apps/troupe_plane/lib/troupe/plane/bundles.ex
  - apps/troupe_plane/lib/troupe/plane/cluster_policy.ex
  - apps/troupe_plane/lib/troupe/plane/fleet.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/profile.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/release_image.ex
  - apps/troupe_plane/lib/troupe/plane/gitops.ex
  - apps/troupe_plane/lib/troupe/plane/gitops/profiles.ex
  - apps/troupe_plane/lib/troupe/plane/gitops/report.ex
  - apps/troupe_plane/lib/troupe/plane/provision.ex
  - apps/troupe_plane/lib/troupe/plane/settings.ex
  - apps/troupe_plane/lib/troupe/plane/web/live/layout.ex
  - apps/troupe_plane/lib/troupe/plane/web/live/profile_editor.ex
  - apps/troupe_plane/lib/troupe/plane/web/live/workers.ex
  - apps/troupe_plane/priv/repo/migrations/20260929000035_gitops_sources.exs
  - apps/troupe_plane/test/support/fake_cluster.ex
  - apps/troupe_plane/test/troupe/plane/gitops_console_test.exs
  - apps/troupe_plane/test/troupe/plane/gitops_test.exs
  - apps/troupe_plane/test/troupe/plane/provision_test.exs
  - apps/troupe_plane/test/troupe/plane/release_image_test.exs
  - apps/troupe_plane/test/troupe/plane/settings_test.exs
  - charts/troupe/templates/plane-rbac.yaml
  - docs/admin/profiles-and-policy.md
gist: In gitops mode a repository holds the profiles and the policy, and the plane reads them from the cluster and never writes git
---

Issue #186. `provisioning_mode: gitops`
made a profile save a commit to a checkout configured only by `:gitops[:path]`,
which nothing set in a real plane, whose image has no `git` and no push credential:
the mode worked in tests. Now the `WorkerProfile` and `TroupePolicy` resources a
repository holds, applied by Flux or anything like it, are what a gitops plane runs
on. A cluster singleton (`Troupe.Plane.Gitops`) lists the profiles in the plane's
namespace every fifteen seconds and makes its rows follow them, making, changing and
deleting them, audited as `system:gitops`: a tick and not a watch, because a list
sees what is not there without a watch's bookmarks and relists, a plane that was
down is right at its first tick, and the change it waits for arrives after the
applier's own interval. A resource is used only if the plane could have saved it
itself (its annotations parse, it has an image, its `sessionsPerPod` is a class's,
the cluster policy allows it, nobody else sets the plane's fields); otherwise it is
reported in `gitops_reports`, the log once, `admin.profiles.list` and the console,
and not used: a new one gets no row, and a changed one leaves the last version that
passed. The plane still writes the three fields that are projections of its own
state, `spec.replicas`, `spec.teams` and `spec.mcpServers`, server-side as
`troupe-plane`, where they differ and only onto a resource something else holds. One
only the plane has written is reported `plane_only` and not written to, because three
fields applied by the only owner of the rest would give the rest up. It is the
manager name direct mode uses, so the first write after adoption releases what
direct mode took and a field the repository drops then leaves the cluster. The
`troupe.dev/drained` record (726) keeps its own manager and survives the applier,
which owns only what its manifest names. The plane's answers the CRD has no field
for are annotations (`troupe.dev/max-sessions`, `warm-workers`, `provisioner`), the
class is read off `sessionsPerPod`, and `release` is not followed: a manifest pins
its image, and 672's comparison against the last commit goes with the commit.
`admin.profile.put` and `admin.profile.delete` refuse as `managed_by_gitops`
(-32015), audited with `outcome: refused` as a refused break-glass login is; the
exception is deleting a row the cluster has no resource for, reported `missing`
after a switch and never deleted by the plane itself. There is no policy write to
refuse, the plane's grant on `TroupePolicy` being read-only already, and in gitops
mode its `:policy` configuration is not read. The console shows profiles locked, with
`gitops_source`, a display-only setting; `admin.profiles.export` gives every profile
and the policy as a repository would hold them, without runtime fields, the plane's
three or its drained record. `provisioning_mode` becomes the deployment's: a console
that could switch it back would be a lock with the key hanging beside it, and a
profile made then would be one the repository never saw and its applier never
prunes. A value stored before is ignored, and the chart's Role drops create and
delete on `WorkerProfile` in gitops mode. The plane migrates
(`profiles.resource_generation`, `gitops_reports`); another kind of resource joins
by implementing `Troupe.Plane.Gitops`'s behaviour. Proof: `gitops_test.exs`, against
a model of server-side apply's field ownership (made, changed, removed, refused, the
plane's fields, the drained record under Flux, the refusals over the API and MCP, the
export and its round trip, both switches), `gitops_console_test.exs`, and the
updated `provision_test.exs`, `release_image_test.exs` and `settings_test.exs`.
