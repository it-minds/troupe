# Deploying Troupe on Scaleway

Kapsule for the cluster, three Scaleway managed services for state, OpenBao run by you,
and your own identity provider. The same chart runs on kind with `dev/kind/values.yaml`
through `scripts/remote-up`, and CI runs it there; Scaleway itself has not been exercised
by anything in this repository, and the parts marked **unverified** are reasoned rather
than run. The general, provider-neutral version is [admin/installing.md](admin/installing.md).

## What runs where

| Need | How | Why |
| --- | --- | --- |
| Kubernetes | **Kapsule**, Cilium CNI | with Cilium the operator writes FQDN egress rules per profile; without it, egress to a named host is a wide CIDR rule |
| PostgreSQL | **Managed Database for PostgreSQL**, PITR on | the session index, ledger, audit trail and identity mirror |
| Sealed session data | **Object Storage**, versioning **on** | S3-compatible; erasure needs versioning |
| Team volumes | **File Storage** (`scw-sfs`) | the only thing that needs `ReadWriteMany`; the CSI driver is preinstalled |
| Worker disks | **Block Storage** (`scw-bssd`) | one `ReadWriteOnce` volume per pod |
| Images | **Container Registry** | private by default, so name a pull secret |
| Ingress and TLS | ingress-nginx and cert-manager behind a **Load Balancer** | in-cluster |
| Keys | **OpenBao, in-cluster** | below |
| Identity | your existing provider | below |
| Models | your LiteLLM gateway | |

**OpenBao stays yours.** Troupe uses KV v2 for per-session keys and the transit engine to
sign plane tokens; Scaleway's Key Manager and Secret Manager are neither API. Nor can Key
Manager auto-unseal OpenBao, so `deploy/scaleway/openbao.values.yaml` runs one Raft
replica with a single-share Shamir seal kept in a Secret and unsealed by a sidecar; the file
says what that does and does not protect.

**Identity** is a plain OIDC provider with discovery, a JWKS, the **device authorization
grant** (the TUI prints a code and polls, so a provider without it cannot be used as is)
and a groups claim. Entra ID and Google Workspace both qualify; register an app, fill
`plane.oidc.*`, and set `platformAdminGroup` to a real group.

**File Storage** is PAR only (AMS promised), one zone at 99.9 %, and at least 25 GB at
about €0.161/GB/month — roughly €4 per team volume at the floor. A team volume going away
loses no session (session state is in object storage); `publish` and `import` fail while
it is down. Scaleway documents a quirk with `subPath`; the operator mounts team volumes
without one. **Unverified.**

## Order of work

### 1. Cluster and registry

A Kapsule cluster **in PAR** with Cilium, and a Container Registry namespace. A release
promotes its images into the registry CI's secrets name; to build and push by hand:

```sh
TROUPE_REGISTRY=rg.fr-par.scw.cloud/troupe TROUPE_IMAGE_TAG=<version> TROUPE_PUSH=true scripts/build-images
```

### 2. Ingress, DNS and certificates

Install ingress-nginx (`deploy/scaleway/ingress-nginx.values.yaml`, which provisions the
Load Balancer), cert-manager and `deploy/scaleway/cluster-issuer.yaml`, then label the
controller's namespace, or every worker Ingress answers 503:

```sh
kubectl label namespace ingress-nginx troupe.dev/ingress=true
```

Two names matter: `troupe.example.com` for the plane, and `*.workers.example.com`, because
a client dials each pod directly at `<ordinal>-<profile>.workers.<domain>` (the hyphen is
what lets one wildcard record cover every profile). The shipped issuer is HTTP-01, so the
values use `operator.certIssuer: letsencrypt` for one certificate per pod hostname; the
plane's `troupe-plane-tls` is yours to provide, or set `plane.certIssuer`.

### 3. State

A managed PostgreSQL with PITR; one bucket with versioning on; and confirm the `scw-sfs`
StorageClass exists.

### 4. OpenBao

`helm upgrade --install openbao openbao/openbao -n troupe-system --create-namespace
--values deploy/scaleway/openbao.values.yaml`, initialise it, then enable the `transit`
engine with an `ecdsa-p256` key `troupe-session-tokens`, Kubernetes auth with a **reviewer
JWT** (a ServiceAccount bound to `system:auth-delegator`; without one, every login is
`permission denied` with nothing in any log), and the roles `troupe-worker` (audience
`troupe-kms`) and `troupe-plane` with their policies
([admin/roles-and-permissions.md §8](admin/roles-and-permissions.md#8-openbao-policies)).
`dev/kind/dependencies.yaml` has it all as working commands in development shape.

### 5. Secrets

Troupe creates none. In `troupe-system`:

```sh
kubectl -n troupe-system create secret generic troupe-plane-database --from-literal=url='ecto://USER:PASS@HOST:5432/troupe_plane'
kubectl -n troupe-system create secret generic troupe-plane-secret-key-base --from-literal=value="$(openssl rand -base64 64 | tr -d '\n')"
kubectl -n troupe-system create secret generic troupe-object-store --from-literal=access-key-id=… --from-literal=secret-access-key=…
```

plus `troupe-plane-oidc` (`client-secret`) for console sign-in and the registry pull
secret `troupe-registry` (`kubectl create secret docker-registry`). In **every worker
namespace** the operator creates: `troupe-object-store` again, the pull secret again, the
profile's model key (`llm.secretRef`, key `api-key`), and `troupe-mcp-<server>` (key
`token`) for every bundle MCP server with a `credential_ref`. External Secrets Operator is
the way to not forget one on every new profile.

### 6. Install

```sh
kubectl apply -f charts/troupe/crds/
helm upgrade --install troupe charts/troupe -n troupe-system --create-namespace --values my-values.scaleway.yaml
```

from a copy of `charts/troupe/values.scaleway.yaml` with its placeholders filled. The
migration runs as a pre-upgrade hook.

This first install is the only one done by hand: after it, a merged change to `VERSION`
releases and runs `scripts/deploy` against the `production` environment. For that, apply
`deploy/ci-deployer.yaml` to the cluster, turn its account into a kubeconfig with
`scripts/ci-kubeconfig` (a Scaleway kubeconfig shells out to `scw`, which a runner lacks),
and give `production` that kubeconfig as `KUBECONFIG`, the values file as `DEPLOY_VALUES`
and the plane's URL as `PLANE_URL`. A cluster that still runs the old `troupe-gui` chart
needs `helm uninstall troupe-gui -n troupe-system` first: both name their objects
`troupe-gui`.

### 7. First team

Sign in to the console at `/admin` as a member of `platformAdminGroup` — platform admin
comes from the provider group, not from a team, so a fresh plane is administrable — and
follow [admin/installing.md §5](admin/installing.md#5-the-rest-is-the-console).

## Sizing and cost

Sessions per pod is the number that sizes everything: a pod holds a process tree per
*active* session and nothing per dormant one. Storage per GB-month: object ~€0.008 (where
history lives), block ~€0.095 (20 GiB per worker pod by default), file ~€0.161 (25 GB
minimum per team volume). The plane is two replicas at 1 vCPU and 1 GiB each.

## The small release

`charts/troupe/values.small.yaml` is the same deployment turned down: one plane without
distribution, one operator, a policy capping a profile at three pods of 2 vCPU and 4 GiB
with four sessions each, every choice commented. Roughly, per month, from list prices for
`fr-par` (**unverified** against the calculator):

| Piece | Size | Roughly |
| --- | --- | --- |
| Kapsule control plane | shared | free |
| Node pool | 2 × DEV1-M (3 vCPU, 4 GB) | €30–40 |
| Managed PostgreSQL | smallest, PITR on | €15–30 |
| Load Balancer | LB-S | €10 |
| Object Storage | a few GB | under €1 |
| Block Storage | 20 GiB per worker pod | €2 each |
| Container Registry | a few images | under €1 |

About **€60–90 a month** for a plane, an operator and two or three worker pods. Two DEV1-M
nodes is the floor: the plane, operator, OpenBao, ingress-nginx and cert-manager take about
a node and a half at their requests, and 2 GB nodes leave workers `Pending` without saying
why. With one replica the plane rolls by `Recreate`, so an upgrade is a few seconds without
a plane; live sessions do not notice.

## Not ready

- CI runs the chart on kind, not on Kapsule's network, storage or load balancer.
- Every worker pod is internet-facing by design, protected by a pod-bound token, the ACL
  and the NetworkPolicy. An LB ACL or a VPN in front of `*.workers` deserves a look before
  production.
- The PITR drill is a script, not a schedule.

Troubleshooting: [admin/monitoring.md §7](admin/monitoring.md#7-if-something-does-not-work).
