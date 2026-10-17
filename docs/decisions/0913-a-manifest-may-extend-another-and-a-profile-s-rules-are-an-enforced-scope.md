---
number: 913
title: "A repository's WorkerProfile may name the profile it extends in spec.extends and say only what differs; the plane resolves it and writes the flat profile in effect into status.effective, which the operator and admission read, the operator creating nothing until it is there; and a profile's spec.permissions are an enforced scope on its pods, each profile of a chain its own, a parent's rules kept, and a shell deny refusing a person's own ! command there too"
date: 2026-10-16
status: accepted
issue: 655
paths:
  - charts/troupe/crds/workerprofile.yaml
  - charts/troupe/templates/admission-policy.yaml
  - charts/troupe/templates/plane-rbac.yaml
  - apps/troupe_protocol/lib/troupe/worker_profile.ex
  - apps/troupe_operator/lib/troupe/operator/reconciler.ex
  - apps/troupe_operator/lib/troupe/operator/skip_observed.ex
  - apps/troupe_operator/lib/troupe/operator/watch.ex
  - apps/troupe_operator/test/troupe/operator/reconciler_test.exs
  - apps/troupe_operator/test/e2e/extends_test.exs
  - apps/troupe_plane/lib/troupe/plane/gitops.ex
  - apps/troupe_plane/lib/troupe/plane/gitops/profiles.ex
  - apps/troupe_plane/lib/troupe/plane/provision.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/extends.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/profile.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/test/support/fake_cluster.ex
  - apps/troupe_plane/test/troupe/plane/gitops_extends_test.exs
  - apps/troupe_core/lib/troupe/config/permissions.ex
  - apps/troupe_core/lib/troupe/session/shell.ex
  - apps/troupe_worker/lib/troupe/worker/session/restore.ex
  - apps/troupe_worker/test/troupe/worker/profile_rules_test.exs
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/gui/packages/client/src/config.ts
  - clients/gui/apps/console/src/views/Profiles.tsx
  - clients/gui/apps/console/src/views/RuleLists.tsx
  - docs/admin/profiles-and-policy.md
symbols:
  - Troupe.WorkerProfile.in_effect/1
  - Troupe.Plane.Gitops.Profiles.order/1
  - Troupe.Plane.Provision.record_effective/2
  - Troupe.Plane.Fleet.Extends.rules/1
  - Troupe.Session.Shell.denied/3
  - Troupe.Operator.SkipObserved
gist: "GitOps child: spec.extends as written, plane writes status.effective, operator waits without it; profile rules a scope per profile, parent's kept; deny refuses !cmd on pods"
---

#655's slice 4 and #724, as the maintainer decided them on 2026-10-16 and the slot brief
put them: both change the `WorkerProfile` resource, and they share one cluster run. Two
things Decision 907 and Decision 908 left are settled here: 908's "GitOps refuses
`extends`" rule is gone (its §GitOps mode is replaced by this), and 907's "a WorkerProfile
carrying rules" and "a `deny: [shell]` and a person's own `!cmd`", both left for later.

## extends in a repository

**What Flux applies is what was written.** A manifest names one parent in `spec.extends`
and says only what differs, by Decision 908's rules (910's budget and bundles included).
`spec.image` is no longer required where `spec.extends` is set (a CEL rule on the spec), and
the `llm` rule that every `llm` field needs `llm.endpoint` moved from `llm` to the spec, so
it passes a child that has the endpoint from its parent: the plane checks the profile the
two come to. `spec.budgetMicros` is the profile's monthly budget in a manifest.

**The plane resolves, into the status.** `Gitops.Profiles.read/2` reads a child's manifest
as what it wrote (`own`, as `admin.profile.put` would have taken it), resolves the chain
against its rows (`Extends.resolve/2`), and checks the profile in effect: the image, the
class, the policy, the row's own changeset, a budget above the parent's, a missing parent,
a cycle, a chain too long. The row holds the profile in effect, as in direct mode, so
placement, the scaler and the activation need no change. `take/4` then writes the flat spec
into `status.effective` (with `chain`, `from`, a `revision` and the `observedGeneration`
it resolved), by server-side apply on the status subresource as `troupe-plane`, only where
it differs. The plane writes nothing of the manifest's spec but `replicas`, `teams` and
`mcpServers`, which it writes onto every resource, so Flux and the plane never own the same
field. Its gitops Role gains `patch` on `workerprofiles/status` and nothing else.

Not chosen: a parent kind the operator resolves (#655's other option), which would put the
chain in the operator and make admission judge a profile it cannot see whole; and writing
the flat spec onto the resource, which Flux owns and would put back at every interval.

**A pass reads parents first** (`Gitops.order/1`, an optional callback of the engine), so a
parent's change in the repository reaches its children's status in the same pass, and their
pods roll as for any change. A child's own change runs the last profile in effect until the
plane's next pass.

**Defaults are not the child's.** The API server fills `sessionsPerPod`, `configBundleChannel`,
`orgMount` and `storage.size` into every resource. In a child each counts only where some
field manager owns it, read from `managedFields`, so a default never replaces the parent's
value. In gitops mode `sessionsPerPod`, `resources` and `storage.size` are the repository's
numbers, not the size class's, so `Extends` treats them as replaced where a child sets them
(direct mode is unchanged).

**The operator reads the status, and waits without it** (the brief's question). For a
resource with `spec.extends`, `WorkerProfile.in_effect/1` gives the spec from
`status.effective.spec` with the plane's three from the spec; with no block yet it answers
`{:waiting, sentence}`, and the operator writes `Resolved: False, AwaitingPlane` and
`Ready: False` and creates nothing. Running the spec as written would make pods from what
differs from the parent alone, missing the parent's image, endpoint, egress and rules; that
is the failure the brief named, and a profile that waits is visibly waiting. Once there it
writes `Resolved: True` naming the chain and records `status.effectiveRevision`; the
operator's own status writes leave `effective` out, so it never owns the plane's block or
puts an older one back. Because a resolution arrives as a status write and no new
generation, `Bonny.Pluggable.SkipObservedGenerations` would have ignored it until the
resync; `Troupe.Operator.SkipObserved` halts an event only when the generation and, for a
child, the revision have both been run.

**Admission reads the status too.** The `ValidatingAdmissionPolicy` matches
`workerprofiles/status` as well, under a match condition that holds only for a status write
that changes `status.effective`, so the operator's own conditions are always writable
(that is how it reports a policy that tightened under a profile). For a child, `variables.spec`
is `status.effective.spec` where there is one, and the spec as written before; `replicas`,
`teams` and `mcpServers` are read from the spec for every profile. A child with no status is
judged by what it wrote, the image only where it names one.

**A child that stops extending** is read whole again, and the plane applies an empty status
as its manager, which takes its block away. The `troupe.dev/extends` annotation is refused,
saying to use `spec.extends`. `admin.profiles.export` writes a child as a repository now holds
it: `spec.extends` and what it wrote.

## Per-tool rules on a profile (#724)

**Shape and check.** `spec.permissions` is config's shape, `deny`, `ask` and `allow` lists
of rules, checked by `PermissionRule.check_set/1` in the profile's changeset, so
`admin.profile.put` and a manifest's reading both refuse a rule the pods could not read,
with the reader's sentence. The CRD declares the three lists; it does not parse rules in CEL.

**On the pods, a scope.** The plane sends `permission_rules` in every activation beside the
pin, as it sends `personal_tools` (Decision 879): no pod restarts, and a change reaches a
session at its next wake. Each rule carries the profile that wrote it, and the worker adds
them to the session's rules as layer `:profile`, source the profile's name. Decision 907's
merge then holds unchanged: of every scope's verdict the strictest, so nothing in a
repository's files loosens them; the profile's `allow` stands under
`managed_permission_rules_only`, as the organisation's does, since it is the platform's.
`Permissions.scope/1` names it "the worker profile <name>", and so do the TUI's approval line,
its `/settings` and the GUI's `ruleScope`.

**extends.** A chain's rules are sent per profile (`Extends.rules/1`), each profile's a scope
of its own, not one merged list: inside one scope the more specific rule decides, so a
child's `allow: [shell(git status)]` in the same list as its parent's `ask: [shell]` would
loosen the parent's. Kept apart, the parent's `ask` holds. A child adds rules and cannot drop
its parent's. The profile in effect's `spec.permissions` is the union, each rule's `from` its
profile, for the console and `admin.profile.get`.

**A person's `!` command** (907 left it open). On a pod a `deny` for `shell` of the worker
profile's refuses a command a person types with `!` (`Shell.denied/3`), answering
`forbidden` with `setting: permissions` and the rule. Only the profile's: a person's own
files and a repository's could be changed by the person anyway, and a project's `deny`
refusing its owner's typing would be surprising. An `ask` does not apply: the person who
typed it is who it would ask. It reads the line as the agent's call is read, so `ls && curl`
is refused by `deny: [shell(curl)]`; like the agent's, it is a reading, not a sandbox.

**Shown.** A refused call and an asked approval name the profile; the console's profile page
lists every rule in effect with the profile it came from, and its editor edits a profile's
own rules with the organisation's rule editor's reading (Decision 912), factored into
`RuleLists.tsx`. `troupe config --explain` is about a machine's files and does not list a
pod's profile rules; there is no method that explains a pod session's configuration, which
is a follow-up.

## Proof

On the chunk's tip `gitops_extends_test.exs` failed every test (a manifest naming a parent
was refused outright), `profile_rules_test.exs` (worker) ran the denied command, and the
operator ran a child's spec as written. Now: a parent and a child applied as Flux applies
them resolve to the child's row and `status.effective`, the plane owning only its three spec
fields and that block; a parent's change reaches the child in the same pass and nothing is
written again after; a default the API server filled in leaves the parent's value; a missing
parent, a budget above it and an unreadable rule are refused; a child that stops extending
loses its block; the export names the parent. The operator waits with `AwaitingPlane` and
creates nothing, runs the status's spec and records its revision, refuses one outside the
policy, and `SkipObserved` lets a new revision through. A worker refuses the agent's `touch`
by the parent's `deny` over the child's `allow`, names the profile, refuses the person's
`!touch` and runs it once the rule is gone at the next activation. Core: a profile `deny`
over a user `allow`, a profile `ask` asking with `scope: profile`, the profile's `allow`
under `managed_permission_rules_only`, `Shell.denied/3`. The cluster suite's
`extends_test.exs` refuses a person's command by a profile's `deny` on a real pod, and
switches the plane to gitops to apply a parent and a child from manifests and see the
child's pods run the merge and roll onto the parent's change.
