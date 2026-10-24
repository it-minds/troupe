# Upgrading Troupe

From the release you run to the next one: what to do, in order, what to watch while it
rolls, how to go back, and how to restore when going back is not enough. The commands
assume the release `troupe` in `troupe-system`, with `$chart` and `$version` as in
[installing.md §2](installing.md#2-crds-then-the-chart). A release's own steps, where it
has any, are under [Upgrade in routine-tasks.md](routine-tasks.md#upgrade); read the ones
between your release and the next before you start.

## One release at a time

Go from the release you run to the next one, and from there to the one after. The cluster
suite upgrades the release before each new one to it, on every pull request into `main` and
on every release ([../developer/ci.md](../developer/ci.md#the-upgrade-from-the-previous-release)):
the previous release's chart and images from the registry, an organisation seeded through
the API, then the steps below and nothing else, and every seeded thing asked for again. It
never upgrades across two releases, so **a skipped release is tested nowhere**: 0.23 to
0.25 directly may work, and nobody has seen it do so.

## 1. Back up

Before anything changes, so that a migration that goes wrong has somewhere to go back to:

1. **The plane's database**: a snapshot of the managed instance, or `pg_dump -Fc` of the
   database in the `troupe-plane-database` Secret. It is the only copy of principals,
   triggers, runs, settings, the audit trail and the client version policy
   ([backup-restore.md §1](backup-restore.md#1-where-state-lives)).
2. **Object storage** needs no step of its own if versioning is on, as it must be: an
   upgrade writes no session object, and the workers go on sealing as before.
3. **OpenBao**: `bao operator raft snapshot save` where you run it yourself. An upgrade
   does not touch its keys, but a backup that is a day old is not one.

## 2. The CRDs

Helm installs `crds/` once and never upgrades them, so a field a new release adds is
invisible to the API server until you apply them:

```bash
helm show crds "$chart" --version "$version" | kubectl apply --server-side --force-conflicts -f -
```

A CRD the API server refuses fails here, before anything else changes, with the rule it
refused. Fix nothing by hand: a refusal is a defect in the release; stay where you are and
report it.

## 3. The chart, and the migration before it

```bash
helm upgrade troupe "$chart" --version "$version" -n troupe-system \
  --values my-values.yaml --wait --timeout 10m
```

Your own values file, as you installed with, and the image tags empty unless you pull
through a registry of your own (empty is the chart's `appVersion`). `--rollback-on-failure`
(`--atomic` on Helm 3) undoes a release that does not become ready; without it, a failed
upgrade stays where it failed for you to read.

The chart's `pre-upgrade` hook runs the plane's migrations as a Job, `troupe-plane-migrate`,
before any new pod starts: a migration runs once per release, never from a plane's own
start. If it fails, the upgrade stops there, the old plane goes on serving, and the Job is
kept for its log:

```bash
kubectl -n troupe-system logs job/troupe-plane-migrate
```

## 4. What to watch

1. **The rollout.** `kubectl -n troupe-system rollout status deployment/troupe-plane` and
   `deployment/troupe-operator`. A single plane replica rolls by `Recreate`: seconds without
   a plane, and live sessions do not notice, since the plane is not in their data path.
2. **The build.** `curl -sS https://<plane host>/.well-known/troupe | jq .plane.build`: the
   version and commit must be the ones you rolled, or the rollout has not finished or a tag
   did not move. `kubectl -n troupe-system get pods -o
   custom-columns='POD:.metadata.name,IMAGE:.status.containerStatuses[0].imageID'` shows
   the digest each pod runs.
3. **The workers.** A profile whose image is `release` follows the chart: the plane writes
   it again with the new image, the profile reports `UpgradePending`, and each pod is
   replaced once it holds no active session, by the plane draining it and the operator
   deleting it, one at a time ([profiles-and-policy.md §3](profiles-and-policy.md#3-upgrades-and-drains)).
   `kubectl -n troupe-system get wp` until every profile is `Ready` and none
   `UpgradePending`; its message says how far each pod has got. A profile that names its
   image keeps it until `admin.profile.put`.
4. **The overview.** `admin.overview`, or the console's Overview, and a dormant session
   opened from a client.

## 5. What the plane checks, and how to read it

Some of what a plane needs is not the chart's to give: the OpenBao policy its role holds,
the Pod Security level of the namespaces, the identity provider's groups. The plane and the
operator check these rather than fail on the first request that needs one, and say what is
missing where an administrator looks:

- **A profile's conditions** (`kubectl -n troupe-system get wp <profile> -o yaml`, or the
  console's profile page): `PolicyViolation`, `SecretMissing`, `MCPIdentityMissing`,
  `PlaneCAMissing` and `EndpointUnreachable` each name what is missing and what to do
  ([profiles-and-policy.md, status conditions](profiles-and-policy.md#status-conditions)).
- **The plane's preconditions**, in `admin.overview` and the console's Overview, from the
  release that brings them (the path to 1.0, issue #765): each one missing is one sentence
  saying what it is for and the change that grants it. Nothing in the list is something
  the upgrade did; each is something the release needs that the installation does not yet
  give, and the sentence is the step.
- **The plane's log** at start, where a check could not be made at all (OpenBao or the
  identity provider not answering): that is the installation, not the release.

A precondition the release newly needs is in its notes and under its heading in
[routine-tasks.md](routine-tasks.md#upgrade), before the upgrade rather than after.

## 6. Going back

```bash
helm history troupe -n troupe-system
helm rollback troupe <revision> -n troupe-system --wait
```

`helm rollback` puts the previous chart and images back. It does not undo the CRDs, which
Helm never touched, and it does not undo the migrations: the old plane then runs against
the new schema. Whether it can depends on what the migrations between the two did, and
**no test rolls a release back**: the suite proves the way forward, and the tested way back
is the restore (§7). Roll back when the new release fails to start and its migration
added only what the old one ignores, which its notes say; restore otherwise.

To take the schema back as well, which is for an operator with a problem and not part of a
deploy: run the plane image with the database URL, `TROUPE_PLANE_AUTOSTART=false` and
`RELEASE_DISTRIBUTION=none`, evaluating
`Troupe.Plane.Release.rollback(Troupe.Plane.Repo, <version>)`, where `<version>` is the
newest migration of the release you go back to ([backup-restore.md, a bad
migration](backup-restore.md#a-bad-migration)). A migration that cannot be reversed says so
and stops.

Workers that were replaced on the new image stay on it until their profile names the old
one again, which the rolled-back plane does for a profile that follows the release; their
pods then roll as they empty, as on the way up.

## 7. Restore

When going back is not enough (a migration that lost data, a database left half migrated),
restore from the backup of step 1, in this shape:

1. Scale the plane to zero: `kubectl -n troupe-system scale deployment/troupe-plane
   --replicas=0`. Live sessions keep running; nothing can be opened or created.
2. Restore the database as a **new** instance (a dump into a new database, or the managed
   provider's restore), and point `troupe-plane-database` at it.
3. Roll back the chart to the release the backup was taken under (§6), so the plane and
   the schema agree, and scale it back up.
4. Rebuild the session index from object storage, which a restore leaves behind by however
   long passed since the backup ([backup-restore.md §2](backup-restore.md#2-what-the-repository-provides)).
5. Check, as after an upgrade: `admin.overview`, `admin.audit.verify` (the audit chain
   holds), `admin.sessions.list`, and a dormant session opened from a client. What was
   written only to the database after the backup is lost: audit rows, runs, principals,
   settings, client versions.

`scripts/dev-restore-rehearsal` is this restore rehearsed on the development stack, timed:
a database and a bucket dumped, dropped, restored, and every table, the audit chain, the
organisation's memory, an object's bytes and the index rebuilt from the bucket checked
against what was there before. It is the shape this section follows, not a tool for a real
installation; [backup-restore.md §4](backup-restore.md#4-restore-procedures) has the rest of
what can be lost and how each comes back.
