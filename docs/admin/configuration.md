# Configuration reference

Every knob, in four layers, lowest first:

1. **Environment variables**, read at boot by `config/runtime.exs` (Part A).
2. **Helm values** in `charts/troupe/values.yaml`, which render most of those variables into
   the plane, operator, A2A and GUI pods (Part B). Worker pods get theirs from the operator.
3. **Platform settings** a platform admin changes at runtime, stored in PostgreSQL (Part C).
4. **Secrets** the chart references but never creates (Part D), and the ports and labels the
   network depends on (Part E).

A session also reads `config.yaml` files: a machine's and a workspace's (Part F).

---

## Part A — Environment variables

- Everything in `config/runtime.exs` is inside `if config_env() == :prod`; in `dev` and
  `test` the values come from `config/config.exs` (Postgres on `localhost:55432`, MinIO on
  `:59000`, OpenBao on `:58200` with root token `troupe-dev-root`).
- Five `*_AUTOSTART` flags decide which supervision tree starts (operator, plane, worker,
  daemon, A2A). The image runs `/app/bin/${RELEASE_NAME} start`, `RELEASE_NAME` baked in at
  build time.
- Unset and `""` mean the same thing, because a blank Helm value renders as `""`.
- The plane's database is configured whenever `DATABASE_URL` is set, outside the autostart
  gate, so the migration Job (`TROUPE_PLANE_AUTOSTART=false`) can reach it.

### A.1 Operator (`troupe_operator`)

| Variable | Default | What it controls | Helm value |
|---|---|---|---|
| `TROUPE_OPERATOR_AUTOSTART` | unset | starts the operator (required) | fixed `"true"` |
| `TROUPE_PLANE_CONTROL_HOST` | `troupe-plane-control.troupe-system.svc` | host written into every worker's `TROUPE_PLANE_CONTROL` | `troupe-plane-control.<namespace>.svc` |
| `TROUPE_PLANE_CONTROL_PORT` | `4001` | its port; also the worker egress rule to the plane | `plane.controlPort` |
| `TROUPE_PLANE_NAMESPACE` | `troupe-system` | namespace the operator watches | `namespace` |
| `TROUPE_BAO_ADDR` | `http://openbao.troupe-system.svc:8200` | copied into worker pods; a `.svc` host adds an in-cluster egress rule | `bao.address` |
| `TROUPE_OBJECT_ENDPOINT` | `http://minio.troupe-system.svc:9000` | copied into worker pods; same rule | `objectStore.endpoint` |
| `TROUPE_OBJECT_BUCKET` | `troupe-sessions` | copied into worker pods | `objectStore.bucket` |
| `TROUPE_OBJECT_SECRET_NAME` | `troupe-object-store` | Secret in each worker namespace with `access-key-id` and `secret-access-key` | `objectStore.secretName` |
| `TROUPE_INGRESS_CLASS` | `nginx` | class of every per-pod Ingress; nginx annotations only for `nginx` | `operator.ingressClassName` |
| `TROUPE_WORKERS_TLS_SECRET` | unset | one TLS Secret shared by every pod Ingress; ignored when a cert issuer is set | `operator.tlsSecretName` |
| `TROUPE_WORKERS_CERT_ISSUER` | unset | cert-manager ClusterIssuer per pod Ingress, secret `<profile>-<ordinal>-tls` | `operator.certIssuer` |
| `TROUPE_CILIUM_AVAILABLE` | false | writes a `CiliumNetworkPolicy` with FQDN rules per profile, and drops the public 443/80 rule from the worker NetworkPolicy ([Part E](#part-e--ports-and-network-policy)); each profile's `EgressByHostname` condition says whether it applied, and is what the plane reports | `operator.ciliumAvailable` |
| `TROUPE_MAX_PORTS` | `65536` | `+Q` in every worker's `ERL_FLAGS` | `operator.maxPorts` |
| `TROUPE_WORKERS_SCHEME`, `TROUPE_WORKERS_PORT` | `wss`, unset | scheme and port of the endpoint a pod advertises (kind uses `ws`, `30080`) | `operator.workersScheme`, `operator.workersPort` |
| `TROUPE_DRAIN_TIMEOUT_SECONDS` | `300` | worker `terminationGracePeriodSeconds`; **not** put in the pod's env, so the worker's own drain wait stays 300 | `operator.drainTimeoutSeconds` |
| `TROUPE_IMAGE_PULL_SECRETS` | none | comma-separated pull secrets for worker pods | `imagePullSecrets` |
| `TROUPE_WORKER_ALLOWED_ORIGINS` | every origin | browser origins, written to pods as `TROUPE_ALLOWED_ORIGINS` | `operator.workerAllowedOrigins` |
| `TROUPE_POLICY_NAME` | `default` | which `TroupePolicy` is read | none — keep `policy.name` at `default` |
| `TROUPE_KUBE_CONTEXT`, `KUBECONFIG` | unset, `~/.kube/config` | outside a pod only; in a pod the ServiceAccount wins | none |

### A.2 Plane (`troupe_plane`)

| Variable | Default | What it controls | Helm value |
|---|---|---|---|
| `DATABASE_URL` | none | `ecto://user:pass@host:port/db`; required with autostart | `plane.database.secretName`/`secretKey` |
| `TROUPE_DB_SSL`, `TROUPE_DB_CACERT_FILE` | off, OS roots | `"true"` verifies the server (SNI = the URL's host) against the CA file | none |
| `TROUPE_POOL_SIZE` | `10` per replica | Ecto pool, plus the migration Job's | none |
| `TROUPE_PLANE_AUTOSTART` | unset | starts the plane; the migration Job sets `false` | fixed |
| `TROUPE_SECRET_KEY_BASE` | none | signs console cookies (required; the dev default is refused) | `plane.secretKeyBase.*` |
| `TROUPE_HTTP_PORT` | `4000` | listen port | `plane.httpPort` |
| `TROUPE_HOST` | `localhost` | endpoint host; issuer fallback | `plane.host` |
| `TROUPE_BASE_URL` | unset | public URL: console redirect URI, MCP resource and scope, token issuer. Effectively required; the chart always renders it | `plane.baseUrl`, default `https://<plane.host>` |
| `TROUPE_APP_URL` | `/app` | where `/` links to the GUI; empty says no GUI is mounted | `plane.appUrl`, default `gui.basePath` when `gui.enabled` |
| `TROUPE_CLI_URL` | empty | where `/` links to the TUI; empty says to ask an administrator | `plane.cliUrl` |
| `TROUPE_CORS_ORIGINS` | CORS off | exact origins answered on `/rpc`, `/auth/exchange`, `/.well-known/*` | `plane.corsOrigins` |
| `TROUPE_LOG_FORMAT` | text | `"json"`: one object per line with `request_id`, `session_id` | none |
| `RELEASE_DISTRIBUTION`, `TROUPE_NODE_BASENAME`, `TROUPE_PLANE_SELECTOR` | set by chart | `name` clusters replicas through libcluster's Kubernetes topology | `plane.distribution` |
| `TROUPE_PLANE_CONTROL_PORT` | `4001` | the control listener workers dial | `plane.controlPort` |
| `TROUPE_GROUPS_CLAIM` | `groups` | deployed `groups_claim` | `plane.groupsClaim` |
| `TROUPE_PLATFORM_ADMIN_GROUP` | unset (nobody) | deployed `platform_admin_group` | `plane.platformAdminGroup` |
| `TROUPE_SCIM_TOKEN` | unset | the deployment's SCIM bearer; the console can mint its own | `plane.scim.*` |
| `TROUPE_PLANE_AUDIENCE` | `troupe-plane-api` | `aud` of plane tokens | none |
| `TROUPE_PROVISIONING_MODE` | `direct` | `direct` or `gitops` | `plane.provisioningMode` |
| `TROUPE_KUBECONFIG` | unset | how the plane reaches Kubernetes to apply profiles and read the policy; unset, the in-pod ServiceAccount; with neither, profiles are saved and reported `not_applied` | none |
| `TROUPE_WORKER_IMAGE` | unset | the image a profile whose image is `release` runs | `worker.image.*`, tag default `appVersion` |
| `TROUPE_OIDC_ISSUER`, `TROUPE_OIDC_CLIENT_ID` | none | the identity provider and app registration (required) | `plane.oidc.issuer`, `clientId` |
| `TROUPE_OIDC_DEVICE_URL`, `TROUPE_OIDC_TOKEN_URL` | none | endpoints published to clients (required) | `plane.oidc.deviceUrl`, `tokenUrl` |
| `TROUPE_OIDC_AUTHORIZE_URL` | `<issuer>/authorize` | where the console sends the browser | `plane.oidc.authorizeUrl` |
| `TROUPE_OIDC_CLIENT_SECRET` | unset | redeems the console's authorization code; device flow works without | `plane.oidc.secretName`/`secretKey` |
| `TROUPE_OIDC_SCOPES` | `openid profile email offline_access` | scopes advertised and asked for. Not `groups`: Entra refuses it (`AADSTS650053`) | `plane.oidc.scopes` |
| `TROUPE_OIDC_MCP_SCOPE` | `<base_url>/mcp/admin` | the scope MCP clients are told to ask for | `plane.oidc.mcpScope` |
| `TROUPE_BREAKGLASS_TOKEN`, `_SUBJECT`, `_LIFETIME_SECONDS` | unset, `breakglass`, `3600` | the emergency console door; unset, its routes 404 | `plane.breakglass.*` |
| `TROUPE_BAO_ADDR` | `http://openbao.troupe-system.svc:8200` | OpenBao, for transit signing | `bao.address` |
| `TROUPE_BAO_TOKEN` | unset | a static token (development); set, no Kubernetes login is tried | `bao.tokenSecretName`/`tokenSecretKey` |
| `TROUPE_BAO_AUTH_PATH`, `TROUPE_BAO_ROLE`, `TROUPE_BAO_JWT_PATH` | `kubernetes`, `troupe-plane`, `/var/run/secrets/troupe/bao-token` | Kubernetes auth with a projected token (audience `troupe-kms`) | `bao.authPath`, `bao.planeRole` |
| `TROUPE_OBJECT_ENDPOINT`, `_BUCKET`, `_ACCESS_KEY_ID`, `_SECRET_ACCESS_KEY`, `_REGION` | unset, `troupe-sessions`, unset, unset, `us-east-1` | the object store; the plane reads it for `mix troupe.index.rebuild` | `objectStore.*` |
| `TROUPE_SCHEDULERS`, `ERL_FLAGS` | set by chart | `+S` from `limits.cpu`, `+Q` from `plane.maxPorts`, the dist port when clustered | — |

### A.3 Worker (`troupe_worker`)

Worker pods are created by the operator, so the chart sets none of these.

| Variable | Default | What it controls | Injected |
|---|---|---|---|
| `TROUPE_WORKER_AUTOSTART` | unset | starts the worker (required) | yes |
| `TROUPE_PLANE_CONTROL` | unset | `host[:port]` of the control listener | yes |
| `TROUPE_POD_ORDINAL`, `TROUPE_PROFILE` | unset | the pod's name (its worker id) and profile | yes |
| `TROUPE_WORKERS_DOMAIN`, `_SCHEME`, `_PORT` | unset, `wss`, unset | the advertised endpoint `<scheme>://<ordinal>-<profile>.<domain>[:port]/v1/socket` | yes |
| `TROUPE_SESSIONS_PER_POD` | `4` | capacity claimed at enrolment | yes |
| `TROUPE_MCP_SERVERS` | `[]` | JSON list of the profile's MCP servers | yes |
| `TROUPE_KMS_TOKEN_PATH` | `/var/run/secrets/troupe/kms-token` | projected token (audience `troupe-kms`) for OpenBao | path matches |
| `TROUPE_TOKEN_PATH`, `TROUPE_HOST_SECRET` | unset | a registered machine's enrolment secret, from a file or directly ([single-machine.md](single-machine.md)) | no |
| `TROUPE_BAO_ADDR`, `TROUPE_BAO_TOKEN`, `TROUPE_BAO_MOUNT` | as the plane, unset, `secret` | KV v2 for session keys; without a token, Kubernetes auth as `troupe-worker` | address only |
| `TROUPE_OBJECT_*` | as the plane | the object store; credentials from `TROUPE_OBJECT_SECRET_NAME`. `_REGION` is never injected, so a worker signs for `us-east-1` | all but region |
| `TROUPE_ALLOWED_ORIGINS` | every origin | origins the WebSocket upgrade admits | from `TROUPE_WORKER_ALLOWED_ORIGINS` |
| `TROUPE_BASE_URL` | unset | **the LLM endpoint** — not the plane's meaning of the name | from `llm.endpoint` |
| `TROUPE_PROVIDER`, `TROUPE_MODEL`, `TROUPE_API_KEY` | core defaults | provider, model, and the key from `llm.secretRef` (not optional: a missing Secret is `CreateContainerConfigError`) | from `llm` |
| `<credentialRef>` | unset | one per MCP server with a secret, default `TROUPE_MCP_<NAME>_TOKEN` | optional `secretKeyRef` |
| `TROUPE_HTTP_PORT`, `TROUPE_HARNESS_PORT`, `TROUPE_NODE_NAME`, `TROUPE_JWKS_PATH`, `TROUPE_TOKEN_ISSUER`, `TROUPE_MAX_FRAME_BYTES`, `TROUPE_DRAIN_TIMEOUT_SECONDS` | `4000`, `4100`, unset, unset, unset, 16 MiB, `300` | ports, identity and limits the operator leaves at their defaults | no |

### A.4 A2A facade (`troupe_a2a`)

| Variable | Default | What it controls | Helm value |
|---|---|---|---|
| `TROUPE_A2A_AUTOSTART` | unset | starts the listener | fixed `"true"` |
| `TROUPE_A2A_PUBLIC_URL` | none | origin in every agent card and artifact URI (required) | `a2a.publicUrl`, default `https://<a2a.host>` |
| `TROUPE_A2A_PORT` | `4002` | listen port | `a2a.port` |
| `TROUPE_A2A_PLANE_URL` | `http://troupe-plane.troupe-system.svc:4000` | where `/rpc` and `/auth/exchange` are reached | `a2a.planeUrl` |
| `TROUPE_A2A_MAX_STREAMS` | `200` | open SSE streams per replica; 429 beyond | `a2a.maxStreams` |
| `TROUPE_A2A_VISIBILITY` | `private` | visibility of a task's session (`private` or `team`) | `a2a.visibility` |

### A.5 Build-time

| Variable | Purpose |
|---|---|
| `MIX_ENV` | `prod` in images and native builds |
| `RELEASE` (build arg) → `RELEASE_NAME` | which server release an image runs |
| `TROUPE_REAPER_TARGETS` | which `reaper` targets to build (`all` in CI) |
| `TROUPE_REGISTRY`, `TROUPE_IMAGE_TAG`, `TROUPE_PUSH`, `TROUPE_KIND_CLUSTER` | `scripts/build-images`: where images go; `TROUPE_PUSH=true` pushes, otherwise `kind load` |

The daemon's and the TUI's own variables are in [`apps/troupe_daemon`](../../apps/troupe_daemon/README.md)
and [`clients/tui`](../../clients/tui/README.md).

---

## Part B — Helm values

An empty image tag means the chart's `appVersion`. CRDs in `charts/troupe/crds/` are
installed once by Helm and never upgraded: `kubectl apply -f charts/troupe/crds/` on every
upgrade. Values that only feed a variable in Part A are listed there; these are the rest.

| Value | Default | Becomes |
|---|---|---|
| `namespace` | `troupe-system` | the namespace, and the control host `troupe-plane-control.<namespace>.svc` |
| `imagePullSecrets` | `[]` | pull secrets on plane, Job, operator, A2A, and (via the operator) workers |
| `networkPolicy.enabled` | `true` | plane, operator, A2A and GUI NetworkPolicies |
| `operator.image.*`, `plane.image.*`, `a2a.image.*`, `gui.image.*` | `ghcr.io/objective-mj/troupe-<name>`, tag `appVersion` | the images |
| `operator.replicas` | `1` | leader elected by Lease |
| `plane.enabled` | `true` | whether the plane is rendered at all |
| `plane.replicas` | `2` | `Recreate` when 1; PDB `minAvailable: 1` when more; more than 1 without `distribution: name` fails the render |
| `plane.ingress.enabled`, `.bodySize`, `.rateLimit.{rps,burstMultiplier,connections}` | `true`, `1m`, `20`/`5`/`100` | the plane's Ingress and its nginx limits, per client IP; `rateLimit: null` turns them off |
| `plane.ingressClassName`, `plane.certIssuer`, `plane.tlsSecretName` | `nginx`, `""`, `""` | the plane's Ingress class and TLS |
| `plane.distPort`, `plane.maxPorts` | `9100`, `65536` | Erlang distribution port; `+Q` |
| `*.resources` | small requests and limits | container resources; `limits.cpu` also sets `+S` |
| `gui.enabled`, `gui.replicas`, `gui.basePath` | `true`, `2`, `/app` | the GUI's Deployment, Service, Ingress on `plane.host` and NetworkPolicy. `basePath` must match the image's `TROUPE_GUI_BASE`; `/` is refused |
| `a2a.enabled`, `a2a.host`, `a2a.ingressClassName`, `a2a.tlsSecretName` | `false`, `a2a.example.test`, `nginx`, `""` | the facade and its Ingress; enabling it also admits facade pods to the plane's HTTP port |
| `policy.install`, `policy.name` | `true`, `default` | the default `TroupePolicy` (kept on uninstall) and the admission `paramRef` |
| `policy.allowedImageRepositories` | `[ghcr.io/objective-mj/troupe-worker]` | see [profiles-and-policy.md §4](profiles-and-policy.md#4-troupepolicy) |
| `policy.maxReplicas`, `maxSessionsPerPod`, `maxResources` | `8`, `8`, 4 CPU / 8Gi | ceilings |
| `policy.allowedEgress`, `allowedStorageClasses`, `orgVolume` | `["*.anthropic.com", github.com]`, `[standard]`, `{}` | what profiles may reach and mount |
| `policy.namespacePrefix`, `policy.workersDomain` | `troupe-w-`, `workers.example.test` | worker namespaces and hostnames |
| `admission.install` | `true` | the `ValidatingAdmissionPolicy` and binding (`Deny`, `failurePolicy: Fail`) |

Not chart values: worker profiles and team volumes (custom resources), the LLM gateway (a
profile field plus egress), database TLS and pool size, `TROUPE_LOG_FORMAT`,
`TROUPE_PLANE_AUDIENCE`, `TROUPE_POLICY_NAME`, and the ingress controller, cert-manager
and OpenBao themselves (`deploy/scaleway/*`).

### The overlays

`charts/troupe/values.small.yaml` (two small nodes, one plane replica, `distribution:
none`, tighter ceilings), `charts/troupe/values.scaleway.yaml` (two clustered replicas)
and `dev/kind/values.yaml` (images tagged `dev`, `ws` on port `30080`, Dex at
`dex.localtest.me`, a static OpenBao token) differ from the defaults in registry, host,
OIDC endpoints, egress and storage classes; read the files. Both Scaleway files point
`plane.tlsSecretName` at `troupe-plane-tls` with no `plane.certIssuer`, and the shipped
`ClusterIssuer` is HTTP-01 only, so the plane's certificate is yours to provide. With
`replicas: 1` and `distribution: none` an upgrade is a few seconds without a plane.

---

## Part C — Platform settings

`Troupe.Plane.Settings` (`apps/troupe_plane/lib/troupe/plane/settings.ex`) is the registry
of what a platform admin may change without a rollout, stored in `platform_settings`: each
key's group, type, deployed source, fallback and when it takes effect. A stored value that
parses wins over the deployed value (the variable in Part A), which wins over the shipped
fallback; `reset` deletes the row. Reads are cached for five seconds per node. Secrets read
back as set or unset, never as values.

The groups: **administration** (`platform_admin_group`, `groups_claim`, the platform
budget), **provisioning** (`provisioning_mode`), **team defaults** that seed a team when it
is enabled (budgets, idle timeout, cache eviction, erase-after, pins, whether members may
control sessions), **sessions** (managed permission rules and MCP servers only, the default
bundle channel), **sign in** (issuer, client, endpoints, scopes — the console's **Identity
provider** card), **client defaults** (the provider and models people's own machines are
offered), and **deployment** keys that are shown but only change with a rollout.

`admin.settings.list`, `admin.setting.effective`, `admin.setting.put` and
`admin.setting.reset` are the methods; the console's settings pages are the same calls. A
wrong `platform_admin_group` or `groups_claim` locks everyone out at their next request, so
the console will not save the group until `admin.identity.check` has passed for it.

---

## Part D — Secrets the chart expects

Troupe creates no Secrets. Each must exist before the pod that references it starts.

| Secret | Namespace | Keys | Needed |
|---|---|---|---|
| `troupe-plane-database` | `troupe-system` | `url` | always |
| `troupe-plane-secret-key-base` | `troupe-system` | `value` (≥ 64 bytes) | always |
| `troupe-plane-oidc` | `troupe-system` | `client-secret` | console sign-in (both Scaleway overlays leave `plane.oidc.secretName` empty) |
| `troupe-object-store` | `troupe-system` **and every** `troupe-w-<profile>` | `access-key-id`, `secret-access-key` | the plane's index rebuild; every session on a worker |
| break-glass (your name) | `troupe-system` | `token` | only when the door is wanted |
| `troupe-plane-scim` | `troupe-system` | `token` | the deployment's SCIM token, with `plane.scim.enabled` |
| `troupe-bao-token` | `troupe-system` | `token` | development only |
| the profile's `llm.secretRef` | `troupe-w-<profile>` | `api-key` by default | every profile with a model key |
| `troupe-mcp-<server>` | `troupe-w-<profile>` | `token` | every bundle MCP server with a `credential_ref` |
| pull secrets | `troupe-system` and every worker namespace | `.dockerconfigjson` | private registries |
| `troupe-plane-tls`, the A2A TLS secret, worker TLS | their namespaces | `tls.crt`, `tls.key` | per-pod worker certificates are written by cert-manager when `operator.certIssuer` is set |

The operator's `SecretMissing` condition looks in the worker namespace, but its ClusterRole
grants no verb on `secrets`, so the check cannot see a Secret that is there. Put the
Secrets where the pods read them and do not rely on the condition.

---

## Part E — Ports and network policy

| Port | Who listens | Exposed how |
|---|---|---|
| 4000 | plane HTTP (`/rpc`, `/mcp`, console, discovery) | Service `troupe-plane` → Ingress `plane.host` |
| 4000 | worker WebSocket `/v1/socket`, `/health/live`, `/health/ready` | per-pod Service → Ingress `<ordinal>-<profile>.<workersDomain>` |
| 4001 | plane control listener (NDJSON over TCP) | Service `troupe-plane-control`, never an Ingress |
| 4002 | A2A facade | Service `troupe-a2a` → Ingress `a2a.host` |
| 4100 | worker raw NDJSON harness | in-pod only |
| 4369, 9100 | epmd and Erlang distribution on plane pods, when clustered | pod to pod only |
| 8080 | the GUI | Service `troupe-gui` → Ingress at `gui.basePath` on `plane.host` |

**Namespace labels.** `troupe.dev/ingress=true` goes on the ingress controller's namespace
(Helm cannot label a namespace it did not create): the plane, A2A and every worker admit
HTTP only from it, and without it a worker Ingress answers 503. `troupe.dev/workers=true`
is put on every worker namespace by the operator; the plane admits the control port only
from those and from operator pods.

| Policy | Ingress admitted | Egress |
|---|---|---|
| `troupe-plane` | HTTP from ingress namespaces (and A2A pods when enabled); control port from worker namespaces and the operator; epmd and dist from plane pods | unrestricted |
| `troupe-operator` | nothing | unrestricted |
| `troupe-a2a` | `a2a.port` from ingress namespaces | unrestricted |
| `troupe-w-<profile>` | TCP 4000 from ingress namespaces | DNS to `k8s-app=kube-dns` in `kube-system`; the plane's control port; OpenBao, object storage, the LLM endpoint and MCP servers when their hosts are `*.svc`; **without Cilium only**, `0.0.0.0/0` minus private and link-local ranges on 443 and 80 |
| `troupe-egress` (Cilium only) | — | `toFQDNs` for the LLM endpoint, MCP servers, `egress.fqdns` and `gitHosts`; DNS to kube-dns through Cilium's DNS proxy (a `dns` rule), which is how `toFQDNs` learns addresses |

With Cilium a worker reaches the hosts its profile names and nothing else outside the
cluster: Cilium admits the union of both policies, so the NetworkPolicy carries no address
block. Without Cilium a worker can reach any public host on 443 and 80; `allowedEgress` is
then a check at admission and reconcile, not on the wire.

**Ingress annotations.** Plane: 3600 s read and send timeouts, `proxy-body-size`, the rate
limits above. A2A: buffering off, 3600 s timeouts, 2m bodies. Worker (nginx only): 3600 s
timeouts, `limit-connections: 50`. The Scaleway controller adds PROXY protocol and
`proxy-body-size: 16m`, so an oversized `input.send` is refused by the worker rather than
the proxy. The plane's JSON parser takes 4 MiB, control frames 8 MiB, worker frames 16 MiB.

---

## Part F — The config.yaml a session reads

Every session, on a pod or on a laptop, also reads settings from files: the user's
`config.yaml`, the workspace's `.troupe/config.yaml` and `.troupe/config.local.yaml`, then
the `TROUPE_*` variables, merged by key and checked against one key table. The rules and
every key are in [docs/user/configuration.md](../user/configuration.md); the schema is
`protocol/schema/config/v1.json`. What an administrator needs from them:

- **A pod's provider is its profile's.** The operator writes the provider, model and key
  into the pod as `TROUPE_*` (A.3). A session on a pod never reads the keys that change
  approvals, endpoints and credentials, commands to run or readable paths from the
  project's own file, whatever the repository says; the rest of that file (models,
  budgets, the project brief) applies.
- **A file Troupe refuses fails the session's start**, and says which file, which key and
  what to write: one that is not YAML, a value of the wrong type, an enum value nobody
  knows, both spellings of one setting, or a file written for a newer Troupe.
- **On a laptop**, a workspace's files set those keys only once the user's own file lists
  the workspace under `trusted_workspaces`, which `troupe config trust` in the workspace
  adds. `troupe config pull` writes the plane's
  client defaults (Part C) into the user's file through the daemon, in the current
  spellings.
- **A repository can check its own file** in CI: `troupe config validate
  .troupe/config.yaml` exits non-zero on any problem, an unknown key included.
