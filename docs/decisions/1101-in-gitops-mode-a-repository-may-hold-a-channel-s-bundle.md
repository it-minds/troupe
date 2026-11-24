---
number: 1101
title: In gitops mode a repository may hold a channel's bundle as a ConfigBundle, which the plane publishes as the channel's next version when its hash differs from the one the resource last published
date: 2026-11-24
status: accepted
issue: 1198
paths:
  - apps/troupe_plane/lib/troupe/plane/gitops/bundles.ex
  - apps/troupe_plane/lib/troupe/plane/bundles.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/gitops.ex
  - apps/troupe_plane/priv/repo/migrations/20261124001198_config_bundle_resources.exs
  - charts/troupe/crds/configbundle.yaml
  - charts/troupe/templates/plane-rbac.yaml
  - clients/gui/apps/console/src/views/Bundles.tsx
gist: "ConfigBundle per channel, spec = document verbatim, no CRD defaults, <= 1 MiB; publish only when hash != hold's (never current's); refuse publish per held channel; removal releases; read before profiles"
---

Issue #1198. Narrows Decisions 736 and 737: their `managed_by_gitops` is per mode, and for a
bundle it is per channel; their removal deletes a row, and here it releases a channel.
Decision 125 holds: every change is still a new immutable version.

**The resource.** `ConfigBundle` (`troupe.dev/v1alpha1`, namespaced, `cb`), one per channel,
`metadata.name` the channel, `spec` the bundle document verbatim in its own snake_case, so
the hash of the file is the hash of the version and `admin.bundle.validate` proves which
version a commit is. The CRD keeps unknown fields, requires `schema`, and has no default,
since a default is content nobody committed and a hash that never matches. At most 1 MiB of
JSON, under etcd's limit; schema 1 only; a composed `profile:` channel is refused. The
optional `troupe.dev/revision` annotation is recorded and shown, never trusted.

**The pass.** Bundles are the first source, before profiles, so a profile and its prompt land
in one pass. A resource is checked as a publish is. `config_bundle_holds` keeps, per channel,
the hash and version the resource last published; the content is compared with that hash,
never with `Bundles.current/1`. Equal is unchanged; no hold and the current version's content
adopts it (`bundle.hold`); otherwise the next version by `system:gitops` with the generation
and revision on it (`bundle.publish`). A held version since retired is reported `retired`
and not published again. A removed resource deletes the hold (`bundle.release`) and retires
nothing. A revert is a new version. A resource at the hold's generation with nothing reported
is not checked again. A person's publish and the pass take one advisory lock per channel. A
profile added in the same commit is not yet a follower when its bundle is checked; its own
reach check catches a server its pods cannot reach.

**Refusals.** On a gitops plane `admin.bundle.publish` to a held channel is
`managed_by_gitops`, audited; any other channel publishes as before; `retire`, `validate` and
`preview` stay open. A direct plane reads no resource, and a person's publish there drops a
left-over hold. `admin.bundle.channels` lists channels with what the pass made of each.

## Not chosen

- Files by reference (a ConfigMap or OCI artifact per skill): a second object the hash must
  follow, and a grant the plane's Role lacks. A later issue if 1 MiB is hit.
- One resource per skill: an applier's half-applied commit would be a version nobody reviewed.
- Retiring on removal: every pinned session would move at its next start over a deleted file.
- Comparing with the current version: an administrator's retire would be undone 15 s later.

## If undone

Without the hold's hash the pass republishes a retired version every pass; with CRD defaults
it publishes every pass; refused per mode, every hand-published channel locks at the switch.
