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
  `test` the values come from `config/config.exs` (Postgres on `localhost:25432`, MinIO on
  `:29000`, OpenBao on `:28200` with root token `troupe-dev-root`).
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
| `TROUPE_PLANE_CONTROL_CA` | unset | the control certificate's CA, read on every pass and copied, certificates alone, into each worker namespace as the ConfigMap `troupe-plane-ca`, which pods are given as `TROUPE_PLANE_CA_PATH` to dial with TLS. Unset: pods dial in plaintext | `/etc/troupe/plane-control-ca/ca.crt`, `ca.crt` alone from `plane.controlTls.secretName`, with `plane.controlTls.enabled` |
| `TROUPE_PLANE_CONTROL_PORT` | `4001` | its port; also the worker egress rule to the plane | `plane.controlPort` |
| `TROUPE_PLANE_NAMESPACE` | `troupe-system` | namespace the operator watches | `namespace` |
| `TROUPE_BAO_ADDR` | `http://openbao.troupe-system.svc:8200` | copied into worker pods; a `.svc` host adds an in-cluster egress rule, with Cilium any other host is admitted in the `CiliumNetworkPolicy`, and without it on the port it names ([Part E](#part-e--ports-and-network-policy)) | `bao.address` |
| `TROUPE_BAO_WORKER_ROLE_PER_PROFILE` | false | gives each profile's pods `TROUPE_BAO_ROLE=troupe-worker-<profile>`, a role the installation made per profile ([roles §8](roles-and-permissions.md#8-openbao-policies)); off, pods are given none and log in as `troupe-worker` | `bao.workerRolePerProfile` |
| `TROUPE_OBJECT_ENDPOINT` | `http://minio.troupe-system.svc:9000` | copied into worker pods; same rules | `objectStore.endpoint` |
| `TROUPE_OBJECT_BUCKET` | `troupe-sessions` | copied into worker pods | `objectStore.bucket` |
| `TROUPE_OBJECT_REGION` | `us-east-1` | copied into worker pods, which sign for it | `objectStore.region` |
| `TROUPE_OBJECT_SECRET_NAME` | `troupe-object-store` | Secret in each worker namespace with `access-key-id` and `secret-access-key` | `objectStore.secretName` |
| `TROUPE_INGRESS_CLASS` | `nginx` | class of every per-pod Ingress; nginx annotations only for `nginx` | `operator.ingressClassName` |
| `TROUPE_WORKERS_TLS_SECRET` | unset | one TLS Secret shared by every pod Ingress; ignored when a cert issuer is set | `operator.tlsSecretName` |
| `TROUPE_WORKERS_CERT_ISSUER` | unset | cert-manager ClusterIssuer per pod Ingress, secret `<profile>-<ordinal>-tls` | `operator.certIssuer` |
| `TROUPE_CILIUM_AVAILABLE` | false | writes a `CiliumNetworkPolicy` with FQDN rules per profile, and drops the public 443/80 rule from the worker NetworkPolicy ([Part E](#part-e--ports-and-network-policy)); each profile's `EgressByHostname` condition says whether it applied | `operator.ciliumAvailable` |
| `TROUPE_MAX_PORTS` | `65536` | `+Q` in every worker's `ERL_FLAGS` | `operator.maxPorts` |
| `TROUPE_WORKERS_SCHEME`, `TROUPE_WORKERS_PORT` | `wss`, unset | scheme and port of the endpoint a pod advertises (kind uses `ws`, `30080`) | `operator.workersScheme`, `operator.workersPort` |
| `TROUPE_WORKER_SECCOMP_TYPE`, `TROUPE_WORKER_SECCOMP_PROFILE` | `RuntimeDefault`, unset | the worker container's `seccompProfile`: `Localhost` with the profile's path under the kubelet's seccomp directory, `RuntimeDefault` (bubblewrap cannot start, so no command runs) or `Unconfined`. Anything else, or `Localhost` without a path, stops the operator at boot ([worker-sandbox.md](worker-sandbox.md#the-workers-seccomp-profile)) | `worker.seccomp.type`, `worker.seccomp.localhostProfile` (chart default `Localhost`, `troupe/worker.json`) |
| `TROUPE_WORKER_APPARMOR_PROFILE` | unset | the AppArmor profile, loaded on the nodes, every worker container runs under (`appArmorProfile: Localhost`); unset leaves the runtime's default, which refuses bubblewrap's mounts where a node enforces AppArmor. Never `Unconfined`. A name that is not letters, digits, `.`, `_` and `-` stops the operator at boot ([worker-sandbox.md](worker-sandbox.md#the-workers-apparmor-profile)) | `worker.appArmor.enabled`, `worker.appArmor.profile` (chart default on, `troupe-worker`) |
| `TROUPE_WORKER_USER_NAMESPACES` | false | `true` gives every worker pod `hostUsers: false` and its worker container `procMount: Unmasked`, always together; off, a pod refuses every command ([worker-sandbox.md](worker-sandbox.md#the-workers-user-namespaces)) | `worker.userNamespaces` (chart default `true`; a non-boolean is refused) |
| `TROUPE_DRAIN_TIMEOUT_SECONDS` | `300` | worker `terminationGracePeriodSeconds`; **not** put in the pod's env, so the worker's own drain wait stays 300. Keep it at 300 or more ([profiles-and-policy.md §3](profiles-and-policy.md#3-upgrades-and-drains)) | `operator.drainTimeoutSeconds` |
| `TROUPE_IMAGE_PULL_SECRETS` | none | comma-separated pull secrets for worker pods | `imagePullSecrets` |
| `TROUPE_WORKER_ALLOWED_ORIGINS` | none | browser origins, written to pods as `TROUPE_ALLOWED_ORIGINS`; the chart adds the plane's own origin when it serves the GUI | `operator.workerAllowedOrigins` |
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
| `TROUPE_APP_URL` | `/app` | where `/` links to the GUI, and the `plane.app` address `/.well-known/troupe` gives `troupe-daemon open`; empty says no GUI is mounted | `plane.appUrl`, default `gui.basePath` when `gui.enabled` |
| `TROUPE_CONSOLE_URL` | `/console` | where `/`'s console door and the `/admin` page point; empty says no console is mounted, and both say the plane is administered over the admin API | `console.basePath` when `console.enabled`, else empty |
| `TROUPE_CLI_URL` | empty | where `/` links to the TUI; empty says to ask an administrator | `plane.cliUrl` |
| `TROUPE_CORS_ORIGINS` | CORS off | exact origins answered on `/rpc`, `/auth/exchange`, `/.well-known/*` | `plane.corsOrigins` |
| `TROUPE_LOG_FORMAT` | text | `"json"`: one object per line with `request_id`, `session_id` | none |
| `RELEASE_DISTRIBUTION`, `TROUPE_NODE_BASENAME`, `TROUPE_PLANE_SELECTOR` | set by chart | `name` clusters replicas through libcluster's Kubernetes topology | `plane.distribution` |
| `TROUPE_PLANE_CONTROL_PORT` | `4001` | the control listener workers dial | `plane.controlPort` |
| `TROUPE_PLANE_CONTROL_TLS_DIR` | unset | where the control port's certificate is (`tls.crt`, `tls.key`, `ca.crt`, as cert-manager writes them), read at each handshake; a registered machine enrols over TLS only and is given `ca.crt` at registration. Unset: plaintext alone, and no machine can be registered | `/etc/troupe/control-tls` from `plane.controlTls.secretName`, with `plane.controlTls.enabled` |
| `TROUPE_PLANE_CONTROL_REQUIRE_TLS` | unset: on where `TROUPE_PLANE_CONTROL_TLS_DIR` is set, off where it is not | `"true"`: the control port takes TLS only, a pod's connection included; a plaintext one is closed at its first byte, with a warning naming the peer once a minute per address and counting the rest. `"false"`: pods may dial in plaintext beside TLS, and the port warns so when it starts, as it does with no certificate. Each enrolment's log line says whether it came over TLS | `"true"` or `"false"` from `plane.controlTls.requireTls` with `plane.controlTls.enabled`, on by default from 0.20 |
| `TROUPE_GROUPS_CLAIM` | `groups` | deployed `groups_claim` | `plane.groupsClaim` |
| `TROUPE_PLATFORM_ADMIN_GROUP` | unset (nobody); the chart's is `troupe-platform-admins` | deployed `platform_admin_group` | `plane.platformAdminGroup` |
| `TROUPE_DEPLOYMENT_BUDGET_MICROS` | `0` (no ceiling) | the deployment's monthly ceiling on everything the plane spends, in millionths; the console's `platform_budget_micros` may narrow it, never raise it | `plane.deploymentBudgetMicros` |
| `TROUPE_SCIM_TOKEN` | unset | the deployment's SCIM bearer; the console can mint its own | `plane.scim.*` |
| `TROUPE_PLANE_AUDIENCE` | `troupe-plane-api` | `aud` of plane tokens | none |
| `TROUPE_PROVISIONING_MODE` | `direct` | `direct`: the console writes profiles to the cluster. `gitops`: a repository holds the `WorkerProfile`, `TroupePolicy`, `Trigger` and `GitHubApp` resources and something else applies them ([gitops.md](gitops.md)). Deployment only; in `gitops` the chart's Role drops `create` and `delete` on `WorkerProfile` and reads `Trigger` and `GitHubApp` | `plane.provisioningMode` |
| `TROUPE_GITOPS_SOURCE` | unset | the repository and path the console shows beside "Locked to gitops". Display only; the plane never reads it | `plane.gitops.source` |
| `TROUPE_KUBECONFIG` | unset | how the plane reaches Kubernetes to apply profiles and read the policy; unset, the in-pod ServiceAccount; with neither, profiles are saved and reported `not_applied` | none |
| `TROUPE_WORKER_IMAGE` | unset | the image a profile whose image is `release` runs | `worker.image.*`, tag default `appVersion` |
| `TROUPE_OIDC_ISSUER`, `TROUPE_OIDC_CLIENT_ID` | none | the identity provider and app registration (required) | `plane.oidc.issuer`, `clientId` |
| `TROUPE_OIDC_DEVICE_URL`, `TROUPE_OIDC_TOKEN_URL` | none | endpoints published to clients (required) | `plane.oidc.deviceUrl`, `tokenUrl` |
| `TROUPE_OIDC_AUTHORIZE_URL` | `<issuer>/authorize` | where the console sends the browser | `plane.oidc.authorizeUrl` |
| `TROUPE_OIDC_CLIENT_SECRET` | unset | redeems the console's authorization code; device flow works without | `plane.oidc.secretName`/`secretKey` |
| `TROUPE_OIDC_SCOPES` | `openid profile email offline_access` | scopes advertised and asked for. Not `groups`: Entra refuses it (`AADSTS650053`) | `plane.oidc.scopes` |
| `TROUPE_OIDC_MCP_SCOPE` | `<base_url>/mcp/admin` | the scope MCP clients are told to ask for | `plane.oidc.mcpScope` |
| `TROUPE_OIDC_SUBJECT_CLAIM` | `sub` | the claim that is the person, in sign-in and as SCIM's `externalId`: `oid` for Entra ID. Deployment only; switching it moves each known person once, at their next sign-in ([§ Which claim is the person](#which-claim-is-the-person)) | `plane.oidc.subjectClaim` |
| `TROUPE_BREAKGLASS_TOKEN`, `_SUBJECT`, `_LIFETIME_SECONDS` | unset, `breakglass`, `3600` | the emergency console door; unset, its routes 404 | `plane.breakglass.*` |
| `TROUPE_BAO_ADDR` | `http://openbao.troupe-system.svc:8200` | OpenBao: transit signing, destroying an erased session's key, and the assertions a person's daemon logs in with | `bao.address` |
| `TROUPE_BAO_TOKEN` | unset | a static token (development); set, no Kubernetes login is tried | `bao.tokenSecretName`/`tokenSecretKey` |
| `TROUPE_BAO_AUTH_PATH`, `TROUPE_BAO_ROLE`, `TROUPE_BAO_JWT_PATH` | `kubernetes`, `troupe-plane`, `/var/run/secrets/troupe/bao-token` | Kubernetes auth with a projected token (audience `troupe-kms`) | `bao.authPath`, `bao.planeRole` |
| `TROUPE_OBJECT_ENDPOINT`, `_BUCKET`, `_ACCESS_KEY_ID`, `_SECRET_ACCESS_KEY`, `_REGION` | unset, `troupe-sessions`, unset, unset, `us-east-1` | the object store; the plane reads it for `mix troupe.index.rebuild`, presigns the URLs a person's daemon seals a private session through, and deletes an erased private session's objects | `objectStore.*` |
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
| `TROUPE_MCP_IDENTITIES_PATH` | none | the file holding the profile's `mcpIdentities`, read again whenever a token is asked for ([profiles](profile-options.md#calling-an-mcp-server-as-the-profile)) | yes, when there are any |
| `TROUPE_KMS_TOKEN_PATH` | `/var/run/secrets/troupe/kms-token` | projected token (audience `troupe-kms`) for OpenBao | path matches |
| `TROUPE_TOKEN_PATH`, `TROUPE_HOST_SECRET` | unset | a registered machine's enrolment secret, from a file or directly ([single-machine.md](single-machine.md)) | no |
| `TROUPE_PLANE_CA_PATH`, `TROUPE_PLANE_SERVER_NAME` | unset, the host dialled | the one CA the link trusts for the plane's certificate, read at each dial: with it the link dials with TLS, and without it a machine's secret is never sent. The name the certificate must carry, for a tunnel or an address it does not name | the CA path, `/etc/troupe/plane-ca/ca.crt` from the namespace's `troupe-plane-ca` ConfigMap, with `plane.controlTls.enabled`; the name, no |
| `TROUPE_BAO_ADDR`, `TROUPE_BAO_TOKEN`, `TROUPE_BAO_MOUNT` | as the plane, unset, `secret` | KV v2 for session keys; without a token, Kubernetes auth | address only |
| `TROUPE_BAO_ROLE` | `troupe-worker` | the Kubernetes-auth role the pod logs in under; the client token is kept until shortly before its lease ends | `troupe-worker-<profile>` with `bao.workerRolePerProfile` |
| `TROUPE_OBJECT_*` | as the plane | the object store; credentials from `TROUPE_OBJECT_SECRET_NAME` | yes |
| `TROUPE_STATE_HOME` | | `/var/lib/troupe`, the pod's data volume | yes |
| `TROUPE_SMALL_MODEL` | unset | the cheap model | from `llm.smallModel` |
| `TROUPE_ALLOWED_ORIGINS` | none | browser origins the WebSocket upgrade admits besides the desktop app's own (`tauri://localhost`, `http://tauri.localhost`); none admits no page, `*` every one. A client that is not a browser sends no origin and is not asked | from `TROUPE_WORKER_ALLOWED_ORIGINS` |
| `TROUPE_BASE_URL` | unset | **the LLM endpoint** — not the plane's meaning of the name | from `llm.endpoint` |
| `TROUPE_PROVIDER`, `TROUPE_MODEL`, `TROUPE_API_KEY` | core defaults | provider, model, and the key from `llm.secretRef` (not optional: a missing Secret is `CreateContainerConfigError`). Given only with `llm.endpoint`, which is why a profile that sets them without one is refused | from `llm` |
| `TROUPE_MODEL_PRICES` | unset | JSON `models.prices`: dollars per million tokens by model, for calls the gateway does not price. Unset, such a call costs nothing on the ledger | from `llm.prices` |
| `<credentialRef>` | unset | one per MCP server with a secret, default `TROUPE_MCP_<NAME>_TOKEN` | optional `secretKeyRef` |
| `TROUPE_HTTP_PORT`, `TROUPE_HARNESS_PORT`, `TROUPE_NODE_NAME`, `TROUPE_JWKS_PATH`, `TROUPE_TOKEN_ISSUER`, `TROUPE_MAX_FRAME_BYTES`, `TROUPE_DRAIN_TIMEOUT_SECONDS` | `4000`, `4100`, unset, unset, unset, 16 MiB, `300` | ports, identity and limits the operator leaves at their defaults | no |

No variable turns the sandbox off: a worker runs every command in bubblewrap, set in its
own configuration (Decision 832).

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
| `namespace` | `troupe-system` | the namespace, and the control host `troupe-plane-control.<namespace>.svc`. Keep the default: the plane reads and writes `WorkerProfile`s in `troupe-system` whatever it says |
| `createNamespace` | `true` | the chart makes the namespace, marked to be kept on uninstall ([installing.md §2](installing.md#2-crds-then-the-chart)) |
| `imagePullSecrets` | `[]` | pull secrets on plane, Job, operator, A2A, GUI, and (via the operator) workers |
| `networkPolicy.enabled` | `true` | plane, operator, A2A and GUI NetworkPolicies |
| `operator.image.*`, `plane.image.*`, `a2a.image.*`, `gui.image.*` | `ghcr.io/it-minds/troupe-<name>` (public), tag `appVersion` | the images |
| `operator.replicas` | `1` | leader elected by Lease |
| `plane.enabled` | `true` | whether the plane is rendered at all |
| `plane.replicas` | `2` | `Recreate` when 1; PDB `minAvailable: 1` when more; more than 1 without `distribution: name` fails the render |
| `plane.ingress.enabled`, `.bodySize`, `.rateLimit.{rps,burstMultiplier,connections}` | `true`, `1m`, `20`/`5`/`100` | the plane's Ingress and its nginx limits, per client IP; `rateLimit: null` turns them off |
| `plane.ingressClassName`, `plane.certIssuer`, `plane.tlsSecretName` | `nginx`, `""`, `""` | the plane's Ingress class and TLS |
| `plane.distPort`, `plane.maxPorts` | `9100`, `65536` | Erlang distribution port; `+Q` |
| `plane.controlTls.enabled`, `.certManager`, `.issuer.{kind,name}`, `.secretName`, `.dnsNames`, `.ipAddresses`, `.requireTls` | `true`, `true`, the chart's own CA, `troupe-plane-control-tls`, `[]`, `[]`, `true` | TLS on the control port: a cert-manager `Certificate` for `troupe-plane-control` by its in-cluster names and these, from the named issuer (a CA, not ACME) or a CA the chart makes (ten years, its key kept on renewal), mounted into the plane; `certManager: false` mounts the Secret as you put it there. The operator copies its `ca.crt` into every worker namespace (`troupe-plane-ca`), so pods dial with TLS. `requireTls` closes a plaintext connection, a pod's included ([routine-tasks.md](routine-tasks.md#upgrade) before upgrading from 0.19). A string for any flag is refused, and so is `requireTls` without `enabled` |
| `*.resources` | small requests and limits | container resources; `limits.cpu` also sets `+S` |
| `gui.enabled`, `gui.replicas`, `gui.basePath` | `true`, `2`, `/app` | the GUI's Deployment, Service, Ingress on `plane.host` and NetworkPolicy. `basePath` must match the image's `TROUPE_GUI_BASE`; `/` is refused |
| `console.enabled`, `console.basePath` | `true`, `/console` | the [console](console.md)'s Ingress on `plane.host`, to the GUI's Service, which runs while either is enabled. `basePath` must match the image's `TROUPE_CONSOLE_BASE`; `/` and `gui.basePath` are refused |
| `a2a.enabled`, `a2a.host`, `a2a.ingressClassName`, `a2a.tlsSecretName` | `false`, `a2a.example.test`, `nginx`, `""` | the facade and its Ingress; enabling it also admits facade pods to the plane's HTTP port |
| `a2a.replicas`, `a2a.maxPorts` | `1`, `65536` | the facade's replicas; `+Q` |
| `policy.install`, `policy.name` | `true`, `default` | the default `TroupePolicy` (kept on uninstall) and the admission `paramRef` |
| `policy.allowedImageRepositories` | `[ghcr.io/it-minds/troupe-worker]` | see [profiles-and-policy.md §4](profiles-and-policy.md#4-troupepolicy) |
| `policy.maxReplicas`, `maxSessionsPerPod`, `maxResources` | `8`, `8`, 4 CPU / 8Gi | ceilings |
| `policy.allowedEgress`, `allowedStorageClasses`, `orgVolume` | `["*.anthropic.com", api.openai.com, github.com]`, `[standard]`, `{}` | what profiles may reach and mount |
| `policy.namespacePrefix`, `policy.workersDomain` | `troupe-w-`, `workers.example.test` | worker namespaces and hostnames. The plane is given the prefix too (`TROUPE_NAMESPACE_PREFIX`) and names an enrolling pod's profile by taking it off its namespace, so a policy installed apart from the chart (`policy.install: false`) has the same `namespacePrefix` as this value; a pod in a namespace without it is refused enrolment, and the plane's log names the prefix it expected |
| `admission.install` | `true` | the `ValidatingAdmissionPolicy` and binding (`Deny`, `failurePolicy: Fail`) |
| `worker.seccomp.install.enabled`, `.kubeletSeccompDir`, `.resources` | `true`, `/var/lib/kubelet/seccomp`, tiny | with `worker.seccomp.type: Localhost`, the ConfigMap `troupe-worker-seccomp` and the `seccomp` container of the DaemonSet `troupe-worker-profiles`, which writes `files/worker-seccomp.json` to `<kubeletSeccompDir>/<localhostProfile>` on every node ([worker-sandbox.md](worker-sandbox.md#the-workers-seccomp-profile)). A path that leaves the kubelet's directory, or has no directory of its own, is refused |
| `worker.appArmor.install.enabled`, `.resources` | `true`, tiny | with `worker.appArmor.enabled`, the ConfigMap `troupe-worker-apparmor` and the `apparmor` container of `troupe-worker-profiles`, which loads `files/worker-apparmor` into every node's kernel under `worker.appArmor.profile` ([worker-sandbox.md](worker-sandbox.md#the-workers-apparmor-profile)). A non-boolean, or a profile name that is not letters, digits, `.`, `_` and `-`, is refused |

Not chart values: worker profiles and team volumes (custom resources), the LLM gateway (a
profile field plus egress), database TLS and pool size, `TROUPE_LOG_FORMAT`,
`TROUPE_PLANE_AUDIENCE`, `TROUPE_POLICY_NAME`, and the ingress controller, cert-manager
and OpenBao themselves ([installing.md §6](installing.md#6-a-worked-example-on-managed-services)).

### The overlays

`charts/troupe/values.small.yaml` (two small nodes, one plane replica, `distribution:
none`, tighter ceilings), `charts/troupe/values.example.yaml` (two clustered replicas, the
worked example of [installing.md §6](installing.md#6-a-worked-example-on-managed-services))
and `dev/kind/values.yaml` (images tagged `dev`, `ws` on port `30080`, Dex at
`dex.localtest.me`, a static OpenBao token, workers `Unconfined`) differ from the defaults in host, OIDC
endpoints, egress and storage classes; read the files. Both copyable files point
`plane.tlsSecretName` at `troupe-plane-tls`. The example has cert-manager issue it
(`plane.certIssuer: letsencrypt`, HTTP-01); the small file leaves `plane.certIssuer`
empty, so there the plane's certificate is yours to provide. With `replicas: 1` and
`distribution: none` an upgrade is a few seconds without a plane.

---

## Part C — Platform settings

`Troupe.Plane.Settings` (`apps/troupe_plane/lib/troupe/plane/settings.ex`) is the registry
of what a platform admin may change without a rollout, stored in `platform_settings`: each
key's group, type, deployed source, fallback and when it takes effect. A stored value that
parses wins over the deployed value (the variable in Part A), which wins over the shipped
fallback; `reset` deletes the row. Reads are cached for five seconds per node. Secrets read
back as set or unset, never as values.

The groups: **administration** (`platform_admin_group`, `groups_claim`, the platform
budget), **provisioning** (`provisioning_mode` and `gitops_source`, the deployment's, shown
and not editable; a stored value from before 0.7.0 is not read), **team defaults** (a team is enabled with
the budget, its period, the idle timeout and erase-after set here; cache eviction, pins,
whether members may control sessions and a person's monthly ceiling hold for every team
at once), **sessions** (managed permission rules and MCP servers only, the default
bundle channel), **sign in** (issuer, client, endpoints, scopes — the console's **Identity
provider** card — and `subject_claim`, shown there and not editable), **client defaults**
(the provider and models people's own machines take as their organisation's defaults, and
`client_enforced`, what those machines may not go past: [Part F](client-config.md#defaults-and-limits-for-peoples-machines)),
and **deployment** keys that are shown but only change with a rollout.

`admin.settings.list`, `admin.setting.effective`, `admin.setting.put` and
`admin.setting.reset` are the methods; the console's settings pages are the same calls. A
wrong `platform_admin_group` or `groups_claim` locks everyone out at their next request, so
the console will not save the group until `admin.identity.check` has passed for it. The
versions people's clients may run are not a setting but a table of their own
(`admin.clients.get`, `admin.clients.put`; [routine-tasks.md](routine-tasks.md#client-versions)).

### Which claim is the person

Everything the plane keeps about a person is keyed on one string from their token: the
sessions they own, the teams they administer, their spend, the principals they sponsor.
`subject_claim` names the claim it is read from, `sub` by default, and SCIM's `externalId`
(or `userName`, where there is none) has to be the same value. It is the deployment's
(`TROUPE_OIDC_SUBJECT_CLAIM`, `plane.oidc.subjectClaim`), because changing it moves people
(Decision 751). A token without the claim is refused at sign-in with a reason that names
it. A provider whose `sub` already is what SCIM sends, such as Authentik with its subject
mode set to the user's UUID ([authentik.md §0](authentik.md#0-one-string-is-the-person-and-it-cannot-be-fixed-afterwards)),
keeps `sub` and sees no change.

**Entra ID.** Its `sub` is pairwise, a different string in every app registration, and no
attribute SCIM can send. Its `oid`, the user's object id, is the same in every registration
of the tenant. So set `plane.oidc.subjectClaim: oid`, and in the enterprise application's
provisioning map `externalId` from `objectId`. An id token carries `oid` when `profile` is
among the scopes, as it is by default; an access token for MCP always does.

**Switching on a plane that already has people.** At a person's first sign-in after the
rollout, one the plane does not know by the new claim but knows by the `sub` the same token
carries is moved to the new value, once. The sessions they own and the runs whose spend
counts against them move with them, and so do their ACL entries and the shares made out to
them, the teams they administer, the triggers that notify them, their recorded spend and
open reservations, and the principals they sponsor; team membership is on their row and
stays. If SCIM provisioned them under the new value first, their old row is folded into the
one SCIM made. Each move is logged and audited as `person.rekey` with the two identifiers
and nothing else from the token; the audit trail and every `*_by` keep the name they were
written with. Somebody who never signs in again is never moved.

What the key manager holds for a person (their credentials for person-mode MCP servers and
their private sessions' data keys) needs no move: it is under the name the plane fixed when
it first knew them (`troupe/people/<name>/`), kept through the move and told to pods and
daemons (Decision 755). Their servers stay connected, and a private session sealed before
the move restores on another device as before. A daemon from before Decision 755 looks
under the new subject instead and is refused, so a moved person's private sessions on that
machine stay local, unsealed, until the daemon is upgraded.

What does not move:

- A plane token minted before the move names nobody afterwards: `/rpc` answers
  `unauthenticated` until the client exchanges again, which it does within fifteen minutes.
  An open console session is turned away and signs in again.
- In `gitops` mode, a trigger's `notify` list is the repository's: change it there.

Switching back moves nobody back. People moved to `oid` are not found under their `sub`
and arrive as new people, so pick the claim before people sign in where you can.

---

## Part D — Secrets the chart expects

Troupe creates no Secrets. Each must exist before the pod that references it starts.

| Secret | Namespace | Keys | Needed |
|---|---|---|---|
| `troupe-plane-database` | `troupe-system` | `url` | always |
| `troupe-plane-secret-key-base` | `troupe-system` | `value` (≥ 64 bytes) | always |
| `troupe-plane-oidc` | `troupe-system` | `client-secret` | console sign-in, unless the client secret is saved on the console's **Sign-in** screen instead (both copyable overlays leave `plane.oidc.secretName` empty) |
| `troupe-object-store` | `troupe-system` **and every** `troupe-w-<profile>` | `access-key-id`, `secret-access-key` | the plane's index rebuild and private sessions; every session on a worker |
| break-glass (your name) | `troupe-system` | `token` | only when the door is wanted |
| `troupe-plane-scim` | `troupe-system` | `token` | the deployment's SCIM token, with `plane.scim.enabled` |
| `troupe-bao-token` | `troupe-system` | `token` | development only |
| the profile's `llm.secretRef` | `troupe-w-<profile>` | `api-key` by default | every profile with a model key |
| `troupe-mcp-<server>` | `troupe-w-<profile>` | `token` | every bundle MCP server with a `credential_ref` |
| pull secrets | `troupe-system` and every worker namespace | `.dockerconfigjson` | private registries |
| `troupe-plane-tls`, the A2A TLS secret, worker TLS | their namespaces | `tls.crt`, `tls.key` | per-pod worker certificates are written by cert-manager when `operator.certIssuer` is set |
| `troupe-plane-control-tls` | `troupe-system` | `tls.crt`, `tls.key`, `ca.crt` | written by cert-manager from the chart's `Certificate`; yours to provide with `plane.controlTls.certManager: false`. Mounted optionally: until it is there the plane registers no machine and says why, and the operator, given `ca.crt` alone, gives pods no CA yet |

The operator's `SecretMissing` condition looks in the worker namespace, but its ClusterRole
grants no verb on `secrets`, so the check cannot see a Secret that is there. Put the
Secrets where the pods read them and do not rely on the condition.

---

## Part E — Ports and network policy

| Port | Who listens | Exposed how |
|---|---|---|
| 4000 | plane HTTP (`/rpc`, `/mcp`, console, discovery) | Service `troupe-plane` → Ingress `plane.host` |
| 4000 | worker WebSocket `/v1/socket`, `/health/live`, `/health/ready` | per-pod Service → Ingress `<ordinal>-<profile>.<workersDomain>` |
| 4001 | plane control listener (NDJSON over TCP, or over TLS with the control certificate; a registered machine over TLS only) | Service `troupe-plane-control`, never an Ingress; a machine outside the cluster through a route of your own |
| 4002 | A2A facade | Service `troupe-a2a` → Ingress `a2a.host` |
| 4100 | worker raw NDJSON harness | in-pod only |
| 4369, 9100 | epmd and Erlang distribution on plane pods, when clustered | pod to pod only |
| 8080 | the GUI and the console | Service `troupe-gui` → Ingresses at `gui.basePath` and `console.basePath` on `plane.host` |

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
| `troupe-gui` | TCP 8080 from ingress namespaces | unrestricted |
| `troupe-w-<profile>` | TCP 4000 from ingress namespaces | DNS to `k8s-app=kube-dns` in `kube-system`; the plane's control port; OpenBao, object storage, the LLM endpoint and MCP servers when their hosts are `*.svc`; **without Cilium only**, `0.0.0.0/0` minus private, link-local and shared (`100.64.0.0/10`) ranges on 443 and 80, and OpenBao, object storage outside the cluster and the profile's own LLM endpoint, MCP servers and `egress.fqdns` entries on the port they name: an IP address as that one address (`/32`, `/128`), a name on another port as the same ranges on that port; a profile's endpoint at a loopback, unspecified, link-local or cloud metadata address gets nothing |
| `troupe-egress` (Cilium only) | — | `toFQDNs` for the LLM endpoint, MCP servers, `egress.fqdns` and `gitHosts`, and for OpenBao and object storage when their hosts are not `*.svc`; `toCIDR` (`/32`, `/128`) instead for any of these given as an IP address, except a profile's at a loopback, unspecified, link-local or cloud metadata address, which gets nothing; DNS to kube-dns through Cilium's DNS proxy (a `dns` rule), which is how `toFQDNs` learns addresses; `egressDeny` of `169.254.0.0/16`, `fe80::/10`, `fd00:ec2::254` and `100.100.100.200`, and the v4 ones in NAT64's `64:ff9b::/96`, whatever name resolves there, except `169.254.20.10` (NodeLocal DNSCache) and OpenBao or object storage given as an address in them |

With Cilium a worker reaches the hosts its profile names, the installation's own OpenBao
and object store, and nothing else outside the cluster; without it, any public host on 443
and 80, plus the ports its own endpoints name, and `allowedEgress` is a check at admission
and reconcile, not on the wire. What that means for each kind of endpoint, and what to do
about one a worker cannot reach, is in [profiles-and-policy.md §4](profiles-and-policy.md#4-troupepolicy).

**Ingress annotations.** Plane: 3600 s read and send timeouts, `proxy-body-size`, the rate
limits above. A2A: buffering off, 3600 s timeouts, 2m bodies. Worker (nginx only): 3600 s
timeouts, `limit-connections: 50`. The controller of the worked example
([installing.md §6](installing.md#6-a-worked-example-on-managed-services)) adds
`proxy-body-size: 16m`, so an oversized `input.send` is refused by the worker rather than
the proxy, and PROXY protocol where the load balancer sends it. The plane's JSON parser
takes 4 MiB, control frames 8 MiB, worker frames 16 MiB.

---

## Part F — The config.yaml a session reads

Every session, on a pod or on a laptop, also reads settings from `config.yaml` files and the
`TROUPE_*` variables. What an administrator needs from them is on a page of its own,
[the config.yaml a session reads](client-config.md):

- <a id="defaults-and-limits-for-peoples-machines"></a>[Defaults and limits for people's machines](client-config.md#defaults-and-limits-for-peoples-machines):
  the organisation's defaults and its enforced ceilings for people's own machines, from a
  plane's `client_defaults` and `client_enforced` or from a managed file.
