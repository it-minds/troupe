# Monitoring and troubleshooting

What the deployment tells you about itself, and the failures already seen. Health probes,
Kubernetes conditions, the console, the audit log and JSON logs exist. **No metrics
exporter, Prometheus endpoint or ServiceMonitor exists** anywhere in the repository.

## 1. Health endpoints

| Component | Endpoint | Answer | Probe in chart |
|---|---|---|---|
| plane | `GET /healthz` | always 200 while up; touches nothing | none |
| plane | `GET /.well-known/troupe` | discovery: issuer, client id, endpoints, scopes, plane name, protocol version and build (commit, time, version) | startup 2 s × 30, readiness 5 s, liveness 10 s |
| plane | `GET /.well-known/jwks.json` | the signing keys, or **503** when OpenBao or its credential is unreachable — the quickest OpenBao check | none |
| worker | `GET /health/live`, `GET /health/ready` | `ok`; `ready`, or **503 `draining`** so its Service stops routing | liveness and readiness every 5 s |
| a2a | `GET /healthz` | 200 | startup, readiness, liveness |
| operator | `exec /app/bin/troupe_operator pid` | non-zero when no node answers | liveness every 30 s |

If the build in `/.well-known/troupe` (also in the console's footer) is not the commit you
deployed, the rollout has not finished or the image tag did not move.

## 2. Kubernetes signals

- **`WorkerProfile` conditions** `Ready`, `PolicyViolation`, `SecretMissing`,
  `UpgradePending`, `EgressByHostname` ([profiles-and-policy.md §2](profiles-and-policy.md#status-conditions));
  `kubectl -n troupe-system get wp`.
- **Events**: the operator may write them (through Bonny); Troupe's own code writes none.
- **PodDisruptionBudgets**: the plane's `minAvailable: 1` with more than one replica, each
  profile's `maxUnavailable: 1`. A node drain that hangs is one of these doing its job.
- **The operator's leader Lease** in `troupe-system`.

## 3. The console

`/admin` is the overview: per profile its pods, conditions, load and bundle state; per team
budget, spend and reservations; session counts. It refreshes every two seconds, the Workers page every second. Sessions, bundles (with
adoption per pod), triggers and runs, audit and settings each have a page. Every page is a
call into `Troupe.Plane.Admin`, and `admin.overview` returns the same map to `/rpc` and
`/mcp`.

## 4. Audit log

Every administrative change is an `audit_events` row: `actor`, `action`, `subject_kind`,
`subject_id`, a `detail` diff keyed by dotted path (`spec.llm.model`) and the time. Values
whose key looks like a secret are redacted. Break-glass writes `admin.breakglass` on success
and on refusal. A refused change writes nothing. `admin.audit.list` filters by `actor`,
`kind`, `subject_id`, `since` and `limit`, and is **not** team-scoped: a team admin reads
every team's changes. `admin.audit.verify` checks the trail's integrity.

## 5. Logs

`TROUPE_LOG_FORMAT=json` on the **plane** gives one JSON object per line with `request_id`
and `session_id`. There is no Helm value: add the variable to the Deployment yourself. The
operator, workers and A2A log in Elixir's default text format. Lines worth alerting on:

| Line (prefix `troupe plane:` unless noted) | Meaning |
|---|---|
| `no OpenBao credential (...)` | the plane can neither sign tokens nor publish its JWKS |
| `break-glass panel login from <ip>` / `break-glass token refused from <ip>` | the door was used or probed |
| `admin sign-in refused (<step>) — <reason>` | which console login step failed, and why |
| `no TroupePolicy is configured or reachable; every MCP host is allowed` | the plane has no Kubernetes connection; bundle egress checks are open |
| `<ns>/<pod> stopped heartbeating; ...` | a pod missed its 15 s lease |
| `ledger drift of N micros — ...` | the reconcile found disagreement |
| `scheduler could not fire <trigger> ...` | a cron firing failed to create its session |
| `erasure of <id> is pending: ...` | no healthy pod could erase; it runs at the next enrolment |
| `troupe operator: refusing <profile>: <violations>` | a policy violation; nothing was created |
| `troupe operator: pruning <kind>/<name>` | a scale-down or a revoked grant took an object away |

`troupe_core` also emits `:telemetry` events — `[:troupe, :llm, :start|:stop]`,
`[:troupe, :tool, :stop]`, `[:troupe, :agent, :transition]` — and nothing attaches to them.

## 6. Fleet mechanics

| Mechanism | Numbers |
|---|---|
| Worker heartbeat | every 5 s over the control channel: capacity, bundle hash, version, active sessions, disk, draining |
| Lease | no heartbeat for 15 s and a pod is unhealthy and not placed on |
| Placement | healthy, not draining, disk below 80 % |
| Worker disk | caches evicted above 70 %, checked every 30 s |
| Dormancy | a session sleeps after 10 min idle on the pod; sealed every 60 s and at a turn's end |
| Caches | ledger sums 60 s per node; settings 5 s; provider JWKS until a bad signature |

## 7. If something does not work

| Symptom | Cause |
|---|---|
| Pod OOMKilled in a second, empty log | the BEAM sized its port table from `RLIMIT_NOFILE`; set `+Q` in any pod spec you write yourself |
| A release dies in its config provider | Kubernetes injected `<SERVICE>_PORT=tcp://…`, which collides with `TROUPE_PLANE_CONTROL_PORT`; keep `enableServiceLinks: false` |
| A worker enrols, looks healthy and refuses every client | it has no JWKS; the plane pushes one at enrolment and logs if that failed |
| `permission denied` logging into OpenBao | no reviewer JWT on the Kubernetes auth mount |
| A worker Ingress answers 503 | the ingress namespace lacks `troupe.dev/ingress=true`, or the pod is drained and was never deleted |
| `the pod did not accept the session`, a signer crash on `nil` | object-store credentials missing from the **worker** namespace |
| Workers enrol, then go quiet | the worker namespace lacks `troupe.dev/workers=true` |
| `429` from the plane behind one office address | `plane.ingress.rateLimit` is per client IP; raise `connections` first |
| `unauthorized` pulling an image in a worker namespace | the pull secret exists in `troupe-system` only |
| Worker pod `CreateContainerConfigError` | the `llm.secretRef` Secret is missing in `troupe-w-<profile>` |
| `SecretMissing: True` with the Secrets present | the operator has no RBAC on Secrets; ignore the condition |
| A profile is saved but no `WorkerProfile` appears; `not_applied`, `no_cluster` | the plane has no Kubernetes connection (`TROUPE_KUBECONFIG`, or the in-pod ServiceAccount) |
| `PolicyViolation: NoPolicy` on every profile | `policy.name` is not `default`, and nothing sets `TROUPE_POLICY_NAME` |
| Pods stay on the old image, `UpgradePending: True` | `OnDelete`: drain, then delete the pod ([profiles-and-policy.md §3](profiles-and-policy.md#3-upgrades-and-drains)) |
| Console sign-in lands on `/admin/denied`, listing the groups carried | the admin group is not among them, or `groups_claim` names the wrong claim |
| "token endpoint answered 200 without an id_token" | `openid` not in scope, or the registration cannot issue id tokens |
| Every sign-in fails before a password, `AADSTS650053` | `groups` asked for as a scope; take it out of `plane.oidc.scopes` |
| `/.well-known/jwks.json` 503; `troupe login` fails at exchange | no OpenBao credential: no static token and the projected token unreadable or refused |
| `/mcp` 401 with a valid provider token | its `aud` is none of the client id, `api://<client id>`, `<base_url>/mcp`, or the issuer differs (v1 against v2 endpoints) |
| MCP OAuth fails after consent, `AADSTS9010010` | the advertised scope and the client's `resource` name different resources; expose `<base_url>/mcp/admin` or set `plane.oidc.mcpScope` |
| Console redirect URI is `http://localhost:4000/admin/callback` | `TROUPE_BASE_URL` unset in a hand-written manifest |
| `troupe.ledger.reconcile` says `:no_gateway_configured` | `:troupe_plane, :gateway` is set by nothing here |
| Workers cannot write to object storage on Scaleway, the plane can | the plane signs for `fr-par`, workers for `us-east-1` |
| Plane replicas do not cluster during a rolling image upgrade | the Erlang cookie is baked into each image build |
| Team volumes never appear inside sessions | they are mounted on the pod, not into a session's mount table |
