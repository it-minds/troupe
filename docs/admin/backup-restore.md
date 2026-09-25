# Backup and restore

What state exists, which copy is authoritative, what the repository gives you to get it
back, and what it does not.

## 1. Where state lives

| Store | Holds | Rebuildable? |
|---|---|---|
| **Object storage** `sessions/<id>/…` | sealed event segments (AES-256-GCM per session key), plaintext manifests, snapshots, workspace archives, blobs — **the session truth** | no; this is the primary copy |
| **PostgreSQL** | the session index, ACLs, tombstones; the ledger; the audit trail; the identity mirror (people, groups, teams, grants, team admins); profiles and workers; bundles; principals, triggers, runs, settings | the session index yes, from manifests. **Everything else exists only here** |
| **OpenBao** | per-session data keys (KV v2); the transit signing key | no. Losing the KV keys makes every sealed segment unreadable forever; losing the transit key invalidates every outstanding token |
| **Worker volumes** `/var/lib/troupe` | working copies of live sessions, caches, materialised bundles, the unsealed tail of the log — at most 60 s or one root turn | yes, except that tail |
| **Kubernetes** | `WorkerProfile`, `TeamVolume`, `TroupePolicy`, worker namespaces | profiles from the plane's rows (re-apply); the policy from your values; the rest by reconcile |
| **Git** (GitOps mode) | `profiles/<name>.yaml` | from the plane's rows |

So a restored database plus object storage is a complete plane for sessions, and the
database backup is the only copy of triggers, principals, settings and the audit trail.

## 2. What the repository provides

**`scripts/pitr-drill`** is a restore drill against the docker-compose development
PostgreSQL only (it has WAL archiving on for this). It takes a base backup and a named
restore point, writes a session after it, restores to the point as a second cluster,
asserts the late row is gone, rebuilds the index from object storage, and asserts the
session is back with the right epoch and head hash. Run it with `scripts/dev-up` then
`scripts/pitr-drill` (`TROUPE_PG_CONTAINER`, `TROUPE_PITR_DB` override the container and
database). It is not a disaster-recovery tool and nothing schedules it against a real
instance.

**`mix troupe.index.rebuild [--database-url URL]`** reconstructs the session index from
object storage alone — manifests are plaintext and every segment's epoch, last sequence and
head hash are in its key and metadata, so it needs no key. Safe on a populated index; a
tombstoned session stays erased; prints `found`, `rebuilt`, `skipped`, `failed`. A release
has no Mix, so in a cluster:

```bash
kubectl -n troupe-system exec deploy/troupe-plane -- /app/bin/troupe_plane eval 'IO.inspect(Troupe.Plane.Index.rebuild())'
```

**`mix troupe.ledger.reconcile [--days N] [--database-url URL]`** compares usage with the
gateway and never repairs ([integrations.md §5](integrations.md#5-llm-gateway)).

**Erasure is ordered so a restore cannot bring a session back**: a tombstone first (the
session goes read-only), then a healthy pod of the profile destroys the key's metadata —
every version — and then deletes the objects. A pod that was offline applies pending
erasures when it enrols. Because the key goes first, old object versions and backup copies
are unreadable. That holds only with **bucket versioning on**.

## 3. What it does not provide

No scheduled backup of any kind (use the managed database's PITR); no OpenBao Raft
snapshots or backup of the unseal share; no object-storage lifecycle or replication rules;
no scheduled ledger reconcile; no job that acts on a team's `erase_after_days`.

## 4. Restore procedures

### The plane's database

1. Restore the managed instance to the last point before the incident as a **new**
   instance, as the drill does.
2. `kubectl -n troupe-system scale deployment/troupe-plane --replicas=0`. Live sessions do
   not notice — the plane is not in their data path — but nothing can be opened or created.
3. Point `troupe-plane-database` at the new instance
   (`kubectl create secret … --dry-run=client -o yaml | kubectl apply -f -`) and scale back
   up, or `helm upgrade` if the schema needs migrating.
4. Rebuild the index (§2), with object-store credentials in `troupe-system`.
5. Workers re-enrol by themselves and receive pending erasures and the JWKS; usage they hold
   is re-sent from the plane's watermark, and the ledger's uniqueness on request id makes
   overlap a duplicate rather than a double charge.
6. Accept the loss of what lived only in the database after the restore point — audit rows,
   runs, principals created or rotated, settings, team admins — and re-create what matters.
7. Verify with `admin.overview`, `admin.sessions.list`, and a dormant session opened from a
   client.

### Object storage

No recovery: after dormancy sealed segments exist nowhere else. Versioning protects against
overwrite and deletion of single objects; nothing here configures replication.

### OpenBao

If the Raft volume survives, the pod restarts and the sidecar unseals it. If it is gone, so
are the keys and **every sealed session is unreadable**: re-create the transit key and the
auth roles so new sessions work, erase the unreadable sessions so the index matches, and
from then on take `bao operator raft snapshot save` on a schedule and keep the unseal share
outside the cluster.

### A worker volume

Delete the pod; it comes back with a fresh volume, enrols, and its sessions restore from
object storage at their next activation. Lost: at most the last 60 s or current root turn of
a session that was live there, and the local blob store.

### A bad migration

The failed hook Job is kept with its logs. To go back one schema version, run the plane
image with the database URL, `TROUPE_PLANE_AUTOSTART=false` and `RELEASE_DISTRIBUTION=none`
(and `ERL_FLAGS="+Q 65536"`), evaluating
`Troupe.Plane.Release.rollback(Troupe.Plane.Repo, <version>)`.
