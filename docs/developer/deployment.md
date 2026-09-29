# Deployment, from a developer's side

How a build reaches a cluster. Installing and operating one is the admin track:
[../admin/installing.md](../admin/installing.md), [../admin/configuration.md](../admin/configuration.md),
[../admin/routine-tasks.md](../admin/routine-tasks.md#upgrade).

## 1. Environments

This repository deploys nothing and holds no credential for any cluster. It has one
environment of its own, for development; a real deployment lives in a repository of its
own, which pins a release and keeps its values (Decision 734).

| Name | What | Values | Brought up by |
|---|---|---|---|
| dev | kind on one machine: single replicas on `emptyDir`, Dex, a static OpenBao token | `dev/kind/values.yaml`, `dev/kind/dependencies.yaml` | `scripts/remote-up` ([local-setup.md §4](local-setup.md#4-a-plane-and-a-worker-on-kind)) |
| a deployment | the published chart and images at one release, with values of its own (from `values.small.yaml` or `values.example.yaml`) | its own repository | whatever that repository runs, or [routine-tasks.md](../admin/routine-tasks.md#upgrade) by hand |

## 2. A release publishes, and stops there

`scripts/release <version>` opens the pull request that changes `VERSION`; merging it is
the release (Decisions 669, 676). `release.yml` runs the full suite, builds the images at
that version and pushes them to `ghcr.io`, tags `v<version>`, publishes the chart there
and on the release page, and attaches the native builds (735). A deployment picks the
release up from what was published. Nothing is released by pushing a tag. The workflows
are in [../../.github/CI.md](../../.github/CI.md).

Rolling a release, by whatever does it, is: the chart's CRDs applied server-side (Helm
never upgrades them), `helm upgrade --wait` rolling back on failure, the rollouts waited
for, and `/.well-known/troupe` checked for the release's version and commit. Every pod's
running digest is worth reading too: a tag that already exists with `imagePullPolicy:
IfNotPresent` leaves the old image serving while Helm reports success, so CI never
publishes a floating tag. The commands are in
[routine-tasks.md](../admin/routine-tasks.md#upgrade).

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
  has been drained by the plane, once it holds no active session, and replaced by the
  operator, one at a time ([../admin/profiles-and-policy.md §3](../admin/profiles-and-policy.md#3-upgrades-and-drains)).
  A cluster whose `WorkerProfile` CRD predates `status.podsBehind` drops it, and the roll
  stays manual until the CRDs are applied.
  Profiles whose image is `release` are rewritten by the upgraded plane.
- A namespace made by an older operator gets its `troupe.dev/workers=true` label at the
  next reconcile; until then its pods cannot reach the control port.

## 4. Rolling back

| Option | What it does |
|---|---|
| the deployment pinned to an earlier release | rolls that release's chart the same way as a new one |
| `helm rollback troupe <revision>` | reverts the release; the hook migrates up again and undoes no migration |
| `Troupe.Plane.Release.rollback(repo, version)` | migrations down to a version; by hand, from a one-off pod shaped like the migrate Job ([../admin/backup-restore.md](../admin/backup-restore.md#a-bad-migration)) |
| the database | the managed provider's PITR, then `mix troupe.index.rebuild` |

Nothing rolls back a CRD change, and removing a CRD removes every object of its kind.

## 5. Checking a deployment

`GET /healthz` (200), `GET /.well-known/troupe` (discovery, protocol version and the
build's commit), `GET /.well-known/jwks.json` (503 means OpenBao is unreachable), a pod's
`/health/ready` (`draining` while drained), `kubectl -n troupe-system get wp`. More in
[../admin/monitoring.md](../admin/monitoring.md).
