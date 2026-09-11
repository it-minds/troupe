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

`scripts/build-images` builds all three server images from one Dockerfile and pushes
nothing — it loads into kind. For Scaleway, push them; the client binary is not built here,
because it is a Burrito executable for a laptop and CI builds it per target.

### 2. Ingress, DNS and certificates

Install ingress-nginx (it will provision a Scaleway Load Balancer) and cert-manager.

Two hostnames matter and one of them is a wildcard:

- `troupe.example.com` — the plane: the admin panel, `/rpc`, and the OIDC discovery
  document clients read.
- `*.workers.example.com` — **one hostname per worker pod**, `<ordinal>.<profile>.workers…`.

The wildcard is not a convenience. A client is handed an endpoint and dials that pod
directly, because the plane is not in the data path of a live session — so every pod needs
a name a client can resolve. Issue the wildcard with **DNS-01**; HTTP-01 cannot do
wildcards. Scaleway DNS has a cert-manager webhook.

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
- block storage ~€0.095/GB — 20 GiB per worker pod, currently hard-coded in the
  StatefulSet template;
- file storage ~€0.161/GB — 25 GB minimum per team volume.

The plane is small: two replicas at 1 vCPU and 1 GiB each. The operator is smaller.

---

## Things that are not ready

Honest list, all of it known:

- **CI has never run.** The workflow is written and there has been no remote to run it on.
  Everything in it that can run locally does: `mix check`, boundaries, schema diff, the
  Python conformance client, and a Burrito build with a smoke test.
- **Worker PVC size is fixed at 20 GiB** and is not a profile field. Changing it is small
  but it is a change.
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
| Sessions placed twice, budgets double-counted | `plane.replicas: 2` with `distribution: none`. The replicas are not clustered, so the `:global` singletons exist once per replica. |
