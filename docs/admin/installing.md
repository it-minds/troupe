# Installing Troupe on a cluster that has nothing on it

This is the page to follow if you have a Kubernetes cluster and nothing else. It assumes
no CNI that enforces policy, no ingress controller, no database, no object store, no key
manager and no identity provider — because that is what "a cluster" usually means, and a
page that assumed otherwise would be a page that works on the author's cluster.

Everything here is a command you can run. Where a step is somebody else's product to
install, it says so and says what Troupe does without it, because "install cert-manager"
is not an instruction anybody can act on at three in the afternoon.

> **The short version.** On a laptop, `scripts/remote-up` does all of this into kind and
> prints where everything is. Read that script alongside this page: it is the same nine
> steps, automated for one target, and it is kept working by `mix troupe.e2e`.

---

## 0. What you need before the first command

| | why | what happens without it |
| --- | --- | --- |
| Kubernetes 1.30 or newer | `ValidatingAdmissionPolicy` is GA from 1.30 | the operator still refuses a bad profile and marks `PolicyViolation`; the *cluster* stops enforcing it |
| `kubectl`, `helm` | everything below | — |
| A CNI that enforces NetworkPolicy | a worker's isolation is a NetworkPolicy | **policies are accepted and enforced by nothing.** kind's default CNI is one of these |
| Cilium, optionally | egress by hostname rather than by CIDR | `troupePolicy.ciliumAvailable: false`, and egress to named hosts is a CIDR rule and a documented gap |
| An ingress controller | how a client reaches a worker | sessions are created and cannot be attached to from outside the cluster |

The namespace running your ingress controller must carry the label
`troupe.dev/ingress=true`. A worker pod admits traffic from namespaces with that label and
from nowhere else, so an ingress without it is an ingress whose traffic is dropped:

```bash
kubectl label namespace ingress-nginx troupe.dev/ingress=true
```

---

## 1. The four things Troupe does not run for you

Troupe keeps its index in PostgreSQL, its sessions' objects in an S3-compatible bucket, its
keys in OpenBao, and its people in an identity provider. None of them is installed by the
chart, deliberately: each is something an organisation already has opinions about, and a
chart that installed its own would be a chart that quietly became the owner of your data.

`dev/kind/dependencies.yaml` installs a development-grade one of each into kind — single
replicas, `emptyDir`, a static root token, Dex as the provider. Read it as a worked example
of what the plane needs, and not as a production install.

**PostgreSQL.** One database, and a role that owns it. The plane migrates on start.

**An object store.** One bucket, **with versioning on**. Erasure destroys prior versions
under a prefix, and a bucket without versioning cannot be erased from correctly — this is
the one requirement here that is not a preference.

**OpenBao (or Vault).** A transit mount for signing, and a KV v2 mount for people's own
credentials. The plane needs a token or a Kubernetes auth role; it has no default, and a
plane with neither fails to sign and says so rather than trying a development root token
against your cluster.

**An identity provider.** Any OIDC provider that issues a group claim. Troupe assigns no
roles of its own: a platform admin is a member of a group you name, because an admin role
Troupe could grant would be a way to escalate inside Troupe.

---

## 2. The custom resource definitions

```bash
kubectl apply -f charts/troupe/crds/
```

Three of them: `WorkerProfile`, `TroupePolicy`, `TeamVolume`. Applied before the chart
because Helm does not upgrade CRDs it installed, and separating them is what lets you
upgrade the chart without touching them.

---

## 3. The chart

```bash
helm upgrade --install troupe charts/troupe \
  --namespace troupe-system --create-namespace \
  --values my-values.yaml
```

The values you cannot leave unset, and what each one is:

```yaml
plane:
  baseUrl: https://troupe.example.com    # where a client reaches this plane
  oidc:
    issuer: https://login.example.com    # your provider
    clientId: troupe
  platformAdminGroup: platform-admins    # the group whose members administer this
  database:
    url: ecto://user:pass@host/troupe    # or `existingSecret`
  objectStore:
    endpoint: https://s3.example.com
    bucket: troupe-sessions
  bao:
    address: https://bao.example.com

troupePolicy:
  workersDomain: workers.example.com     # where a worker pod is reached
  allowedEgress:                         # see docs/egress-allowlist.md
    - "*.anthropic.com"
    - api.openai.com
    - github.com
```

`docs/egress-allowlist.md` is generated from what each component declares it dials. Read it
before narrowing `allowedEgress`: a host the code has and the policy refuses is a tool that
fails the first time somebody uses it.

---

## 4. Prove it is up before you tell anybody

```bash
kubectl -n troupe-system get pods
curl -sS https://troupe.example.com/healthz
curl -sS https://troupe.example.com/.well-known/troupe | jq
```

The last one answers with the plane's name, the protocol version, **and the build**:

```json
{ "build": { "commit": "a8ba29e", "built_at": "2026-09-17T18:02:11Z", "version": "0.2.0" } }
```

The console's footer says the same thing. If the commit is not the one you deployed, the
rollout has not finished or the image tag did not move — and the two look identical from
the outside until you read this.

---

## 5. The first administrator, and the door if you get it wrong

Sign in at `https://troupe.example.com/admin`. You are a platform admin because you are in
the group named by `platformAdminGroup` — which means **a wrong group locks everybody out,
including you.**

Two things make that recoverable:

* The console's **Identity** screen checks a group before you save it, and the check asks
  the question that matters: how many people would administer this platform afterwards, and
  are you one of them. Saving is gated on it.
* `TROUPE_BREAKGLASS_TOKEN`, if you set one, opens `/admin/breakglass`. It is a door you
  decide to have; absent, the route answers 404 and the deployment says nothing about it.
  A break-glass session is marked on every page and is in the audit trail.

---

## 6. Configure the rest from the console

Everything after this is a screen. `Troupe.Plane.ConsoleWalkthroughTest` drives exactly this
sequence on every build, which is what makes this section a claim rather than a hope:

1. **Identity** — check the admin group.
2. **Policy** — save it, and set the ceilings every team inherits.
3. **Teams** — turn a provider group into a team.
4. **Profiles** — write a worker profile.
5. **Bundles** — publish what a session on it gets; read the diff first.
6. **Teams** — grant the profile to the team.
7. **Identity** — a service principal for work nobody starts by hand.
8. **Triggers** — a schedule that fires as it.
9. **Budgets** — confirm which ceiling would refuse, and for whom.

No `kubectl`, no environment variable and no database write in any of them, and every step
is in the audit trail with a diff keyed by the path it changed.

---

## What to read next

* [configuration.md](configuration.md) — every value, what it does, and when it takes effect.
* [integrations.md](integrations.md) — the four dependencies, in detail.
* [single-machine.md](single-machine.md) — a worker on a machine you already have, without
  a cluster underneath it.
* [../egress-allowlist.md](../egress-allowlist.md) — what this product dials, generated.
* [backup-restore.md](backup-restore.md) — and the one thing a restore cannot undo.
