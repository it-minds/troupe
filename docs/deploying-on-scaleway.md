# Deploying Troupe on Scaleway

Kapsule for the cluster, three Scaleway managed services for state, one thing you run
yourself, and your own identity provider. This is the whole list and the order to do it
in.

Everything here has been exercised on a local kind cluster by `scripts/remote-up`, which
is the same chart with `dev/kind/values.yaml` instead of `values.scaleway.yaml`. What has
*not* been exercised is Scaleway itself: the parts marked **unverified** are ones I have
reasoned about rather than run.

---

## What runs where

| Need | How | Why not otherwise |
| --- | --- | --- |
| Kubernetes | **Kapsule**, Cilium CNI | With Cilium the operator writes real FQDN egress rules per profile. Without it, egress to a named host degrades to a wide CIDR rule — written down in `resources.ex` rather than hidden, but a real loss. |
| PostgreSQL | **Managed Database for PostgreSQL** | The plane's session index, usage ledger, audit trail and identity mirror. You want their PITR: `scripts/pitr-drill` is the restore drill and should become a scheduled job against the real instance. |
| Sealed session data | **Object Storage**, versioning **on** | S3-compatible, which is what `Troupe.ObjectStore` speaks. Versioning is not optional — see below. |
| Team volumes | **File Storage** (`scw-sfs`) | The only thing in Troupe that needs `ReadWriteMany`. Scaleway's CSI driver is preinstalled on Kapsule, so this needs no Rook, no NFS provisioner, no distributed filesystem to operate. |
| Worker disks | **Block Storage** (`scw-bssd`) | One `ReadWriteOnce` PVC per pod, from the StatefulSet template. |
| Images | **Container Registry** | |
| Ingress and TLS | ingress-nginx + cert-manager, behind a **Load Balancer** | Self-managed in-cluster. |
| Key manager | **OpenBao, in-cluster** | The one thing you run. See below. |
| Identity | **your existing IdP** | See below. |
| Models | your LiteLLM gateway | Already yours. |

---

## The three that need a decision

### OpenBao stays yours

Troupe uses two specific things from it: **KV v2** for per-session data keys, and the
**transit** engine to sign plane tokens (ES256, `kid` = RFC 7638 thumbprint). Scaleway's
Key Manager and Secret Manager are neither of those APIs, so moving would mean a second
`Troupe.KMS` adapter and a second `Tokens` signer — real work, for a managed service
holding the keys that protect every session.

Run it in-cluster: Raft storage, three replicas, Kubernetes auth (which is what the plane
and the workers already use), and **auto-unseal via Scaleway Key Manager**. That last part
is what their Key Manager is genuinely good at — sealing the seal key — and it removes the
one operational burden self-hosted Vault-likes are notorious for.

Two policies and two roles, exactly as `Troupe.KMS.Policy` writes them:

- a **worker** creates and reads keys under its granted teams and can delete none, not
  even its own — a pod must not be able to make a session unreadable;
- the **plane** can destroy metadata and read no key at all. Not a deny rule: an absence,
  because OpenBao denies by default and a deny rule invites somebody to "fix" it later by
  narrowing it.

### Identity is almost certainly one you already have

Troupe is a plain OIDC relying party. It needs four things and nothing else: a discovery
document, a JWKS, the **device authorization grant**, and a `groups` claim.

If ITMinds is on Entra ID or Google Workspace, register an app, point `plane.oidc.*` at
it, and set `platformAdminGroup` to a real group. No new service.

**Check the device grant first.** `troupe login` runs in a terminal: it prints a URL and a
code, and polls. There is no redirect URI to come back to, so a provider without the
device flow cannot be used as-is. Entra ID and Google both support it; some smaller IdPs
do not.

The groups claim is what makes a platform admin. Membership is the provider's business and
is never edited in Troupe — that is on the Forbidden list, and `Admin.actor_for/1` reads
identity-provider groups rather than anything Troupe owns.

### Object Storage versioning must be on

`session.erase` removes every version of every object under a session's prefix. A bucket
without versioning does not make that fail — it makes it *vacuous*, which is worse,
because the erasure reports success and the done item that checks it passes. Turn
versioning on when you create the bucket, and confirm it before the first real session.

---

## File Storage, and what it costs

Team volumes are `ReadWriteMany`:

```elixir
# apps/troupe_operator/lib/troupe/operator/resources.ex
defp access_mode(:rw), do: "ReadWriteMany"
defp access_mode(:ro), do: "ReadOnlyMany"
```

Scaleway File Storage supports RWX natively with a preinstalled CSI driver, which is why
this deployment is straightforward rather than a Ceph project. Three things to plan around:

- **PAR only**, with AMS in 2026. It is the only component with a regional restriction, so
  it pins the whole deployment to Paris until then.
- **One zone, 99.9%, marked new.** A team volume going away does not lose a session —
  session state is sealed to object storage, and team volumes are mounted `ro` by default.
  What fails while it is down is `publish` and `import`.
- **25 GB minimum at ~€0.161/GB/month**, about 1.7× block storage and 20× object storage.
  That is roughly €4 per team per month at the floor. Fine at ten teams; set a default size
  and a `TroupePolicy` cap before it is a hundred.

There is a documented quirk about `subPath` with File Storage. The operator mounts team
volumes at `/mnt/teams/<name>` without `subPath`, so it should not bite — but read
Scaleway's page on it before the first team volume rather than after. **Unverified.**

---

## Order of work

### 1. Cluster and registry

Create the Kapsule cluster **in PAR**, with **Cilium** as the CNI. Create a Container
Registry namespace. Build and push:

```sh
TROUPE_REGISTRY=rg.fr-par.scw.cloud/troupe TROUPE_IMAGE_TAG=0.2.0 scripts/build-images
```

`scripts/build-images` builds all five images — the four servers from one Dockerfile, the
GUI from `clients/gui` — and pushes nothing unless told to; it loads into kind. For
Scaleway, push them, or let a release do it: CI promotes the images of every release to
its version in the registry these secrets name.

### 2. Ingress, DNS and certificates

Install ingress-nginx (it will provision a Scaleway Load Balancer) and cert-manager.

Two hostnames matter and one of them is a wildcard:

- `troupe.example.com` — the plane: the admin panel, `/rpc`, and the OIDC discovery
  document clients read.
- `*.workers.example.com` — **one hostname per worker pod**,
  `<ordinal>-<profile>.workers.<domain>`, so `0-dev.workers.example.com`.

The wildcard is not a convenience. A client is handed an endpoint and dials that pod
directly, because the plane is not in the data path of a live session — so every pod needs
a name a client can resolve. Issue the wildcard with **DNS-01**; HTTP-01 cannot do
wildcards. Scaleway DNS has a cert-manager webhook.

The **hyphen** between the ordinal and the profile is what makes one wildcard enough. A
DNS wildcard matches exactly one label, so `*.workers.example.com` covers
`0-dev.workers.example.com` and would not have covered `0.dev.workers.example.com`. With
a dot, every new profile would need its own DNS record and its own certificate before any
of its pods could be reached, and creating a profile in the panel would stop being
self-service. Both places that compose the name say so:
`Troupe.Operator.Names.host/3` and `config/runtime.exs`.

### 3. State

- **Managed PostgreSQL**: one instance, PITR enabled. Note the connection URL.
- **Object Storage**: one bucket, **versioning on**.
- **File Storage**: nothing to create — the CSI driver provisions filesystems from PVCs.
  Confirm `scw-sfs` exists as a StorageClass on the cluster.

### 4. OpenBao

Deploy it with Raft and auto-unseal against Scaleway Key Manager, then enable:

- the `transit` engine with an `ecdsa-p256` key named `troupe-session-tokens`;
- Kubernetes auth, configured with a **reviewer JWT** — a ServiceAccount bound to
  `system:auth-delegator`. Without one, OpenBao tries to review the incoming token using
  the incoming token, which no worker ServiceAccount is allowed to do. This is the single
  most confusing failure in the whole setup: it presents as `permission denied` at login
  with nothing in any log to say why.
- roles `troupe-worker` (audience `troupe-kms`) and `troupe-plane`, with the two policies
  above.

`dev/kind/dependencies.yaml` has all of this as working commands. It is a development
shape — dev mode, a root token — but the engine names, policy paths, role names and
audiences are the real ones and can be copied.

### 5. Secrets

Troupe creates no secrets. Four must exist in `troupe-system` before the chart installs:

| Secret | Key | What |
| --- | --- | --- |
| `troupe-plane-database` | `url` | `ecto://user:pass@host:port/db` from the managed instance |
| `troupe-plane-secret-key-base` | `value` | ≥64 random bytes; signs admin-panel session cookies |
| `troupe-object-store` | `access-key-id`, `secret-access-key` | Scaleway API key with object-storage access |
| `troupe-workers-tls`, `troupe-plane-tls` | — | written by cert-manager, not by you |

And **in every worker namespace** (`troupe-w-<profile>`, which the operator creates):

| Secret | Key | What |
| --- | --- | --- |
| `troupe-object-store` | `access-key-id`, `secret-access-key` | the same credentials; a pod reads and writes sealed segments itself |
| your LLM secret | `api-key` | whatever the profile's `llm.secretRef` names |

**MCP servers** follow a fixed convention rather than a field you fill in. For every
server the channel's config bundle names with a `credential_ref`, create
`troupe-mcp-<server>` with key `token` in each worker namespace whose profile is on
that channel — a bundle server called `jira` means `troupe-mcp-jira`. The operator
injects it as the environment variable the `credential_ref` names, marked optional, so a
Secret that is not there yet does not stop the pod: the profile reports `SecretMissing`
naming it, the server's tools are offered without a credential until it appears, and
nothing in the plane or the panel ever holds the value.

This is where External Secrets Operator earns its keep: the operator creates the namespace,
and ESO puts the secrets in it. Doing it by hand means remembering on every new profile.

### 6. Install

Copy `charts/troupe/values.scaleway.yaml`, fill in the four placeholders, and:

```sh
helm upgrade --install troupe charts/troupe \
  --namespace troupe-system --create-namespace \
  --values values.scaleway.yaml
```

Migrations run as a pre-upgrade hook before the new pods start — not from the
application's own boot, because two replicas starting at once would both migrate and a
failure would look like a plane that would not start.

This first install is the only one done by hand. After it, an upgrade is a release: a
merged change to `VERSION` makes CI promote the images, publish the chart and run
`scripts/deploy` against the repository's `production` environment (Decision 669). For
that, apply `deploy/ci-deployer.yaml` to this cluster, turn its account into a
kubeconfig with `scripts/ci-kubeconfig` — a Scaleway kubeconfig shells out to `scw`, which
a runner does not have — and give the `production` environment that kubeconfig as
`KUBECONFIG`, this values file as `DEPLOY_VALUES`, and the plane's URL as `PLANE_URL`.

**Label the ingress namespace.** A worker's NetworkPolicy admits traffic only from
namespaces carrying `troupe.dev/ingress=true`. That is how "only the ingress may reach a
pod" is said, and labelling whichever namespace runs the controller is the cluster admin's
half of it:

```sh
kubectl label namespace ingress-nginx troupe.dev/ingress=true
```

Without it every worker Ingress answers 503 with a timeout in the nginx log and nothing
anywhere else.

### 7. First profile, first team

The bootstrap has an order to it. A `WorkerProfile` in Kubernetes and a profile row in the
plane are two different things: the operator owns one, the plane owns the other, and in
`direct` mode the plane writes the first when an admin creates the second.

```sh
troupe login https://troupe.example.com
troupe admin team enable <your-idp-group>
troupe admin profile put profile.json
troupe admin team grant <team> <profile>
troupe --remote
```

You can administer from the first login because platform admin comes from an
identity-provider group, not from an enabled team — enabling the first team is itself a
platform-admin action, so the other way round would leave a fresh plane unadministerable.

---

## Sizing and cost

Sizing is driven by one number: **sessions per pod**. A pod holds a process tree per
*active* session and nothing per dormant one — ten thousand dormant sessions cost zero
processes — so capacity is about concurrent work, not accounts.

Storage, per month, at the margin:

- object storage ~€0.008/GB — where session history actually lives, and the cheapest
  thing here by twenty times;
- block storage ~€0.095/GB — 20 GiB per worker pod unless the profile's `storage.size`
  says otherwise, on the cluster's default class unless `storage.storageClassName`
  names one;
- file storage ~€0.161/GB — 25 GB minimum per team volume.

The plane is small: two replicas at 1 vCPU and 1 GiB each. The operator is smaller.

---

## The small release

`charts/troupe/values.small.yaml` is the same deployment with every number turned down:
one plane with distribution off, one operator, a policy that caps a profile at three
pods of 2 vCPU and 4 GiB with four sessions each. Every choice in it has its cost
written beside it. Install it the same way, with that file in place of
`values.scaleway.yaml`.

What it runs on, and roughly what that is per month. These are list prices from memory
for `fr-par`, rounded, and **unverified** against the calculator — check them before
trusting them:

| Piece | Size | Roughly |
| --- | --- | --- |
| Kapsule control plane | the shared offer | free |
| Node pool | 2 × DEV1-M (3 vCPU, 4 GB) or 2 × PLAY2-MICRO-class | €30–40 |
| Managed PostgreSQL | the smallest instance, PITR on | €15–30 |
| Load Balancer | LB-S, in front of ingress-nginx | €10 |
| Object Storage | a few GB of sealed segments | under €1 |
| Block Storage | 20 GiB per worker pod | €2 each |
| Container Registry | three images | under €1 |

Call it **€60–90 a month** for a plane, an operator and two or three worker pods. Two
DEV1-M nodes is the floor, not a suggestion: the plane, the operator, OpenBao,
ingress-nginx and cert-manager take about a node and a half between them at their
requests, and what is left is the workers. A pool of 2 GB instances does not fit, and
fails by leaving worker pods `Pending` rather than by saying so.

What the small release gives up is availability during a plane upgrade. With one
replica the Deployment rolls by Recreate — the chart insists on it, because a rolling
update of unclustered planes briefly runs two of them and both place sessions — so
there are a few seconds without a plane while the new pod starts. Live sessions do not
notice: the plane is not in their data path. A `troupe login` or a panel load during
those seconds fails and is retried.

The change set that made this deployable closed these, in the order they would have
bitten:

- the migration Job had no `+Q`, so it was OOMKilled in a second with an empty log and
  looked like a failed migration;
- a single-replica plane rolled by RollingUpdate, which is two unclustered planes for
  the length of the rollout; the chart now uses Recreate for one replica and refuses
  more than one without distribution;
- the operator had no liveness probe at all, and the plane had no startup grace, so a
  cold start on a shared vCPU could be killed by its own liveness probe;
- nothing restricted ingress to the plane's control port or to the operator; a
  NetworkPolicy now admits HTTP from the ingress namespace, the control port from
  worker namespaces (which the operator labels `troupe.dev/workers=true`) and the
  operator, and Erlang distribution between plane pods only;
- no rate limit on the plane's Ingress, which is the one internet-facing thing that
  talks to the database;
- no way to name a pull secret, and Scaleway's registry is private by default;
- the worker PVC was 20 GiB on the default class with no way to say otherwise;
- CI never ran the plane's suite (it skipped itself without a database) and never built
  an image.

Two things to do by hand after upgrading to it. The `WorkerProfile` CRD gained a
`storage` field, and Helm does not upgrade CRDs, so `kubectl apply -f charts/troupe/crds/`
first. And a worker namespace created by an older operator gets its
`troupe.dev/workers=true` label on the next reconcile, not before — until then its pods
cannot reach the control port, which looks like workers that enrol and then go quiet.
Touching the profile, or waiting for the resync, is the whole fix.

---

## Things that are not ready

Honest list, all of it known:

- **CI runs the images on kind, not on Kapsule.** The `cluster` job brings the chart up
  on kind with all five images and runs the cluster suite, `gui-e2e` runs the GUI against
  a plane built from the same commit, and a release's `deploy` job checks that the plane
  it rolled reports its version and commit. None of that is Scaleway's network, storage
  or load balancer.
- **The operator's liveness probe is an exec of `bin/troupe_operator pid`**, because the
  operator serves no HTTP. It spawns a short-lived BEAM every thirty seconds to ask the
  running node for its pid. It is cheap and it is correct, and it has not been watched
  over a week on a small node.
- **Every worker pod is internet-facing.** By design — a client dials the pod, and the
  plane stays out of the data path — and protected by a pod-audience-bound token, the
  ACL mirror, and the NetworkPolicy. It still deserves a review before production, and an
  LB ACL or a VPN in front of `*.workers` is worth considering.
- **The PITR drill is a script, not a schedule.** `scripts/pitr-drill` proves a restore
  loses no session. It should run against the real instance on a timer.
- **File Storage is new and one-zone.** See above.
- **Nothing here has run on Scaleway.** It has run on kind, end to end, including a real
  OIDC device grant, a session placed by the plane on a worker pod, and a tool call with
  an approval answered over the protocol.

---

## If something does not work

The failures that cost the most time when bringing this up on kind, in the order they
tend to bite:

| Symptom | Cause |
| --- | --- |
| Pod OOMKilled in one second, empty log | The BEAM sizes its port table from `RLIMIT_NOFILE`, which container runtimes set to ~1e9. `+Q` is set by the chart; if you write your own pod spec, set it. |
| Release dies in its config provider | Kubernetes injects `<SERVICE>_PORT=tcp://…`, which collides with `TROUPE_PLANE_CONTROL_PORT`. `enableServiceLinks: false` everywhere. |
| Worker enrols, looks healthy, refuses every client | It has no JWKS. The plane pushes one on enrolment; if the push failed the plane logs it as an error. |
| `permission denied` logging into OpenBao | No reviewer JWT on the Kubernetes auth mount. |
| Worker Ingress answers 503 | The ingress namespace is missing `troupe.dev/ingress=true`. |
| `the pod did not accept the session`, signer crash on `nil` | Object-store credentials are missing from the *worker* namespace. |
| Sessions placed twice, budgets double-counted | `plane.replicas: 2` with `distribution: none`. The replicas are not clustered, so the `:global` singletons exist once per replica. The chart now refuses this combination at render time. |
| Workers enrol, then go quiet; the plane never hears from them again | The worker namespace lacks `troupe.dev/workers=true`, so the plane's NetworkPolicy drops its control connections. The operator labels namespaces it creates; one made by an older operator gets the label on its next reconcile. |
| `429` from the plane behind one office address | `plane.ingress.rateLimit` is per client IP. Raise `connections` first; every open panel tab is one. |
| Image pull fails with `unauthorized` in a worker namespace | The pull secret named in `imagePullSecrets` exists in `troupe-system` but not in `troupe-w-<profile>`. Troupe creates no secrets; ESO or a hand does. |
