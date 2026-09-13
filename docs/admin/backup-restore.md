# Backup and restore

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).
>
> Commit `4083b1f` (`TROUPE_OIDC_MCP_SCOPE`, `plane.oidc.mcpScope`) landed while this track was being written and is covered; line numbers are from that tree. Unprefixed plane modules are under `apps/troupe_plane/lib/troupe/plane/`.

What state exists, where, which copy is authoritative, what the repository gives you to get it back, and what it does not. The design argument — object storage as the truth, the plane as an index — is in [../whitepaper.md](../whitepaper.md).

---

## 1. Where state lives and which copy is authoritative

| Store | Holds | Authoritative for | Rebuildable from elsewhere? | Source |
|---|---|---|---|---|
| **Object storage** (`sessions/<id>/…`) | sealed event segments (AES-256-GCM per session key), plaintext manifests, snapshots, workspace archives, blobs | **session truth** — the log every client replays | no; this is the primary copy | `apps/troupe_protocol/lib/troupe/sessions/storage.ex`; [AUDIT.md §1.4](../AUDIT.md) |
| **PostgreSQL** | the session **index** (rows, epochs, head hashes, status), ACLs, anchors, tombstones; the **ledger** (`usage_records`, `budget_reservations`); the **audit trail**; the identity mirror (users, groups, memberships, teams, grants, team admins); profiles and workers; config bundles; **service principals, triggers, trigger runs, platform settings** | everything except session content | the session index: yes, from manifests (`mix troupe.index.rebuild`). Bundles, principals, triggers, runs, settings, audit, ledger, identity: **no** — they exist only here | `repo.ex:5-8`; `lib/mix/tasks/troupe.index.rebuild.ex:4-19`; [AUDIT.md §3.12](../AUDIT.md) |
| **OpenBao** | KV v2 per-session data keys at `secret/troupe/teams/<team>/sessions/<id>`; the transit signing key `troupe-session-tokens` | the ability to **read** any session; the ability to mint tokens workers accept | no. Losing the KV keys makes every sealed segment unreadable forever; losing the transit key invalidates every outstanding token and the workers' cached JWKS until re-pushed | `apps/troupe_protocol/lib/troupe/kms/open_bao.ex:1-15`; `tokens.ex:1-23` |
| **Worker PVCs** (`/var/lib/troupe`, 20Gi per pod) | working copies of live sessions, encrypted archive caches, materialised bundles, the unsealed tail of the log since the last seal — at most **60 s** or one root turn, whichever is sooner | nothing after dormancy | yes: caches from object storage; a live tail is lost if the pod dies before sealing | `resources.ex:461-476`; `apps/troupe_worker/lib/troupe/worker/session/sealer.ex:28-31` |
| **Kubernetes API** | `WorkerProfile`, `TeamVolume`, `TroupePolicy`, the operator's namespaces | the *desired* infrastructure state | `WorkerProfile` from the plane's `profiles` rows (re-apply); `TroupePolicy` from your values; the rest by reconcile | `provision.ex:166-200`; `templates/policy-default.yaml` |
| **Git** (GitOps mode only) | `profiles/<name>.yaml` | the profile manifests | from the plane's rows | `provision.ex:256-282` |

Two consequences worth stating plainly. **A restored database plus object storage is a complete plane for sessions** — that is what the drill proves (`scripts/pitr-drill:4-19`). **A restored database is the only copy of triggers, principals, settings and the audit trail**, so the database backup's recency is what bounds their loss ([AUDIT.md §3.12](../AUDIT.md)).

---

## 2. What the repository provides

### `scripts/pitr-drill`

A restore drill against the **docker-compose development PostgreSQL only** (`scripts/pitr-drill:4-7,24-28`), which has WAL archiving on for this purpose. It is not a disaster-recovery tool and does not run against a cluster or a managed instance. What it does (`:38-163`):

1. Counts sessions and usage records.
2. Takes a base backup with `pg_basebackup` as `postgres`, then creates a named restore point `troupe_drill_<ts>` (`:41-53`).
3. Writes a session manifest to object storage **and** its row to the index *after* the restore point, then forces a WAL switch and waits for the archiver (`:55-97`).
4. Starts the backup as a second cluster on port 5433 with `restore_command`, `recovery_target_name` and `recovery_target_action = promote`; asserts the post-backup row is **absent** (`:99-120`).
5. Runs `mix troupe.index.rebuild --database-url postgres://…:55433/…` against the restored cluster (`:122-133`).
6. Asserts the session is back with the right epoch and head hash (`:135-150`).
7. Runs `mix troupe.ledger.reconcile --database-url …`, which reports nothing when no gateway is configured (`:152-154`).
8. Cleans up the fixture (`:156-162`).

What it proves: PostgreSQL really goes back, the rebuild had something to recover, and the rebuild recovered it (`:164-170`). What the guide says should happen next — it "should become a scheduled job against the real instance" (`docs/deploying-on-scaleway.md:19,348-349`) — has not been built.

### `mix troupe.index.rebuild [--database-url URL]`

Reconstructs the `sessions` index from object storage alone: every manifest is plaintext and every segment's epoch, last sequence and head hash are in its key and metadata, so it needs no key and reads nothing it may not (`lib/mix/tasks/troupe.index.rebuild.ex:4-19`). Safe against a populated index — rows are overwritten, a session with a tombstone stays erased. Prints `found N, rebuilt N, skipped N, failed N` (`:32-41`). Discrepancy: the task's moduledoc says it is "what `troupe admin index rebuild` runs" (`:10`); no such CLI command exists (`apps/troupe_ctl/lib/troupe/ctl/admin.ex:19-74`; [AUDIT.md §2](../AUDIT.md)). In a cluster it runs inside a plane image with the plane's environment:

```bash
kubectl -n troupe-system exec deploy/troupe-plane -- /app/bin/troupe_plane eval 'Troupe.Plane.Index.rebuild()'
```

(`Index.rebuild/0` is what the Mix task calls, `troupe.index.rebuild.ex:32`; the release has no Mix. Unconfirmed against a live cluster.)

### `mix troupe.ledger.reconcile [--days N] [--database-url URL]`

Compares a window of `usage_records` with the gateway's `/spend/logs` by request id and reports `missing`, `extra`, `unmetered`, `mismatched` and total drift; exits non-zero over the threshold (1 000 000 micros) so it can be a cron job whose failure means something (`lib/mix/tasks/troupe.ledger.reconcile.ex:4-20,63-65`; `reconcile.ex:40,77-88`). It never repairs (`reconcile.ex:28-30`). It needs `Application.get_env(:troupe_plane, :gateway)` which nothing sets ([integrations.md §5](integrations.md#5-llm-gateway)).

### `Troupe.Plane.Release.rollback/2`

`bin/troupe_plane eval 'Troupe.Plane.Release.rollback(Troupe.Plane.Repo, <version>)'` rolls migrations down to a version (`release.ex:27-32`). Nothing in the chart calls it; the migration Job only goes up (`plane-deployment.yaml:78`).

### Object-storage versioning and the erasure order

Erasure is designed so a restore cannot resurrect an erased session (`erasure.ex:1-21`):

1. A **tombstone** row is written first, the session is set read-only and its placement released (`erasure.ex:53-62`).
2. A healthy pod of the profile is asked to `session.erase`: it fences the session, **destroys the KV key metadata** (every version), then deletes the objects (`erasure.ex:64-113`; `kms/open_bao.ex:48-58`).
3. A pod that was offline applies pending erasures when it enrols, before serving anything (`erasure.ex:126-150`).

Because the key goes first, a versioned bucket's prior versions and any backup copy of the ciphertext are unreadable, and `mix troupe.index.rebuild` leaves a tombstoned session erased (`troupe.index.rebuild.ex:17-18`). This only holds if **bucket versioning is on** and the OpenBao delete really removed every version — a bucket without versioning makes the promise vacuous (`values.scaleway.yaml:118-121`).

---

## 3. What the repository does not provide

| Missing | Consequence | Source |
|---|---|---|
| A CronJob or any scheduled backup | database backups are the managed provider's PITR (recommended) or yours | `docs/deploying-on-scaleway.md:19,149,348-349`; no `CronJob` in `charts/` |
| OpenBao Raft snapshots or a backup of the unseal share | losing the single replica's PVC loses every session key; the Shamir share lives in a Kubernetes Secret | `deploy/scaleway/openbao.values.yaml:11-33`; [AUDIT.md §4.7](../AUDIT.md) |
| Object-storage lifecycle or replication rules | erased objects' versions are never expired; no cross-region copy | [AUDIT.md §4.8](../AUDIT.md) |
| A scheduled `troupe.ledger.reconcile` and its `:gateway` config | drift is found only when somebody runs it | [integrations.md §5](integrations.md#5-llm-gateway) |
| A backup of `platform_settings`, triggers, principals beyond the database | they are database rows; the database backup is the backup | [AUDIT.md §3.12](../AUDIT.md) |
| Any retention job for `erase_after_days` | recorded on the team, acted on by nothing found | [AUDIT.md §3.5](../AUDIT.md) |

What the guide recommends instead: **Managed PostgreSQL with PITR** and **bucket versioning** (`docs/deploying-on-scaleway.md:19-20,149-150`).

---

## 4. A restore procedure

Written with only the things that exist. Steps marked **(recommendation)** are not scripts in the repository; everything else names the code it relies on.

### 4.1 The plane's database was lost or corrupted

1. **(recommendation)** Restore the managed instance to the latest point before the incident, as a **new** instance beside the old one, so the rebuild runs against it before anything is switched over — the shape the drill uses (`scripts/pitr-drill:99-110,122-126`).
2. Scale the plane to zero so nothing writes to the old database while you switch:

   ```bash
   kubectl -n troupe-system scale deployment/troupe-plane --replicas=0
   ```

   Live sessions do not notice: the plane is not in their data path, and workers reconnect to the control port when it is back (`plane-deployment.yaml:132-137`). Nothing can be *opened* or *created* while it is down.
3. Point `troupe-plane-database` at the restored instance:

   ```bash
   kubectl -n troupe-system create secret generic troupe-plane-database --from-literal=url='ecto://USER:PASS@HOST:PORT/DB' --dry-run=client -o yaml | kubectl apply -f -
   ```

4. Bring the plane back; the migration hook runs on `helm upgrade`, or simply scale up if the schema is current:

   ```bash
   kubectl -n troupe-system scale deployment/troupe-plane --replicas=<n>
   ```

5. **Rebuild the session index from object storage** so every session sealed after the backup point is back (`troupe.index.rebuild.ex:4-19`):

   ```bash
   kubectl -n troupe-system exec deploy/troupe-plane -- /app/bin/troupe_plane eval 'IO.inspect(Troupe.Plane.Index.rebuild())'
   ```

   Expect `found`, `rebuilt`, `skipped`, `failed` counts. The plane needs object-store credentials in `troupe-object-store` for this (`plane-deployment.yaml:317-330`).
6. Workers re-enrol on their own; on enrol the plane sends `pending_erasures` and pushes the JWKS (`erasure.ex:126-150`; `ARCHITECTURE.md:380-395`). Usage the pods still hold is re-sent from the plane's `usage_seq` watermark, and the ledger's uniqueness on request id turns overlap into duplicates rather than double charges (`ARCHITECTURE.md:944-960`).
7. **Accept the loss** of anything written between the restore point and the incident that lives only in the database: audit rows, trigger runs, principals rotated or created, settings changed, team admins added ([AUDIT.md §3.12](../AUDIT.md)). Re-create principals with `troupe admin principal create` (a rotate gives triggers a new secret to be told about) and re-apply settings with `troupe admin setting set`.
8. Run the reconcile to see how much ledger drift the gap produced — once `:gateway` is configured (`reconcile.ex:185-205`):

   ```bash
   kubectl -n troupe-system exec deploy/troupe-plane -- /app/bin/troupe_plane eval 'IO.inspect(Troupe.Plane.Reconcile.nightly())'
   ```

9. Verify: `troupe admin overview`, `troupe admin sessions`, open a dormant session from a client.

### 4.2 Object storage was lost

There is no recovery: sealed segments exist nowhere else after dormancy (§1). **(recommendation)** Versioning protects against overwrite and deletion of individual objects; cross-region replication is not configured by anything in the repository ([AUDIT.md §4.8](../AUDIT.md)). Live sessions keep working on their pods until they go dormant and fail to upload.

### 4.3 OpenBao was lost

- If the Raft PVC survives, the pod restarts and the sidecar unseals it from the share in the Secret (`openbao.values.yaml:20-33`). Sessions cannot be opened during the restart; live ones are unaffected (`:13-18`).
- If the PVC is gone: the KV keys are gone and **every sealed session is unreadable**. The index rows still exist and will look normal until a pod tries to fetch the key. Re-create the transit key and the auth roles (`dev/kind/dependencies.yaml:231-274` for the commands) so new sessions can be minted and signed; **(recommendation)** take Raft snapshots (`bao operator raft snapshot save`) on a schedule and store the unseal share outside the cluster — nothing in the repository does either ([AUDIT.md §4.7](../AUDIT.md)). Then erase the unreadable sessions with `troupe admin session erase` so the index matches reality.

### 4.4 A worker PVC was lost

Delete the pod; the StatefulSet recreates it with a fresh PVC, it enrols, and sessions are restored from object storage on their next activation (`resources.ex:461-466`; worker restore notes in [AUDIT.md §1.1](../AUDIT.md)). Lost with it: at most the last 60 s or the current root turn of any session that was live on that pod (`sealer.ex:28`), and the local blob store, which is never uploaded ([AUDIT.md §4.12](../AUDIT.md)).

### 4.5 A migration went wrong

The failed hook Job is kept with its logs (`plane-deployment.yaml:47-49`). To go back one schema version:

```bash
kubectl -n troupe-system run troupe-rollback --rm -it --restart=Never --image=<plane image> --env=DATABASE_URL="$(kubectl -n troupe-system get secret troupe-plane-database -o jsonpath='{.data.url}' | base64 -d)" --env=TROUPE_PLANE_AUTOSTART=false --env=RELEASE_DISTRIBUTION=none -- /app/bin/troupe_plane eval 'Troupe.Plane.Release.rollback(Troupe.Plane.Repo, <version>)'
```

(`release.ex:27-32`; the env mirrors the Job at `plane-deployment.yaml:85-97`. Add `ERL_FLAGS=+Q 65536` if the pod is OOMKilled at once, `:80-86`. Unconfirmed against a live cluster.)

---

## 5. Running the drill

Against the development stack only:

```bash
scripts/dev-up
```

```bash
scripts/pitr-drill
```

Environment: `TROUPE_PG_CONTAINER` (default `troupe-dev-postgres-1`), `TROUPE_PITR_DB` (default `troupe_plane_test`) (`scripts/pitr-drill:24-25`). It needs Docker, the compose stack, and a Mix toolchain able to run `MIX_ENV=test mix run` (`:61,133,153`).
