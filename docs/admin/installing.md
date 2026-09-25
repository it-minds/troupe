# Installing Troupe on a cluster that has nothing on it

For a Kubernetes cluster and nothing else: no CNI that enforces policy, no ingress, no
database, no object store, no key manager, no identity provider. On a laptop,
`scripts/remote-up` does all of this into kind and prints where everything is; it is the
same steps automated for one target, kept working by `mix troupe.e2e`. The Scaleway
version, with its managed services, is [../deploying-on-scaleway.md](../deploying-on-scaleway.md).

## 0. Before the first command

| | why | without it |
| --- | --- | --- |
| Kubernetes ≥ 1.30 | `ValidatingAdmissionPolicy` | the operator still refuses a bad profile; the cluster no longer does |
| `kubectl`, `helm` | everything below | — |
| A CNI that enforces NetworkPolicy | a worker's isolation is a NetworkPolicy | **policies are accepted and enforced by nothing** (kind's default CNI) |
| Cilium, optionally | egress by hostname: a worker reaches its allowlist and nothing else | a worker reaches any public host on 443 and 80; the allowlist is checked at admission, not on the wire |
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
kubectl apply -f charts/troupe/crds/
helm upgrade --install troupe charts/troupe \
  --namespace troupe-system --create-namespace --values my-values.yaml
```

`WorkerProfile`, `TroupePolicy` and `TeamVolume` go first because Helm does not upgrade CRDs
it installed. Start from `values.small.yaml` or `values.scaleway.yaml`; what you cannot
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
curl -sS https://troupe.example.com/.well-known/troupe | jq .build
```

The build names the commit, time and version; if it is not what you deployed, the rollout
has not finished or the tag did not move.

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
