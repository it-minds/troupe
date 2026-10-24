---
number: 939
title: "A worker namespace is complete when the operator made it: the operator copies, by name, each Secret its pods mount from the plane's namespace (one a profile names only when the Secret is labelled for workers), labels the ingress controller's namespace where the installation names it and checks the label is somewhere where it does not, and the kind cluster's plane logs in to OpenBao under the documented policies alone"
date: 2026-10-24
status: accepted
issue: 765
paths:
  - apps/troupe_operator/lib/troupe/operator/worker_secrets.ex
  - apps/troupe_operator/lib/troupe/operator/ingress_check.ex
  - apps/troupe_operator/lib/troupe/operator/reconciler.ex
  - apps/troupe_operator/lib/troupe/operator/settings.ex
  - apps/troupe_operator/test/troupe/operator/worker_secrets_test.exs
  - apps/troupe_operator/test/troupe/operator/ingress_check_test.exs
  - apps/troupe_operator/test/e2e/no_hand_steps_test.exs
  - apps/troupe_operator/test/e2e/credentials_test.exs
  - apps/troupe_protocol/lib/mix/tasks/troupe.openbao.policy.ex
  - charts/troupe/crds/workerprofile.yaml
  - charts/troupe/templates/operator-rbac.yaml
  - charts/troupe/templates/operator-deployment.yaml
  - charts/troupe/values.yaml
  - charts/troupe/values.example.yaml
  - charts/troupe/values.small.yaml
  - config/runtime.exs
  - dev/kind/values.yaml
  - dev/kind/dependencies.yaml
  - dev/kind/openbao-plane.yaml
  - scripts/kind-up
  - scripts/remote-up
  - clients/gui/apps/console/src/views/Overview.tsx
  - docs/admin/configuration.md
  - docs/admin/installing.md
  - docs/admin/README.md
  - docs/admin/monitoring.md
  - docs/admin/security.md
  - docs/admin/routine-tasks.md
  - docs/developer/conventions.md
symbols:
  - Troupe.Operator.WorkerSecrets
  - Troupe.Operator.IngressCheck
  - Mix.Tasks.Troupe.Openbao.Policy.render_kind/0
gist: "Operator copies worker Secrets by name from troupe-system (profile-named ones only if labelled troupe.dev/worker-secret=true); ingress label owned or checked; kind plane on a narrow role"
---

# A worker namespace is complete when the operator made it, and the ingress label is a checked precondition

Decision 934 left two cluster-side steps where they were: the Secrets every worker
namespace needs, copied in by a person for each new profile, and the
`troupe.dev/ingress=true` label on the ingress controller's namespace. #765's second gate is
a live plane with no hand step the chart, the operator or a checked precondition does not
own, so this decides who owns these two. It extends Decision 934 and undoes nothing of it.

Reproduced on the kind cluster before the change: the operator's role had no verb on
Secrets, so a profile whose `llm-credentials` and `troupe-object-store` were in its
namespace reported `SecretMissing=True` naming both (the condition looked and was refused);
`scripts/remote-up` and the cluster suite (`World.secrets!/1`) copied both into every new
worker namespace by hand; and remote-up labelled `ingress-nginx` itself.

## The Secrets: copied by the operator, by name

Each Secret is kept once, in the plane's namespace, and every pass copies the ones a
profile's pods mount into its namespace (`Troupe.Operator.WorkerSecrets`), after the
namespace and before the StatefulSet, so a new profile's first pod finds them. A rotation
reaches the copies within a resync (thirty seconds; Bonny's `:reconcile` always goes
through), and the pods at their next start, as before. A copy carries the operator's marker
and the profile's label and a `troupe.dev/copied-from` annotation, goes with the namespace,
and is deleted when the profile stops naming it, found by the names the last pass recorded
in `status.copiedSecrets` (a new status field in the CRD).

Only names, never a pattern, from two places trusted differently:

- **The installation's**: `objectStore.secretName`, `imagePullSecrets`, and
  `operator.tlsSecretName` where no `certIssuer` makes a certificate per pod. They come from
  the chart, through the operator's environment, and nothing a profile says changes them,
  so they are copied as they are.
- **A profile's**: `llm.secretRef` and each MCP server's `secretRef`. The plane writes
  profiles and may read no Secret, by design (its role is two resources). Copying whatever a
  profile names would give a plane that is not what it should be, or anyone who can write a
  WorkerProfile, a way to have `troupe-plane-database`, the OIDC client secret or the SCIM
  token copied into a pod that sends its model key to an endpoint of the profile's choosing.
  So a profile-named Secret is copied only when it carries `troupe.dev/worker-secret=true`,
  and, where it is also annotated `troupe.dev/worker-secret-profiles`, only to the profiles
  listed. Labelling a Secret is part of making it, once, not a step per profile, and its
  absence is said with the line.

The source wins: where it exists and may be copied, the worker namespace's Secret of that
name is its copy, whoever made one there first. An upgrade from hand copies is then
nothing: a hand copy of the same data is replaced by the same data. Where the plane's
namespace has none, a Secret of that name already in the worker namespace (External Secrets
Operator's, or a person's) is used as it is and never touched. Where it is in neither,
`SecretMissing` names it and where it was looked for; one in the plane's namespace without
the label is named with `kubectl -n troupe-system label secret <name>
troupe.dev/worker-secret=true`. A copy whose source loses the label is deleted. The console
puts each profile's `SecretMissing` under *Needs attention*.

The operator's ClusterRole gains `get`, `create`, `patch` and `delete` on Secrets, and no
`list` or `watch`: it reads a Secret something names and cannot go looking. That adds no
reach it lacked, since a StatefulSet it makes may mount any Secret of its namespace, and it
is what makes `SecretMissing` true at last: the false alarm B41 reported was the condition
being refused its `get`.

**Not chosen:** a watch on the plane's namespace's Secrets, so a rotation reached the copies
at once. It needs `watch` on Secrets, which across a namespace is a stream of every Secret
there including the plane's own; thirty seconds is less than any rotation waits for its pods.
**Not chosen:** pruning copies by listing Secrets with the operator's marker, as the other
kinds are pruned. It needs `list` on Secrets cluster-wide, since a ClusterRole cannot name
the worker namespaces; the names in the status do the same with `get`.
**Not chosen:** an allowlist of Secret names in the TroupePolicy. It is the cluster admin's
too, but a second place to keep in step with each Secret; the label sits on the Secret it
is about.

## The ingress label: the operator's where the installation names the namespace

Every worker's NetworkPolicy, and the plane's, the GUI's and A2A's, admit HTTP only from a
namespace labelled `troupe.dev/ingress=true`. Helm cannot label a namespace it does not own,
and the operator cannot know which namespace the controller runs in. So:

- **Named** (`operator.ingressNamespace`, `ingress-nginx` in the example values and on kind),
  the operator labels it at every pass with server-side apply, which owns that one label and
  nothing else, after reading that it exists, since an apply would make one that does not.
  `operator.labelIngressNamespace: false` leaves the label to a person.
- **Not named**, it is a precondition: some namespace carries the label and runs a pod.

Either way each profile's `IngressNamespaceMissing` condition holds the answer, with the
`kubectl label namespace` line, and the console's Overview puts it under *Needs attention*
once however many profiles say it (`Troupe.Operator.IngressCheck`). On the profile, because
the plane may read profiles and nothing about namespaces, and a check by the plane would
widen the role of the one internet-facing component; per profile, because it is that
profile's workers that are unreachable.

**Not chosen:** finding the controller's pods by the labels a well-known controller uses.
Each controller labels differently, and a guess that misses says "fine" about a cluster it
does not understand; "a labelled namespace that runs a pod" is weaker and always true when
it says so.

## The grant check meets a narrow role on kind

Decision 934's check (`Troupe.Plane.KMSCheck`) asks OpenBao what the plane's token may do;
the kind plane held the dev server's root token, for which every path answers `root`, so CI
never met a missing grant. The kind values now give the plane no static token: it logs in
as its ServiceAccount under `auth/kubernetes/role/troupe-plane`, which the OpenBao setup Job
makes with the four policies `Troupe.KMS.Policy.plane_grants/1` lists and no other.
`mix troupe.openbao.policy` writes those, and the role's line, into
`dev/kind/openbao-plane.yaml` beside `docs/admin/openbao.md`, from the same list, and the
test that keeps the page current keeps that file current too. The root token stays the
Job's and the cluster suite's. `Troupe.E2E.NoHandStepsTest` takes the erasure policy away,
restarts nothing, sees `admin.overview` name it with the `bao policy write` and role lines,
gives it back and sees it held.

## Git Bash

`scripts/kind-up` and `scripts/remote-up` turn MSYS path conversion off for themselves on
Windows (`MSYS_NO_PATHCONV=1`, `MSYS2_ARG_CONV_EXCL='*'`), as `scripts/kind-upgrade-check`
already did: `docker exec <node> chmod 0755 /kind` was run as `chmod C:/Program Files/Git/kind`.

## Releases before this one

`scripts/remote-up` labels the ingress namespace and copies the dev profile's Secrets by
hand only when it installs a published chart, which is what `scripts/kind-upgrade-check`
installs as the release before this one; on this tree's chart it does neither, so the fresh
install proves the operator does both.

## Proof

- `Troupe.Operator.WorkerSecretsTest`: each Secret copied and marked; only what is named;
  a profile's name refused without the label, with the line; the installation's copied
  without it; the annotation narrowing to profiles; one already in the worker namespace kept
  untouched; one in neither said; a rotation reaching the copy; a copy no longer named, or
  whose source lost the label, deleted, and nothing of anybody else's.
- `Troupe.Operator.IngressCheckTest`: unlabelled, labelled with and without a running pod,
  a named namespace labelled, left alone with labelling off, and not made when it is missing.
- `Troupe.KMS.PolicyTest`: `dev/kind/openbao-plane.yaml` is current and its role carries
  exactly the listed policies.
- The console's overview tests: a missing Secret per profile, the ingress line once.
- On kind (`Troupe.E2E.NoHandStepsTest`, `Troupe.E2E.CredentialsTest`): the dev profile's
  Secrets are the operator's copies, the ingress label is the operator's field, the plane's
  role carries the documented policies and every grant is held, one taken away is named with
  its lines and held again once given back, and an MCP token kept beside the plane and
  labelled reaches the pod; the capacity, extends and upgrade tests no longer copy a Secret.
