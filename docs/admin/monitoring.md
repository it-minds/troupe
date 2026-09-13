# Monitoring and troubleshooting

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).
>
> Commit `4083b1f` (`TROUPE_OIDC_MCP_SCOPE`, `plane.oidc.mcpScope`) landed while this track was being written and is covered; line numbers are from that tree. Unprefixed plane modules are under `apps/troupe_plane/lib/troupe/plane/`.

What the deployment tells you about itself, and the failures already seen. Short version: health probes, Kubernetes conditions, the console, the audit log and JSON logs exist; **no metrics exporter, Prometheus endpoint or ServiceMonitor exists anywhere in the repository** (grep for `prometheus`, `ServiceMonitor`, `telemetry_metrics`, `PromEx` under `apps/`, `charts/`, `deploy/` finds nothing).

---

## 1. Health endpoints

| Component | Endpoint | Answer | Probe in chart | Source |
|---|---|---|---|---|
| plane | `GET /healthz` | `{"ok": true}`, always 200 while the endpoint is up; touches nothing | not used by the chart | `web/router.ex:46` |
| plane | `GET /.well-known/troupe` | the discovery document (issuer, client id, endpoints, scopes, plane name and protocol version) | **startup** every 2 s × 30 (60 s grace), **readiness** every 5 s, **liveness** every 10 s | `web/router.ex:63-77`; `plane-deployment.yaml:348-362` |
| plane | `GET /.well-known/jwks.json` | 200 with the transit key versions, **503** when OpenBao or its credential is unreachable — the quickest OpenBao check | not a probe | `web/router.ex:93-98`; `tokens/credential.ex:19-23` |
| worker pod | `GET /health/live` | `ok` | liveness every 5 s after 5 s | `apps/troupe_gateway/lib/troupe/gateway/web.ex:24-26`; `resources.ex:512-530` |
| worker pod | `GET /health/ready` | `ready`, or **503 `draining`** while the pod drains, so its Service stops routing | readiness every 5 s after 5 s | `gateway/web.ex:28-35`; `apps/troupe_worker/lib/troupe/worker/harness.ex:74-78` |
| a2a | `GET /healthz` | 200 | startup 2 s × 30, readiness 5 s, liveness 10 s | `a2a-deployment.yaml:97-106`; `docs/a2a.md:20` |
| operator | none over HTTP | `exec /app/bin/troupe_operator pid` connects to the running node and prints its OS pid; non-zero when no node answers | liveness every 30 s after 30 s, timeout 10 s, 3 failures | `operator-deployment.yaml:109-122` |

Timings: `admin.identity.check` returns `took_ms` per check (`oidc.ex:337-345`), which is the only timed probe an admin can call. `/.well-known/troupe` carries no timing.

---

## 2. Kubernetes signals

- **`WorkerProfile` conditions** `Ready`, `PolicyViolation`, `SecretMissing`, `UpgradePending`, with reasons and messages, and the printer columns `Replicas`, `Ready`, `Violation`, `Age` (`crds/workerprofile.yaml:136-166`). What each means, and why `SecretMissing` cannot be trusted, is in [profiles-and-policy.md §3](profiles-and-policy.md#3-status-conditions).

  ```bash
  kubectl -n troupe-system get wp
  ```

- **Events**: the operator's ClusterRole may create and patch Events (`operator-rbac.yaml:28-30`) and Bonny labels them with `operator_name: troupe-operator` (`config/config.exs:23-31`). Troupe code itself writes none; unconfirmed which events Bonny emits.

  ```bash
  kubectl -n troupe-system get events --sort-by=.lastTimestamp
  ```

- **PodDisruptionBudgets**: `troupe-plane` `minAvailable: 1` only with more than one replica (`plane-deployment.yaml:383-398`); `troupe-w-<profile>` `maxUnavailable: 1` per profile (`resources.ex:419-433`). A node drain that hangs is one of these doing its job.
- **StatefulSet revisions**: `UpgradePending` is derived from `status.updateRevision` versus `currentRevision` and each pod's `controller-revision-hash` (`reconciler.ex:224-257`).
- **Leader Lease** for the operator in `troupe-system` (`operator-rbac.yaml:43-46`).

---

## 3. The console and `admin.overview`

| Page | Shows | Refresh | Source |
|---|---|---|---|
| `/admin` Overview | per visible profile: pods, conditions, load, bundle state; per team: budget, period, spent and reserved micros; counts of active, dormant and read-only sessions | every **2 s** | `admin.ex:107-124,1055-1104,1136-1147`; `web/live/overview.ex:24-37` |
| `/admin/workers[/:profile]` Workers | pods per profile with heartbeat, capacity, load, disk, bundle hash; drain button (platform admin) | every **1 s** | `web/live/workers.ex:21-37` |
| `/admin/sessions` | session metadata with status, origin, cost, review flags; never content | on demand | `admin.ex:352-378` |
| `/admin/bundles` | versions per channel, adoption per profile (`current`, `ahead`, `stale` pods) | on demand | `bundles.ex:246-286` |
| `/admin/triggers[/:team]` | triggers and runs with derived states | on demand | `triggers.ex:395-428` |
| `/admin/audit` | the audit trail | on demand | `audit.ex:126-144` |
| `/admin/settings` | every setting, its source and effect; the identity check | on demand | `settings.ex:267-304` |

The layout shows an offline banner and a break-glass banner (plane audit notes). Every page is one call into `Troupe.Plane.Admin`; `troupe admin overview` and the MCP tool `admin_overview` return the same map (`admin.ex:107-124`).

---

## 4. Audit log

Every administrative change is a row in `audit_events` with `actor`, `action`, `subject_kind`, `subject_id`, a `detail` diff keyed by dotted path (`spec.llm.model`) and `occurred_at`; values whose key looks like a secret are redacted and logged as an error if that ever fires (`audit.ex:1-17,26-29,100-124`). Actions written: `profile.put`, `profile.delete`, `pod.drain`, `team.enable`, `team.update`, `team.grant`, `team.revoke`, `team.admin.add`, `team.admin.remove`, `session.erase`, `session.review`, `setting.put`, `setting.reset`, `bundle.publish`, `bundle.retire`, `principal.create`, `principal.rotate`, `principal.disable`, `trigger.put`, `trigger.delete`, `trigger.run`, `admin.breakglass` (both outcomes) (plane audit notes; `breakglass.ex:128-139`). A refused change writes nothing (`ARCHITECTURE.md:727`).

```bash
troupe admin audit
```

Filters: `actor`, `kind`, `subject_id`, `since`, `limit` (default 100) (`audit.ex:136-144`). Not team-scoped ([roles-and-permissions.md §9](roles-and-permissions.md#9-the-admin-method-table)).

---

## 5. Logs

Set `TROUPE_LOG_FORMAT=json` on the **plane** for one JSON object per line — `time`, `level`, `msg`, and `request_id`/`session_id` when present (`runtime.exs:272-277`; `log_formatter.ex:1-22,40-61`). There is **no Helm value**; add the variable to the plane Deployment yourself (a `helm upgrade --set` cannot add an env entry the template does not render). Only the plane has the formatter; operator, worker and a2a log in Elixir's default text format.

Lines worth alerting on, as they are written:

| Line | Meaning | Source |
|---|---|---|
| `troupe plane: no OpenBao credential (...)` | the plane can neither sign tokens nor publish its JWKS | `tokens/credential.ex:128-137` |
| `troupe plane: break-glass panel login from <ip>` / `break-glass token refused from <ip>` (warning) | the door was used or probed | `breakglass.ex:133-136` |
| `troupe plane: admin sign-in refused (<step>) — <reason>` (warning) | which of the console login steps failed and why | `web/admin_auth.ex:118-126` |
| `troupe plane: no TroupePolicy is configured or reachable; every MCP host is allowed` | the plane has no `:k8s_conn`; bundle egress checks are open | `cluster_policy.ex:99-107` |
| `troupe plane: <ns>/<pod> stopped heartbeating; ...` | a pod missed its 15 s lease | `fleet/sweeper.ex:40-50` |
| `troupe plane: ledger drift of N micros — ...` (warning, error over threshold) | reconcile found disagreement | `reconcile.ex:97-107` |
| `troupe plane: scheduler could not fire <trigger> ...` (warning) | a cron firing failed to create | `triggers/scheduler.ex:95-100` |
| `troupe plane: erasure of <id> is pending: ...` (warning) | no healthy pod could carry out an erasure; it will run at the next enrol | `erasure.ex:70-76` |
| `troupe operator: refusing <profile>: <violations>` (warning) | policy violation; nothing was created | `reconciler.ex:106-108` |
| `troupe operator: pruning <kind>/<name>` | scale-down or grant removal took an object away | `reconciler.ex:277` |

---

## 6. Telemetry events

`troupe_core` emits four `:telemetry` events and **nothing attaches to them** in the repository — no reporter, no exporter:

| Event | Measurements | Metadata | Source |
|---|---|---|---|
| `[:troupe, :llm, :start]` | `system_time` | `session_id`, `agent_path`, `model` | `apps/troupe_core/lib/troupe/agent/server.ex:758-762` |
| `[:troupe, :llm, :stop]` | `input_tokens`, `output_tokens` | `session_id`, `agent_path` | `agent/server.ex:873-880` |
| `[:troupe, :tool, :stop]` | `system_time` | `session_id`, `agent_path`, `tool`, `ok?` | `agent/server.ex:1061-1069` |
| `[:troupe, :agent, :transition]` | `system_time` | `session_id`, `agent_path`, `state` | `agent/server.ex:1540-1544` |

These fire on worker pods (and the local daemon). Attaching a handler means a release config overlay or a fork; nothing in the chart does it.

---

## 7. Fleet health mechanics

| Mechanism | Numbers | Source |
|---|---|---|
| Worker heartbeat | every **5 s** over the control channel, carrying `capacity`, `bundle_hash`, `version`, `active_sessions`, `disk_used_bytes`, `disk_total_bytes` | `apps/troupe_worker/lib/troupe/worker/plane/link.ex:38,180-181,379-388` |
| Lease | a pod with no heartbeat for **15 s** is unhealthy and not placed on; `Fleet.Sweeper` runs every lease/3 (5 s) on every replica and logs each pod it marks | `fleet.ex:16-22,110-150`; `fleet/sweeper.ex:25-60` |
| Placement filters | healthy, not draining, heartbeat inside the lease, disk below **0.80** | `fleet.ex:110-130,152-154` |
| Worker disk | `Disk.Watch` every 30 s evicts encrypted caches above **0.70** until under it; `Disk` reports `:high` at 0.80 and `:critical` at 0.90. Discrepancy: `disk.ex:10-14` promises sleeping sessions and refusing placements above the watermarks; only cache eviction is implemented ([AUDIT.md §2](../AUDIT.md)) | `apps/troupe_worker/lib/troupe/worker/disk.ex:16-17`; `disk/watch.ex:27,106-140` |
| Session dormancy | after 10 min idle on the pod; seal every 60 s and at turn end; snapshot every 500 events | `worker/session/manager.ex:51`; `worker/session/sealer.ex:28-31` |
| Ledger cache | spend sums cached 60 s per node | `application.ex:44-46` |
| Trigger scheduler | 30 s tick; a never-fired trigger only within 120 s of its minute | `triggers/scheduler.ex:34-38` |
| Settings cache | 5 s | `settings.ex:221` |
| OIDC JWKS | cached until a bad signature; refetched at most once per 60 s | `oidc.ex:22-23,190-203` |

Ledger reconciliation (`mix troupe.ledger.reconcile`) is the drift check between what pods reported and what the gateway billed; see [backup-restore.md §2](backup-restore.md#2-what-the-repository-provides) and [integrations.md §5](integrations.md#5-llm-gateway).

---

## 8. If something does not work

The table from `docs/deploying-on-scaleway.md:357-373`, kept as written, then extended with causes found during the audit.

| Symptom | Cause | Source |
|---|---|---|
| Pod OOMKilled in one second, empty log | the BEAM sizes its port table from `RLIMIT_NOFILE`; `+Q` is set by the chart and the operator — set it in any pod spec you write yourself | `deploying-on-scaleway.md:364`; `plane-deployment.yaml:178-189` |
| Release dies in its config provider | Kubernetes injects `<SERVICE>_PORT=tcp://…`, which collides with `TROUPE_PLANE_CONTROL_PORT`; `enableServiceLinks: false` everywhere | `:365`; `plane-deployment.yaml:152-157` |
| Worker enrols, looks healthy, refuses every client | no JWKS; the plane pushes one on enrol and logs an error if the push failed | `:366` |
| `permission denied` logging into OpenBao | no reviewer JWT on the Kubernetes auth mount | `:367`; `dev/kind/dependencies.yaml:185-187` |
| Worker Ingress answers 503 | the ingress namespace lacks `troupe.dev/ingress=true` | `:368`; `resources.ex:284-291` |
| `the pod did not accept the session`, signer crash on `nil` | object-store credentials missing from the **worker** namespace | `:369`; `resources.ex:595-596` |
| Sessions placed twice, budgets double-counted | `plane.replicas: 2` with `distribution: none`; the chart now refuses this at render | `:370`; `_helpers.tpl:31-35` |
| Workers enrol, then go quiet | the worker namespace lacks `troupe.dev/workers=true`; an older operator's namespace gets it on the next reconcile | `:371`; `network-policy.yaml:42-48` |
| `429` from the plane behind one office address | `plane.ingress.rateLimit` is per client IP; raise `connections` first | `:372`; `values.yaml:93-100` |
| Image pull fails with `unauthorized` in a worker namespace | the pull secret exists in `troupe-system` but not in `troupe-w-<profile>` | `:373`; `resources.ex:497-501` |
| **`SecretMissing: True` on every profile, secrets present** | the reconciler checks `troupe-system`, not the worker namespace, with a `get` its ClusterRole does not grant | `reconciler.ex:184-195`; `operator-rbac.yaml:15-46`; [AUDIT.md §2, §4.4](../AUDIT.md) |
| **`profile put` succeeds but no `WorkerProfile` appears; answer says `not_applied`, `no_cluster`** | the plane's `:k8s_conn` is never configured; direct provisioning has no connection. Apply the CR yourself | `provision.ex:242-250`; [AUDIT.md §3.1](../AUDIT.md) |
| **Every bundle publishes, even with an MCP host outside `allowedEgress`**, one warning in the log | same cause: no `:k8s_conn`, so `ClusterPolicy` allows every host | `cluster_policy.ex:57-60,99-107` |
| **`PolicyViolation: NoPolicy` on every profile** | `policy.name` is not `default` and nothing sets `TROUPE_POLICY_NAME` | `reconciler.ex:310,320-331` |
| **Console login lands on `/admin/denied` with "administer nothing here" listing the groups carried** | the `platform_admin_group` id is not among them, or `groups_claim` names the wrong claim | `web/admin_auth.ex:99-116`; `settings.ex:50-70` |
| **Console login: "token endpoint answered 200 without an id_token"** | `openid` not in scope, or the registration cannot issue id_tokens | `web/admin_auth.ex:149-159` |
| **Every sign-in fails before a password, Entra says `AADSTS650053`** | `groups` requested as a scope; upgrade to a plane at or after `6c29471`, or set `plane.oidc.scopes` without it | `web/router.ex:48-59` |
| **`/.well-known/jwks.json` returns 503; `troupe login` fails at exchange** | no OpenBao credential: `TROUPE_BAO_TOKEN` unset and the projected JWT unreadable or refused by role `troupe-plane` | `tokens/credential.ex:118-141` |
| **`/mcp` returns 401 to a client that has a valid provider token** | the token's `aud` is none of the client id, `api://<client id>` or `<base_url>/mcp`, or the issuer differs (v1 vs v2 endpoint) | `oidc.ex:88-120`; `oidc.ex:303-305` |
| **MCP OAuth fails in the browser after consent, Entra says `AADSTS9010010`** | the advertised scope and the client's `resource` name different resources; a plane before `4083b1f` advertised `api://<client-id>/admin`. Upgrade, and make the registration expose `<base_url>/mcp/admin` (or set `plane.oidc.mcpScope`) | `web/router.ex:311-338`; `values.yaml:150-154` |
| **Console redirect URI is `http://localhost:4000/admin/callback`** | `TROUPE_BASE_URL` unset in a hand-written manifest | `web/admin_auth.ex:338-341` |
| **`troupe.ledger.reconcile` says `:no_gateway_configured`** | `:troupe_plane, :gateway` is not set by anything in the repository | `reconcile.ex:194-205` |
| **Pods stay on the old image after a profile change; `UpgradePending: True`** | `OnDelete`; nothing deletes the pod. Drain with `troupe admin pod drain`, then `kubectl delete pod` | `reconciler.ex:211-222`; [AUDIT.md §3.13](../AUDIT.md) |
| **Worker pod `CreateContainerConfigError`** | the LLM Secret named by `llm.secretRef` is missing in `troupe-w-<profile>`; that `secretKeyRef` is not optional | `resources.ex:629-644` |
| **Worker cannot write to object storage on Scaleway, plane can** | region mismatch: the plane signs for `fr-par`, workers for `us-east-1`. Unconfirmed whether Scaleway rejects it | `plane-deployment.yaml:259-260`; `resources.ex:532-585` |
| **Team enable fails with a changeset error on `budget_period`** | `default_budget_period` set to `daily`; the team schema accepts `monthly` or `never` | `identity/team.ex:69`; `settings.ex:97` |
| **Plane replicas do not cluster after a rolling image upgrade** | the Erlang cookie is generated per build and not pinned; two image builds may not share one | [AUDIT.md §3.15](../AUDIT.md) |
| **Two profiles' team volumes never appear inside sessions** | mounted on the pod, not passed to the session's mount table | [AUDIT.md §3.2](../AUDIT.md) |
