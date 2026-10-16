---
number: 908
title: "A worker profile may extend one other profile; the plane resolves the two by #655's merge rules into the flat profile it writes to the cluster, keeps what the child wrote beside it, and rewrites every child, after a preview, when the parent changes"
date: 2026-10-16
status: accepted
issue: 655
paths:
  - apps/troupe_plane/lib/troupe/plane/fleet/extends.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/profile.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/admin/api.ex
  - apps/troupe_plane/lib/troupe/plane/bundles.ex
  - apps/troupe_plane/lib/troupe/plane/provision.ex
  - apps/troupe_plane/lib/troupe/plane/gitops/profiles.ex
  - apps/troupe_plane/priv/repo/migrations/20261016000908_profile_extends.exs
  - apps/troupe_plane/test/troupe/plane/extends_test.exs
  - clients/gui/apps/console/src/views/Profiles.tsx
  - clients/gui/apps/console/test/profiles.test.tsx
  - clients/gui/packages/client/src/admin.ts
  - clients/gui/packages/client/test/support/admin.ts
  - clients/gui/packages/client/test/support/extends.ts
  - docs/admin/profiles-and-policy.md
symbols:
  - Troupe.Plane.Fleet.Extends
  - Troupe.Plane.Admin.profile_put/2
  - Troupe.Plane.Admin.profile_get/3
  - Troupe.Plane.Admin.preview/2
  - Troupe.Plane.Admin.profile_delete/2
gist: "extends: one parent, resolved by the plane into the flat profile the cluster gets; credentials and grants never inherited; a parent in use is not deleted"
---

#655 slice 1: a profile that extends a standard profile, in the plane, in direct mode.
Bundle composition (slice 2), a per-profile budget (slice 3) and extends in a repository's
manifest (slice 4) are not here.

## One parent

A profile names at most one profile it `extends`. #655 leaves open whether there may be
several (a standard and a "data access" mixin). One, for now: with one parent every field
has one place it can come from, which is what makes the provenance view a list rather than a
puzzle, and the rules below need no order between parents and no way to settle two parents
that disagree. A mixin is a profile in the chain: `standard` → `data-access` → `data-team`.
Several parents can come later as an order over the same rules; one parent is a chain of
length one in that world, so nothing written now has to be undone.

A chain is at most **four** profiles, counting the one that extends nothing, with every
profile below the one being written counted. A missing parent, a profile extending itself
and a cycle are refused by `admin.profile.put` with a sentence naming them.

## The merge rules, for what slice 1 covers

From #655's table:

| Field | Rule |
| --- | --- |
| `egress.fqdns`, `egress.gitHosts` | **added**: the parent's, then the child's the parent lacks; each still checked against TroupePolicy, on the profile in effect |
| `mcpServers` | **added** by name. A child's server with a parent's name replaces it only with `override: true`, which the resource has no field for and does not get; otherwise the parent's is kept and the clash is reported |
| `max_sessions` | **narrow only**: the lower of the two where either sets one |
| `personalTools: forbid`, `repositoryOverridesBundle: false` | **restrict only**: a parent's restriction holds whatever the child says; otherwise the child's value, or the parent's |
| `image`, `size_class`, `provisioner`, the `llm` fields but `secretRef`, `storage.storageClassName`, `configBundleChannel`, and any other spec field | **replaced** where the child sets it |
| `llm.secretRef`, `mcpIdentities` | **never inherited** (Decision 747): a child names its own, in its own namespace |
| grants | **never inherited**: the resource's `teams` is projected from the grants on the child's own name |
| `warm_workers` | **never inherited**: how many of the child's own workers stay up is the child's |

An empty value (absent, null, `""`, `[]`, `{}`) is one the child did not set. A child
therefore cannot take away what its parent has, which is #655's answer to "may a child
remove?". An explicit `false` for `repositoryOverridesBundle` and `forbid` for
`personalTools` are restrictions; absent is no opinion, and the child decides. Treating
absent as the restriction would make it impossible for any extension of a standard that says
nothing to allow either, which is not what a standard that says nothing means.

Choices #655's table does not make:

- **`github.permissions`, `orgMount` and any field the resource gains are replaced**, not
  narrowed. The default for a field nobody has classified is "replaced where the child sets
  it", so a new field is inherited rather than silently lost; a new credential must be added
  to the never-inherited list in `Troupe.Plane.Fleet.Extends` when it arrives.
- **Profiles have no default terms yet.** #655 lists them with `max_sessions` as narrow-only;
  there is no field to narrow, and the per-profile budget is slice 3. When either arrives it
  takes the narrow rule.
- **Bundles stay as they are** (slice 2 composes them): the child's `configBundleChannel` is
  its own, or its parent's where it sets none, and its pods load that channel's one bundle.
  The resource's `mcpServers` is the parent's servers with the child's added: a child on its
  own channel gets its channel's servers as its own, and a child on its parent's channel has
  them from the parent. Until slice 2, a child on its own channel has its parent's servers in
  its resource (egress, the identity check) but not in the bundle its pods load.
- **A parent's model key is not the child's**, so a child that has its model endpoint from a
  parent with a key, and names no key of its own, is told so in the effective view's
  `problems`. An inherited server that calls with client credentials and has no identity in
  the child's `mcpIdentities` is in `identity_problems`, as a missing identity is today.

## The plane resolves; the operator sees flat profiles

The row keeps two things: `own`, what the child's administrator wrote, as written, and its
columns and `spec`, the profile in effect. Everything that reads a row (placement, the
scaler, the policy check, the reach check, `Provision.manifest/1`) reads the profile in
effect and needs no change; the operator, admission and the worker see a flat
`WorkerProfile` as before. No CRD change.

`admin.profile.get` answers `spec` and `written` as the profile wrote them (an editor loads
those and sends them back, so a save keeps following the parent instead of copying it), the
summary as the profile in effect, and `extended_by`. With `effective: true` it adds the chain,
the resolved profile, and `fields`: each path and value with the profile it came from, one
entry per host and per MCP server.

## A parent's change reaches its children

`admin.profile.preview` of a parent lists every profile below it (`extended_by`) as the write
would leave it: its diff, the policy's verdict on it, and a problem that would refuse the
write. `admin.profile.put` checks each the same way before writing anything and refuses,
naming the child, a change that would leave one the row or the policy refuses (a parent
dropping `llm.endpoint` that a child's `llm.model` needs, say). Applied, it rewrites every
child's row and resource in order, parent before child, and records **one** audit event, the
parent's `profile.put`, with `extended_by` naming each child and its diff. A child's pods
roll as for any change to its resource. A bundle published to a channel rewrites the
profiles below each profile it projects onto, in the same way.

## Deleting or renaming a parent

A profile others extend is not deleted: `admin.profile.delete` answers `conflict` with
`extended_by`, and says to make each extend another profile, or none, first. Taken away at
once, each child would lose every field it has from the parent in one step, and its pods
would roll onto whatever was left. A profile's name is its resource's and is never changed
in place, so a rename is a new profile and a delete, and the delete is refused the same way.

A put that names no parent on a profile that had one keeps what it had in effect, with the
put's own fields laid over it: the change is to what it follows, not to what its pods run.

## GitOps mode

Refused for now, with a sentence. `admin.profile.put` with `extends` on a gitops plane is
`managed_by_gitops` saying that a repository's manifest holds the whole profile until a plane
resolves `extends` from a repository (slice 4). A `WorkerProfile` the plane reads that names a
parent (`spec.extends` or the `troupe.dev/extends` annotation) is refused, not read as flat.
A row read from a resource extends nothing. `admin.profiles.export` writes a child's manifest
whole, as it is in effect, with a note that the repository's copy no longer follows its
parent.

## Proof

On the chunk tip the new `extends_test.exs` failed eleven of twelve: `extends` was dropped by
`admin.profile.put`, and `data-team`'s `llm.model` was refused for want of the endpoint its
parent gives. Now, against `FakeWorkerProfiles`, the resource written for `data-team` is
exactly the merge (egress and servers added, endpoint and permissions inherited, model
replaced, `forbid` held, key and identities and grants not inherited, ceiling narrowed); a
change to `standard` is previewed in `data-team` and then reaches its resource, audited once
with `extended_by`; a bundle published to `standard`'s channel reaches `data-team`; a missing
parent, a cycle, a fifth profile, a parent deletion, and a gitops put and manifest are
refused with their sentences. The console's `profiles.test.tsx` reads a child's fields with
where they came from, makes a child in the editor leaving the rest to its parent, previews a
parent's change in the child and applies it, and shows a parent's deletion refused.
