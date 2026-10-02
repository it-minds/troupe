# Installing Troupe on a cluster that has nothing on it

For a Kubernetes cluster and nothing else: no CNI that enforces policy, no ingress, no
database, no object store, no key manager, no identity provider. On a laptop,
`scripts/remote-up` does all of this into kind and prints where everything is; it is the
same steps automated for one target, kept working by `mix troupe.e2e`. On a managed
cluster with a cloud's services beside it, [section 6](#6-a-worked-example-on-managed-services)
is a worked example.

## 0. Before the first command

| | why | without it |
| --- | --- | --- |
| Kubernetes ≥ 1.30 | `ValidatingAdmissionPolicy` | the operator still refuses a bad profile; the cluster no longer does |
| `kubectl`, `helm` | everything below | — |
| A CNI that enforces NetworkPolicy | a worker's isolation is a NetworkPolicy | **policies are accepted and enforced by nothing** (kind's default CNI) |
| Cilium, optionally | egress by hostname: a worker reaches its allowlist and nothing else | a worker reaches any public host on 443 and 80; the allowlist is checked at admission, not on the wire; a profile's own endpoint on another port, or given as an address, opens that port or that address; one at a loopback or link-local address is refused, as it is with Cilium |
| An ingress controller | how a client reaches a worker | sessions are created and cannot be attached to from outside |

Label the ingress controller's namespace, or every worker drops its traffic:

```bash
kubectl label namespace ingress-nginx troupe.dev/ingress=true
```

## 1. What Troupe does not run for you

The chart installs none of these, deliberately: each is something an organisation already
has opinions about. `dev/kind/dependencies.yaml` installs a development-grade one of each —
read it as a worked example, not a production install.

- **PostgreSQL**: one database and a role that owns it. A Helm hook Job migrates it.
- **An object store**: one bucket, **with versioning on** — the one requirement here that
  is not a preference, because erasure destroys prior versions.
- **OpenBao** (or Vault): a transit mount for signing, a KV v2 mount, and a Kubernetes
  auth role or a token. A plane with neither fails to sign and says so.
- **An identity provider**: any OIDC provider that issues a group claim and the device
  grant. Troupe assigns no roles of its own; a platform admin is a member of a group you
  name. Requirements in detail: [integrations.md](integrations.md).

Create the Secrets the chart expects before installing ([configuration.md Part D](configuration.md#part-d--secrets-the-chart-expects)).

## 2. CRDs, then the chart

```bash
version=0.7.0     # a release: https://github.com/it-minds/troupe/releases
chart=oci://ghcr.io/it-minds/charts/troupe
helm show crds "$chart" --version "$version" | kubectl apply --server-side -f -
helm upgrade --install troupe "$chart" --version "$version" \
  --namespace troupe-system --create-namespace --values my-values.yaml
```

Every release publishes the chart twice, as `oci://ghcr.io/it-minds/charts/troupe` and as
`troupe-<version>.tgz` on its release page, and either works as `$chart`; so does
`charts/troupe` in a checkout of the release's tag. The chart's image tags default to its
version, and the images it names are public on `ghcr.io/it-minds` (`troupe-plane`,
`troupe-operator`, `troupe-worker`, `troupe-a2a`, `troupe-gui`), so nothing needs a pull
secret. A cluster that pulls through a registry of its own copies them there and sets
each `*.image.repository`, `policy.allowedImageRepositories` and `imagePullSecrets`.

The chart makes `troupe-system` itself unless `createNamespace: false`. Where the namespace
is there before the chart (made for the Secrets of section 1, or for OpenBao), set it
false: Helm does not take over a namespace it did not make, and the install stops, saying
the namespace exists and is not the release's. Either way, uninstalling leaves the
namespace and everything in it ([section 7](#7-uninstalling)).

`WorkerProfile`, `TroupePolicy` and `TeamVolume` go first because Helm does not upgrade CRDs
it installed. Start from `values.small.yaml` or `values.example.yaml`; what you cannot
leave unset:

```yaml
plane:
  host: troupe.example.com
  baseUrl: https://troupe.example.com   # where a client reaches this plane
  platformAdminGroup: <group id>        # whose members administer this
  oidc:
    issuer: https://login.example.com
    clientId: troupe
    deviceUrl: https://login.example.com/device
    tokenUrl: https://login.example.com/token
    secretName: troupe-plane-oidc       # for console sign-in
objectStore:
  endpoint: https://s3.example.com
  bucket: troupe-sessions
bao:
  address: https://bao.example.com
policy:
  workersDomain: workers.example.com    # where a worker pod is reached
  allowedEgress: ["*.anthropic.com", api.openai.com, github.com]
```

The database URL is the `troupe-plane-database` Secret. [../egress-allowlist.md](../egress-allowlist.md)
is generated from what each component declares it dials: read it before narrowing
`allowedEgress`, because a host the code needs and the policy refuses is a tool that fails
the first time somebody uses it.

## 3. Prove it is up

```bash
kubectl -n troupe-system get pods
curl -sS https://troupe.example.com/healthz
curl -sS https://troupe.example.com/.well-known/troupe | jq .plane.build
```

The build names the commit, time and version; if it is not what you deployed, the rollout
has not finished or the tag did not move.

Besides the API, the plane's host serves `/`, the page a person gets when they are handed
the URL, which says what this host is and the ways in; `/docs`, the concepts; `/admin`, the
console; and `/healthz`, for Kubernetes. `plane.appUrl` says where the graphical client is
(the chart's own at `/app` by default; a team with its own client sets `gui.enabled: false`
and points it there), and `plane.cliUrl` where the terminal client is published (empty,
the page says to ask an administrator).

## 4. The first administrator

Sign in at `https://troupe.example.com/admin`. You are a platform admin because you are in
the group `platformAdminGroup` names, so **a wrong group locks everybody out, including
you**. The console checks a group before saving it — how many people would administer the
platform afterwards, and whether you are one — and `TROUPE_BREAKGLASS_TOKEN`, if you set
one, opens `/admin/breakglass` ([roles-and-permissions.md §4](roles-and-permissions.md#4-break-glass)).

## 5. The rest is the console

`Troupe.Plane.ConsoleWalkthroughTest` drives this sequence on every build:

1. **Identity**: check the admin group.
2. **Policy**: save it, and the ceilings every team inherits.
3. **Teams**: turn a provider group into a team.
4. **Profiles**: write a worker profile.
5. **Bundles**: publish what a session on it gets, reading the diff first.
6. **Teams**: grant the profile to the team.
7. **Identity**: a service principal for work nobody starts by hand.
8. **Triggers**: a schedule that fires as it.
9. **Budgets**: which ceiling would refuse, and for whom.

No `kubectl`, environment variable or database write in any of them, and every step is in
the audit trail with a diff. Then create the worker namespace's Secrets (object store, the
model key, pull secrets) and watch `kubectl -n troupe-system get wp -w`.

## 6. A worked example on managed services

`charts/troupe/values.example.yaml` is this page on a managed Kubernetes cluster, with
every value that has to be yours marked `CHANGE ME`. It assumes this shape:

| Need | How | Why |
| --- | --- | --- |
| Kubernetes | a managed cluster, with Cilium as its CNI where that is offered | with Cilium the operator writes FQDN egress rules per profile; without it, egress to a named host is a wide CIDR rule |
| PostgreSQL | the provider's managed PostgreSQL, point-in-time recovery on | the session index, ledger, audit trail and identity mirror |
| Sealed session data | an S3-compatible object store, versioning **on** | erasure needs versioning |
| Worker disks | a block-storage class, `ReadWriteOnce` | one volume per pod |
| Team volumes | a file-storage class, `ReadWriteMany` | the only thing that needs it |
| Images | `ghcr.io/it-minds/troupe-*`, public | a mirror of your own names a pull secret |
| Ingress and TLS | ingress-nginx behind the provider's load balancer, and cert-manager | in the cluster |
| Keys | OpenBao, in the cluster | below |
| Identity | your existing provider | [integrations.md §1](integrations.md#1-identity-provider-oidc) |
| Models | your gateway, or the providers' own hosts | named in `policy.allowedEgress` |

**Two DNS names**, both pointing at the load balancer: the plane's (`troupe.example.com`)
and a wildcard for `*.workers.example.com`, because a client dials each pod directly at
`<ordinal>-<profile>.workers.<domain>`. The hyphen is what lets one wildcard record cover
every profile.

**ingress-nginx** needs longer timeouts and a larger body than its defaults, set in its
chart's values:

```yaml
controller:
  config:
    proxy-read-timeout: "3600"   # a session is a WebSocket, idle while a model thinks
    proxy-send-timeout: "3600"
    proxy-body-size: 16m         # the protocol's frame cap, so the worker refuses, not the proxy
```

Where the load balancer can send PROXY protocol, turn it on at both ends
(`use-proxy-protocol: "true"` here, and the provider's own annotation on the controller's
Service): without it every request arrives from the balancer's address, and the plane's
per-client rate limit becomes one bucket for everybody. Then label the controller's
namespace, as in section 0.

**cert-manager** issues every certificate from one ClusterIssuer, the `letsencrypt` both
`certIssuer` values in the example name:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com     # CHANGE ME
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
```

HTTP-01 needs no API token for whoever hosts the zone, so it works on any DNS host. It
costs one ACME order per pod hostname, against Let's Encrypt's fifty certificates per
registered domain per week; at a size where that matters, a wildcard in
`operator.tlsSecretName`, issued over DNS-01, is the answer.

**OpenBao stays yours.** Troupe needs KV v2 and a transit engine, which a cloud's key
manager rarely is, and OpenBao auto-unseals only through a few cloud KMS APIs or another
transit engine. One replica with Raft storage is enough: there is no quorum to lose, a
restart is a window in which no session can be *opened*, and live sessions keep their
keys in memory. Without a KMS it can use, the seal is Shamir and something has to unseal
it after every restart: a person, or a share kept in a Secret, which protects a stolen
volume and not against a cluster admin. Set `server.enableServiceLinks: false` in its
chart, so the `<SERVICE>_PORT` variables Kubernetes injects cannot collide with its own.
Then the transit key, Kubernetes auth with a reviewer JWT, and the two roles of
[integrations.md §2](integrations.md#2-openbao); `dev/kind/dependencies.yaml` has them as
working commands, in development shape.

**Every worker namespace** the operator creates needs its own copies: the object-store
Secret, the pull secret if there is one, the profile's model key (`llm.secretRef`, key
`api-key`) and `troupe-mcp-<server>` for every bundle MCP server with a `credential_ref`.
External Secrets Operator is how none is forgotten on a new profile.

**Sizing.** Sessions per pod sizes everything: a pod holds a process tree per *active*
session and nothing per dormant one. The example's plane is two replicas at 1 vCPU and
1 GiB each. `values.small.yaml` fits two nodes of about 3 vCPU and 4 GB: the plane, the
operator, OpenBao, ingress-nginx and cert-manager take about a node and a half at their
requests, and 2 GB nodes leave workers `Pending` without saying why.

**Not covered by CI.** The chart runs on kind there, not on a cloud's network, storage or
load balancer. Every worker pod is internet-facing by design, protected by a pod-bound
token, the ACL and the NetworkPolicy; a load-balancer ACL or a VPN in front of `*.workers`
deserves a look before production. The PITR drill (`scripts/pitr-drill`) is a script, not
a schedule.

After the first install, an upgrade is [routine-tasks.md](routine-tasks.md#upgrade).

## 7. Uninstalling

`helm uninstall troupe -n troupe-system` takes away the plane, the operator and the rest of
what the chart rendered, and leaves on purpose:

- **The namespace and everything else in it**: OpenBao, the Secrets, volume claims, the
  `WorkerProfile` resources. The chart marks the namespace `helm.sh/resource-policy: keep`,
  so neither an uninstall nor a GitOps controller's remediation that uninstalls takes the
  rest with it; one made with `createNamespace: false` was never the chart's to delete.
- **The CRDs**, which Helm never deletes, and the `TroupePolicy`, which is also marked keep.
- **The workers**: their namespaces are the operator's, and with the operator gone nothing
  removes them.

To take everything away, [decommission each profile](routine-tasks.md#decommission-a-profile)
while the operator still runs, which removes its namespace, then uninstall, look at what is
left (`kubectl -n troupe-system get all,secrets,pvc`), and `kubectl delete namespace
troupe-system`. The database and the bucket are yours and are not touched.

The keep is in the chart from 0.7.1. An install from an older chart gets it at its first
upgrade, and loses it again if rolled back to a revision from before.
