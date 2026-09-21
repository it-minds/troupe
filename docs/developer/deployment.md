# Deployment, from a developer's side

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).

> **2026-09-21:** production is deployed by CI now. A merged change to `VERSION` cuts a
> release, and the release's `deploy` job rolls it with [`scripts/deploy`](../../scripts/deploy)
> (Decision 669; [ci-cd.md](ci-cd.md) §3). The procedure below is what that script does,
> and what a first install still does by hand.

How a build reaches a cluster. Values and their meanings are in
[../admin/configuration.md](../admin/configuration.md); OpenBao, the identity provider
and the object store are set up per [../admin/integrations.md](../admin/integrations.md);
day-to-day operation is in [../admin/routine-tasks.md](../admin/routine-tasks.md). This
document covers the mechanics only.

## 1. What "staging" and "production" mean here

There is no staging environment. Production is the `production` environment of the
repository, which the `deploy` job rolls when a release is cut ([ci-cd.md](ci-cd.md) §3).
What exists:

| Name used here | What it is | Values | Brought up by |
|---|---|---|---|
| dev | a kind cluster on one machine, single replicas on `emptyDir`, Dex as the IdP, static OpenBao token | `dev/kind/values.yaml` + `dev/kind/dependencies.yaml` | `scripts/remote-up` |
| prod (small) | one plane with distribution off, one operator, the GUI, a policy capped at three pods | `charts/troupe/values.small.yaml` | the first install by hand; then `scripts/deploy`, from the `deploy` job on every release |
| prod | two clustered plane replicas, otherwise the same | `charts/troupe/values.scaleway.yaml` | the same |

Whether a live deployment exists, and on which values, is [../AUDIT.md](../AUDIT.md) open
question 1; everything about it is under gitignored `.local/` (`.gitignore:10-13`).

## 2. The pieces

### Images

CI's `images` job pushes all five as `sha-<7>` on every push to `main`, and a release
adds the version tag to those same images rather than building new ones
([ci-cd.md](ci-cd.md) §3). By hand, for a cluster CI does not deploy:

```bash
TROUPE_REGISTRY=rg.fr-par.scw.cloud/troupe TROUPE_IMAGE_TAG=0.2.0 TROUPE_PUSH=true scripts/build-images
```

Without `TROUPE_PUSH=true` the script loads into kind instead (`scripts/build-images:34-40`).
The chart uses `image.tag | default .Chart.AppVersion`, so an empty tag means `0.2.0`
(`charts/troupe/templates/plane-deployment.yaml:76,164`, `charts/troupe/Chart.yaml`).

### CRDs

Helm installs `charts/troupe/crds/` once and "never upgrades or deletes" them
(`charts/troupe/values.yaml:5-9`, `scripts/remote-up:135-138`). Every change to a CRD
is therefore applied by hand, before the chart:

```bash
kubectl apply -f charts/troupe/crds/
```

Three CRDs: `workerprofile.yaml`, `teamvolume.yaml`, `troupepolicy.yaml`. The default
`TroupePolicy` is an ordinary template with `helm.sh/resource-policy: keep`
(`charts/troupe/templates/policy-default.yaml:1-11`), so uninstalling the release
leaves it.

### The chart

```bash
helm upgrade --install troupe charts/troupe --namespace troupe-system --create-namespace --values <values file>
```

The chart also renders the `troupe-system` Namespace itself
(`charts/troupe/templates/namespace.yaml`). `--create-namespace` is what
`docs/deploying-on-scaleway.md:206-208` and both Scaleway values files' headers show
(`values.small.yaml:9-11`, `values.scaleway.yaml:4-6`); `scripts/remote-up:90,143-146`
creates the namespace with `kubectl` first and omits the flag.

Render-time refusal: `plane.replicas > 1` with `plane.distribution != "name"` fails the
template with the message at `charts/troupe/templates/_helpers.tpl:31-35`.

### Migrations

A Helm hook Job, `troupe-plane-migrate` (`charts/troupe/templates/plane-deployment.yaml:35-118`):

| Property | Value | Lines |
|---|---|---|
| `helm.sh/hook` | `pre-install,pre-upgrade` | `:45` |
| `helm.sh/hook-weight` | `-5` | `:46` |
| `helm.sh/hook-delete-policy` | `before-hook-creation,hook-succeeded` — a failed Job is kept because "the logs are the only thing that says what went wrong" | `:47-49` |
| `backoffLimit` | `1`; `restartPolicy: Never` | `:51,56` |
| command | `["/app/bin/troupe_plane", "eval", "Troupe.Plane.Release.migrate()"]` | `:78` |
| env | `ERL_FLAGS=+Q <plane.maxPorts>` (without it the Job "is OOMKilled in a second with an empty log"); `DATABASE_URL` from `plane.database.secretName`/`secretKey`; `TROUPE_PLANE_AUTOSTART=false`; `RELEASE_DISTRIBUTION=none` | `:79-97` |
| identity | `serviceAccountName: troupe-plane`, uid 1000, `enableServiceLinks: false`, the same `imagePullSecrets` and the projected `bao-token` volume as the plane | `:57-73,103-118` |

`Troupe.Plane.Release.migrate/0` runs `Ecto.Migrator.run(repo, :up, all: true)` for every
repo in `:ecto_repos` (`apps/troupe_plane/lib/troupe/plane/release.ex:17-25`). It is
"deliberately not run from the application's `start/2`" because "two replicas starting
at once would both migrate" (`:10-13`). `config/runtime.exs:139-143` configures the
database whenever `DATABASE_URL` is set, outside the autostart gate, precisely so this
Job can reach the repo while serving nothing.

### Rollout behaviour

| Workload | Strategy | Notes | Lines |
|---|---|---|---|
| `troupe-plane` Deployment | `Recreate` when `plane.replicas == 1` or `plane.distribution != "name"`; otherwise the Kubernetes default `RollingUpdate` | "two unclustered planes are two planes: both place sessions, both reserve budget"; the cost is "a few seconds without a plane" during which live sessions carry on and workers reconnect | `charts/troupe/templates/plane-deployment.yaml:131-138` |
| `troupe-plane` | `revisionHistoryLimit: 3` | "enough to roll back through" | `:128-130` |
| `troupe-plane` | PodDisruptionBudget `minAvailable: 1` only when `replicas > 1` | | `:378-393` |
| `troupe-plane` | startup probe `GET /.well-known/troupe` every 2 s, 30 failures (60 s grace); readiness every 5 s; liveness every 10 s | | `:343-357` |
| `troupe-operator` Deployment | default `RollingUpdate`; `revisionHistoryLimit: 3`; liveness `exec /app/bin/troupe_operator pid` every 30 s after 30 s | more than one replica is allowed; a `Lease` elects the leader | `charts/troupe/templates/operator-deployment.yaml:8-12,110-121` |
| `troupe-a2a` Deployment | default `RollingUpdate`; `revisionHistoryLimit: 3`; probes on `/healthz` | off by default (`a2a.enabled: false`) | `charts/troupe/templates/a2a-deployment.yaml:37-38,101-107` |
| worker StatefulSets | `updateStrategy: OnDelete`; the operator "never deletes a pod" and reports `UpgradePending` | who restarts a drained pod is not answered by code ([../AUDIT.md](../AUDIT.md) §3.13) | `apps/troupe_operator/lib/troupe/operator/resources.ex:450` |

With `plane.distribution: name`, `RELEASE_NODE` is `troupe-plane@$(POD_IP)`, the
distribution port is pinned to `plane.distPort` (9100) and `TROUPE_PLANE_SELECTOR` is
`app.kubernetes.io/component=plane,app.kubernetes.io/instance=<release>`
(`plane-deployment.yaml:201-206,263-276`; `config/runtime.exs:293-309`). The Erlang
cookie "comes baked into the release" (`plane-deployment.yaml:265-266`); `mix release`
generates one per build and no `rel/` overlay pins it, so two image builds may not
cluster with each other during a rolling update ([../AUDIT.md](../AUDIT.md) §3.15).

## 3. The kind flow (dev)

The whole flow is `scripts/remote-up`, step by step in [local-setup.md](local-setup.md) §4.
Condensed:

1. `scripts/kind-up` — cluster `troupe-dev`, host ports 30080/30443.
2. ingress-nginx `controller-v1.14.1`; label `ingress-nginx` with `troupe.dev/ingress=true`.
3. `scripts/build-images` — four `:dev` images loaded into kind (skip with `TROUPE_SKIP_BUILD=1`).
4. `kubectl apply -f dev/kind/dependencies.yaml`; `llm-credentials` from `ITM_LLM_GW_KEY`; CoreDNS rewrite for `dex.localtest.me`.
5. `kubectl apply -f charts/troupe/crds/`.
6. `helm upgrade --install troupe charts/troupe --namespace troupe-system --values dev/kind/values.yaml --wait --timeout 5m`, then `kubectl rollout restart deployment/troupe-plane deployment/troupe-operator`.
7. A `WorkerProfile` named `dev`; secrets `llm-credentials` and `troupe-object-store` created in `troupe-w-dev`.
8. `troupe login http://plane.localtest.me:30080`.

To pick up a code change: rebuild and rerun the script, or run steps 3 and 6 by hand.
The rollout restart is not optional after a rebuild under the same tag
(`scripts/remote-up:148-153`). NetworkPolicies are rendered (`networkPolicy.enabled: true`
is the default and `dev/kind/values.yaml` does not change it) but kind's default CNI
does not enforce them, "and silently" (`charts/troupe/values.yaml:18-23`;
[../AUDIT.md](../AUDIT.md) open question 16).

## 4. The Scaleway flow (prod)

From `docs/deploying-on-scaleway.md:108-243` and the files under `deploy/scaleway/`,
in the document's order. Cluster-side prerequisites and their values are the admin
track's; this is the sequence a developer runs to put a build on it.

1. Kapsule cluster in `fr-par` with Cilium; a Container Registry namespace
   (`docs/deploying-on-scaleway.md:110-113`). Push the five images:
   `TROUPE_REGISTRY=rg.fr-par.scw.cloud/troupe TROUPE_IMAGE_TAG=<tag> TROUPE_PUSH=true scripts/build-images`,
   or let the `images` job push with the registry secrets set ([ci-cd.md](ci-cd.md) §2).
2. ingress-nginx: `helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace --values deploy/scaleway/ingress-nginx.values.yaml`
   (`deploy/scaleway/ingress-nginx.values.yaml:3-5`), then
   `kubectl label namespace ingress-nginx troupe.dev/ingress=true` (`:37-45`;
   `docs/deploying-on-scaleway.md:215-225`). cert-manager, then
   `kubectl apply -f deploy/scaleway/cluster-issuer.yaml` (HTTP-01, issuer `letsencrypt`).
   Discrepancy: `docs/deploying-on-scaleway.md:127-137` describes a DNS-01 wildcard for
   `*.workers.<domain>`; both values files set `operator.certIssuer: letsencrypt`
   (per-pod HTTP-01) and the issuer file says why a wildcard is not possible on this DNS
   host (`cluster-issuer.yaml:5-16`). Nothing in the repository issues `troupe-plane-tls`
   (`plane.certIssuer: ""`, `plane.tlsSecretName: troupe-plane-tls` in both files);
   [../AUDIT.md](../AUDIT.md) open question 5.
3. Managed PostgreSQL with PITR, an Object Storage bucket with versioning on, confirm
   `scw-sfs` exists as a StorageClass (`docs/deploying-on-scaleway.md:147-152`).
4. OpenBao: `helm upgrade --install openbao openbao/openbao --namespace troupe-system --values deploy/scaleway/openbao.values.yaml`
   (`deploy/scaleway/openbao.values.yaml:3-5`), then the transit key, Kubernetes auth
   with a reviewer JWT, the two policies and two roles — the commands in
   `dev/kind/dependencies.yaml:231-274` are "the real ones and can be copied"
   (`docs/deploying-on-scaleway.md:154-169`). See [../admin/integrations.md](../admin/integrations.md).
5. Secrets in `troupe-system`: `troupe-plane-database` (`url`), `troupe-plane-secret-key-base`
   (`value`), `troupe-object-store` (`access-key-id`, `secret-access-key`); and in every
   `troupe-w-<profile>`: `troupe-object-store` and the profile's LLM secret
   (`docs/deploying-on-scaleway.md:171-199`). Troupe creates none of them.
6. `kubectl apply -f charts/troupe/crds/`, then
   `helm upgrade --install troupe charts/troupe --namespace troupe-system --create-namespace --values <your copy of values.small.yaml or values.scaleway.yaml>`
   (`docs/deploying-on-scaleway.md:201-209`; the `CHANGE ME` placeholders are the
   registry, the plane host and base URL, the OIDC issuer, the bucket, and the workers
   domain).
7. Bootstrap: `troupe login https://<plane host>`, `troupe admin team enable <idp group>`,
   `troupe admin profile put profile.json`, `troupe admin team grant <team> <profile>`
   (`docs/deploying-on-scaleway.md:227-243`). Caveat: with `provisioningMode: direct`,
   `admin.profile.put` reports `state: :not_applied, reason: :no_cluster` unless
   `:troupe_plane, :k8s_conn` is set somewhere, and nothing in the repository sets it
   ([../AUDIT.md](../AUDIT.md) §3.1, open question 3). `scripts/remote-up` sidesteps
   this by applying the `WorkerProfile` with `kubectl` (`:158-188`).

Upgrading an existing installation is a release: `scripts/release <version>`, merge, and
the `deploy` job runs `scripts/deploy` with the release's chart — the CRDs server-side,
`helm upgrade --wait` rolling back on failure, `rollout status`, and a check that
`/.well-known/troupe` reports the new version and commit. Before the first one, the
`production` environment needs its `KUBECONFIG` (from `deploy/ci-deployer.yaml` and
`scripts/ci-kubeconfig`), `DEPLOY_VALUES` and `PLANE_URL`. And on a cluster that ran the
GUI from its old chart, `helm uninstall troupe-gui -n troupe-system` first: that release
owns a Deployment, Service and Ingress named `troupe-gui`, the names `charts/troupe` now
uses, and Helm will not adopt objects another release owns, so the first deploy with
`gui.enabled` fails until it is gone. The second manual step below still applies.

## 5. Post-upgrade manual steps

From `docs/deploying-on-scaleway.md:322-327`, "Two things to do by hand after upgrading":

1. `kubectl apply -f charts/troupe/crds/` first — the `WorkerProfile` CRD gained a
   `storage` field and Helm does not upgrade CRDs. `scripts/deploy` does this on every
   deploy now, from the chart it is rolling.
2. A worker namespace created by an older operator gets its `troupe.dev/workers=true`
   label on the next reconcile, not before; until then its pods cannot reach the plane's
   control port (the plane's NetworkPolicy admits the control port from namespaces with
   that label, `charts/troupe/templates/network-policy.yaml:36-40`). "Touching the
   profile, or waiting for the resync, is the whole fix."

Also after any image rebuild under an unchanged tag: `kubectl rollout restart` of the
affected Deployments (`scripts/remote-up:148-153`). Worker StatefulSets are `OnDelete`;
the operator reports `UpgradePending` and deletes nothing.

## 6. Rollback

| Option | What it does | Exists where |
|---|---|---|
| The `deploy` workflow with an earlier version | rolls that release's published chart through `scripts/deploy`, in the `production` environment, one roll at a time; a dry run renders it first | `.github/workflows/deploy.yml` |
| `helm rollback troupe <revision>` | reverts the release to a previous revision; the pre-upgrade hook Job runs `migrate()` again, which is `:up, all: true` and does not undo migrations | Helm; `revisionHistoryLimit: 3` keeps three old ReplicaSets per Deployment (`plane-deployment.yaml:128-130`, `operator-deployment.yaml:12`, `a2a-deployment.yaml:38`) |
| `Troupe.Plane.Release.rollback(repo, version)` | `Ecto.Migrator.run(repo, :down, to: version)`; "For an operator with a problem, not for a deploy" | `apps/troupe_plane/lib/troupe/plane/release.ex:27-32`. Nothing in the chart or scripts invokes it; run it by hand as `kubectl exec <plane pod> -- /app/bin/troupe_plane eval 'Troupe.Plane.Release.rollback(Troupe.Plane.Repo, <version>)'` with `TROUPE_PLANE_AUTOSTART=false` semantics in mind (the running pod has it `true`; a one-off Job modelled on the migrate hook is the shape that matches) |
| Re-point the image tag | `helm upgrade` with the previous `image.tag`; equivalent to a rollback without Helm's revision bookkeeping | values |
| Database | the managed provider's PITR; `scripts/pitr-drill` is the rehearsal and `mix troupe.index.rebuild` closes the gap between a restored database and object storage | [../admin/backup-restore.md](../admin/backup-restore.md) |

Nothing rolls back a CRD change; removing a CRD removes every object of that kind
(`charts/troupe/values.yaml:7-9`). Triggers, principals and runs are not rebuildable
from object storage ([../AUDIT.md](../AUDIT.md) §3.12).

## 7. Checking a deployment from the outside

| Check | Command or URL | Expectation |
|---|---|---|
| plane liveness | `GET https://<host>/healthz` | 200 |
| plane discovery | `GET https://<host>/.well-known/troupe` | JSON with `issuer`, `client_id`, endpoints, `plane.rpc`, `plane.jwks`, `protocol_version` (also the probe path, `plane-deployment.yaml:353-362`) |
| plane keys | `GET https://<host>/.well-known/jwks.json` | 200; 503 means OpenBao is unreachable ([../AUDIT.md](../AUDIT.md) §1.2) |
| a worker pod | `GET https://<ordinal>-<profile>.<workersDomain>/health/ready` | 200 `ready`; 503 `draining` while draining (`apps/troupe_gateway/lib/troupe/gateway/web.ex:29-35`) |
| the profile | `kubectl get workerprofile -n troupe-system` | printer columns Replicas, Ready, Violation, Age; conditions `Ready`, `PolicyViolation`, `SecretMissing`, `UpgradePending` |
| a2a | `GET https://<a2a host>/healthz` and `/a2a/<profile>/.well-known/agent-card.json` | when `a2a.enabled: true` |

See [../admin/monitoring.md](../admin/monitoring.md) for what the platform does and does
not expose beyond these.
