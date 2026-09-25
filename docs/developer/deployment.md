# Deployment, from a developer's side

How a build reaches a cluster. Installing and operating one is the admin track:
[../admin/installing.md](../admin/installing.md), [../admin/configuration.md](../admin/configuration.md),
[../deploying-on-scaleway.md](../deploying-on-scaleway.md).

## 1. Environments

There is no staging. Production is the repository's `production` environment, rolled by
a release.

| Name | What | Values | Brought up by |
|---|---|---|---|
| dev | kind on one machine: single replicas on `emptyDir`, Dex, a static OpenBao token | `dev/kind/values.yaml`, `dev/kind/dependencies.yaml` | `scripts/remote-up` ([local-setup.md §4](local-setup.md#4-a-plane-and-a-worker-on-kind)) |
| production | the chart with a values file of the deployment's own (from `values.small.yaml` or `values.scaleway.yaml`) | the `DEPLOY_VALUES` secret | a first install by hand; then every release |

## 2. A release deploys itself

`scripts/release <version>` opens the pull request that changes `VERSION`; merging it is
the release (Decisions 669, 676). `release.yml` runs the full suite, builds the images at
that version, tags `v<version>`, packages the chart, attaches the native builds, and runs
`scripts/deploy` in the `production` environment. A release candidate (`0.4.0-rc.1`) is
published and deployed as a dry run. Nothing is released by pushing a tag, and nothing is
deployed from a laptop. The workflows are in [../../.github/CI.md](../../.github/CI.md).

`scripts/deploy <chart .tgz or directory> [--dry-run]` is the one implementation of
deploying: CI runs it, `deploy.yml` runs it to roll back to or render a published release,
and a person with the same credentials can run it by hand. It applies the chart's CRDs
server-side, `helm upgrade --wait` (rolling back on failure), waits for the rollouts, and,
with `PLANE_URL` set, checks that `/.well-known/troupe` reports the chart's `appVersion`
(and `EXPECT_COMMIT`). It also prints every pod's running digest: a tag that already
exists with `imagePullPolicy: IfNotPresent` leaves the old image serving while Helm reports
success, so CI never publishes a floating tag. Its inputs: `KUBECONFIG_FILE`, `VALUES`,
`NAMESPACE`, `RELEASE`, `PLANE_URL`, `EXPECT_COMMIT`.

Before the first automated deploy the `production` environment needs `KUBECONFIG` (the
`troupe-deployer` account from `deploy/ci-deployer.yaml`, turned into a kubeconfig by
`scripts/ci-kubeconfig`), `DEPLOY_VALUES` and `PLANE_URL`.

## 3. What a roll does

- **CRDs** are applied before the chart every time; Helm never upgrades them.
- **Migrations** run in the `troupe-plane-migrate` hook Job (`pre-install,pre-upgrade`,
  weight −5, `backoffLimit: 1`), `bin/troupe_plane eval "Troupe.Plane.Release.migrate()"`
  with `TROUPE_PLANE_AUTOSTART=false` and `RELEASE_DISTRIBUTION=none`. A failed Job is kept
  for its logs. Never from application boot: two replicas would both migrate.
- **The plane** rolls by `Recreate` with one replica or without distribution (two
  unclustered planes would both place sessions and reserve budget), otherwise by
  `RollingUpdate` with a PDB. Startup probe 60 s, readiness 5 s, liveness 10 s. The Erlang
  cookie is baked into each image build, so two builds may not cluster during a rolling
  update.
- **Workers** are `OnDelete` StatefulSets: a new image is `UpgradePending` until each pod
  is drained and deleted ([../admin/profiles-and-policy.md §3](../admin/profiles-and-policy.md#3-upgrades-and-drains)).
  Profiles whose image is `release` are rewritten by the upgraded plane.
- A namespace made by an older operator gets its `troupe.dev/workers=true` label at the
  next reconcile; until then its pods cannot reach the control port.

## 4. Rolling back

| Option | What it does |
|---|---|
| `deploy.yml` with an earlier version | rolls that release's chart through `scripts/deploy`; `dry_run` renders it first |
| `helm rollback troupe <revision>` | reverts the release; the hook migrates up again and undoes no migration |
| `Troupe.Plane.Release.rollback(repo, version)` | migrations down to a version; by hand, from a one-off pod shaped like the migrate Job ([../admin/backup-restore.md](../admin/backup-restore.md#a-bad-migration)) |
| the database | the managed provider's PITR, then `mix troupe.index.rebuild` |

Nothing rolls back a CRD change, and removing a CRD removes every object of its kind.

## 5. Checking a deployment

`GET /healthz` (200), `GET /.well-known/troupe` (discovery, protocol version and the
build's commit), `GET /.well-known/jwks.json` (503 means OpenBao is unreachable), a pod's
`/health/ready` (`draining` while drained), `kubectl -n troupe-system get wp`. More in
[../admin/monitoring.md](../admin/monitoring.md).
