---
number: 934
title: "Every cluster-side step is the chart's or the operator's, and one they cannot own is a precondition the plane checks and prints the fix for: the operator labels each worker namespace with the lowest Pod Security level its pods need and the chart its own namespace (podSecurity), the operator replaces a pod that dials the control port in plaintext once TLS is required instead of waiting on a drain that cannot come, the plane checks its OpenBao grants look-only from one list that also writes docs/admin/openbao.md, and admin.groups.list says which groups seen in sign-ins no team links"
date: 2026-10-24
status: accepted
issue: 765
paths:
  - apps/troupe_operator/lib/troupe/operator/resources.ex
  - apps/troupe_operator/lib/troupe/operator/reconciler.ex
  - apps/troupe_operator/lib/troupe/operator/settings.ex
  - apps/troupe_operator/test/e2e/pod_security_test.exs
  - charts/troupe/values.yaml
  - charts/troupe/templates/namespace.yaml
  - charts/troupe/templates/_helpers.tpl
  - charts/troupe/templates/operator-deployment.yaml
  - dev/kind/values.yaml
  - scripts/remote-up
  - scripts/kind-upgrade-check
  - .github/workflows/cluster.yml
  - config/runtime.exs
  - apps/troupe_protocol/lib/troupe/kms/policy.ex
  - apps/troupe_protocol/lib/mix/tasks/troupe.openbao.policy.ex
  - apps/troupe_plane/lib/troupe/plane/kms_check.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/login.ex
  - apps/troupe_plane/lib/troupe/plane/identity.ex
  - apps/troupe_plane/priv/repo/migrations/20261024000934_group_last_seen.exs
  - clients/gui/apps/console/src/views/Overview.tsx
  - clients/gui/apps/console/src/views/Teams.tsx
  - docs/admin/openbao.md
  - docs/admin/installing.md
  - docs/admin/security.md
  - docs/admin/routine-tasks.md
symbols:
  - Troupe.Operator.Settings.pod_security_level/1
  - Troupe.KMS.Policy.plane_grants/1
  - Troupe.Plane.KMSCheck
  - Troupe.Plane.Identity.groups_seen/2
gist: "Operator labels worker namespaces' Pod Security level, chart its own; plaintext pods replaced under requireTls; OpenBao grants checked look-only from one list; unlinked groups listed"
---

# Every cluster-side step is the chart's or the operator's, and one they cannot own is a checked precondition

1.0's second gate (#765) is a live plane thirty days on one release with no hand step the
chart, the operator or a checked precondition does not own. The one live plane had four
such steps that nothing in this repository owned, each done by a person: the Pod Security
labels on `troupe-system` and on every worker namespace, new profiles' included;
`plane.controlTls.requireTls: false` through an upgrade and back to `true` after; an
OpenBao policy added to the plane's role when a release started signing with a key of the
plane's own; and an identity provider group typed by its identifier, which nobody could
read off anything the plane showed. This decides who owns each.

## Pod Security labels: the operator's for worker namespaces, the chart's for its own

The operator puts `pod-security.kubernetes.io/enforce`, `audit` and `warn` on every worker
namespace it applies, at every pass, so a namespace made before this is labelled at the next
one. One level for all three: the lowest that admits the pod the operator's settings make
(`Settings.pod_security_level/1`). Measured against a real API server, a server-side dry run
of the worker pod at each level:

- with `worker.userNamespaces` (`hostUsers: false`, `procMount: Unmasked`, Decision 890)
  `restricted` and `baseline` both refuse it, on `procMount` alone, user namespace or not
  (Kubernetes 1.34, the kind cluster's). So `privileged`;
- with seccomp `Unconfined` (the kind cluster's), `baseline` refuses it: `privileged`;
- otherwise `restricted` admits it, AppArmor `Localhost` and the seccomp profile included.

The chart labels `troupe-system`, when it makes it, with `podSecurity.level`, or by default
with the lowest the chart's own pods need: `privileged` while the DaemonSet that puts the
workers' profiles on the nodes runs (a host mount, root, an unconfined AppArmor container),
`restricted` otherwise. The cluster job checks that claim each run: every pod the chart
makes is dry-run in a namespace labelled as the chart labels its own. One switch,
`podSecurity.labels` (default on), turns off both; off, nothing is written and nothing
somebody else wrote is removed, since server-side apply drops only what its own field
manager set.

**Not chosen:** the same three labels at a lower `warn` than `enforce`, so a privileged
namespace says what it would refuse. Every pod the operator makes would then carry a
warning about the very field it was made with, and a warning nobody can act on teaches
people to skip warnings. **Not chosen:** a cluster-wide default level in the kind cluster's
API server, so the suite would fail on an unlabelled namespace. It needs the cluster made
again with an admission file and exemptions for Cilium, ingress-nginx and the local
storage provisioner; the dry runs below prove the same thing on the cluster as it is.

The kind cluster's `troupe-system` also runs the development dependencies, which
`baseline` admits and `restricted` does not, so `dev/kind/values.yaml` names `baseline` and
`scripts/remote-up` raises it to `privileged` where the AppArmor DaemonSet runs: the
documented case of something sharing the namespace.

## A plaintext pod under requireTls: replaced, not waited on

Reproduced on kind: a plane run with `plane.controlTls.enabled: false`, a pod made then,
which dials in plaintext, and an upgrade to `enabled` and `requireTls: true`. The plane
closes the pod's connection at its first byte, once a minute in the log with the count;
the pod stops heartbeating and takes no session; the profile reports `UpgradePending`,
"waits to be drained", and stays so. The upgrade (Decision 726) waits for the plane to
drain a pod behind, and the plane drains only a pod that can reach it, so the pod and every
session on it were cut off for good. The live plane avoided it by running `requireTls:
false` through the upgrade from 0.18, whose operator made plaintext pods, and turning it
on once the old pod had gone.

The operator now replaces such a pod without a drain: one behind, whose worker container
has no `TROUPE_PLANE_CA_PATH` (a pod is told where the CA is exactly when it dials with
TLS), where the plane takes TLS only (the chart passes `requireTls` to the operator) and
the current revision dials with TLS (so the replacement can enrol). Still one at a time and
the highest ordinal first, as every replacement is. The deleted pod's own stop drains it
(`Troupe.Worker.Drain.on_stop/1`): its sessions are put to sleep inside the grace period,
as for any pod something other than the plane stops. With the fixed operator on the same
cluster the pod was replaced within a pass and its successor enrolled over TLS.

Turning `requireTls` from `false` to `true` is then the upgrade and nothing else, which
`values.yaml` says; `false` stays for a workload of one's own that dials without TLS. This
adds one case to Decision 726's and undoes nothing of it.

**Not chosen:** the plane taking a plaintext connection from a pod behind, to drain it.
That is plaintext on the control port again, for whoever can claim to be such a pod.

## OpenBao: a precondition, checked look-only and printed from one list

Writing a policy takes an OpenBao administrator, which the plane never is and must not
be. So what the plane's role must hold is a precondition, and `Troupe.KMS.Policy.plane_grants/1`
is the one list of it: per grant, its policy name, what it is for, what fails without it,
and its rules, rendered as the policies always were (the texts are byte for byte those of
`plane/1`, `signing/2`, `plane_signing/2` and `github_app/3`, which now render from the
same rules). From that list:

- `Troupe.Plane.KMSCheck` asks OpenBao `sys/capabilities-self` at a concrete path for each
  rule (the `default` policy allows it; nothing is made, signed with or read) and
  `auth/token/lookup-self` for the policies the token carries, once at start in the log and
  on every platform admin's `admin.overview` as `openbao`. A grant it lacks is a sentence
  (what the plane may not do, what fails, which capabilities on which path) and the lines
  that grant it: `bao policy write` with the policy, and the role's `token_policies` with
  the token's own policies kept, or a new static token. A plane that cannot log in at all
  gets the role line. The console's Overview lists each grant and puts a missing required
  one under *Needs attention*. The GitHub App's grant is optional, and missing it leaves
  the plane healthy.
- `mix troupe.openbao.policy` writes `docs/admin/openbao.md`, the page an administrator
  runs the lines from, with the manual root steps; a test fails when it is stale.

A team admin's overview has no `openbao`: the key manager is the platform's.

## Groups nobody links: listed with when they were seen

`groups.last_seen_at` is set at every sign-in for each group its claim carries
(`Identity.groups_seen/2`), and `admin.groups.list` says of each group whether a team
draws on it (`linked`, by `team_group_links`) and when it was last seen. The console's
Teams page lists, for a platform admin, the groups seen in sign-ins that no team draws on,
newest first, each with a button that opens *Enable a group as a team* on it; the Members
tab's link list marks them too. Nothing is granted by being listed: a group's people reach
nothing until a team links it and is granted a profile. A group only SCIM pushed has no
`last_seen_at` and is not in that list; it is no news from a sign-in.

## What stays manual

The OpenBao administrator's lines on `docs/admin/openbao.md`, which the plane checks and
prints. Labelling the ingress controller's namespace `troupe.dev/ingress=true` and the
Secrets each worker namespace needs stay where they were: neither is named by #765's slot,
and each is said where it is needed.

## Proof

- `Troupe.Operator.ResourcesTest` (the labels at each setting), `ReconcilerTest` (a
  namespace made without them is labelled; a plaintext pod under `requireTls` is replaced
  undrained, and is waited for while the plane takes plaintext, while it dials with TLS, or
  while the current revision has no CA either).
- `Troupe.E2E.PodSecurityTest`: the worker namespace's three labels, the worker pod as its
  StatefulSet makes it admitted at that level and refused one below, no `FailedCreate` for
  Pod Security, and `troupe-system` labelled. The cluster job's dry run of every pod the
  chart makes at the level it labels its namespace with, both ways.
- `Troupe.KMS.PolicyTest` (the page is current; every grant and path is on it; the policy
  texts unchanged) and `Troupe.Plane.KMSCheckTest`, against the development OpenBao with
  tokens holding some grants and not others.
- `Troupe.Plane.UnlinkedGroupsTest`, and the console's overview and teams tests.
