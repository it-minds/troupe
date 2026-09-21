# Configuration reference

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).
>
> Commit `4083b1f` (`TROUPE_OIDC_MCP_SCOPE`, `plane.oidc.mcpScope`) landed while this track was being written and is covered; every line number below is from that tree, whose working copy was otherwise clean.

> **Re-audited 2026-09-14.** The client apps were deleted and this repository now ships
> only its four images and the chart. `TROUPE_CLI_URL` / `plane.cliUrl` are new; the
> client-side variables in A.2 are kept for client authors and no longer read by anything
> here.

This is the one place every knob is listed. Four layers, lowest first:

1. **Environment variables**, read at boot by `config/runtime.exs` (Part A). There is no `.env.example` in the repository ([AUDIT.md §1.5](../AUDIT.md)); the list was derived from `config/runtime.exs`, `config/config.exs` and every `System.get_env` call under `apps/*/lib`.
2. **Helm values** in `charts/troupe/values.yaml`, which render most of those variables into the plane, operator and A2A pods (Part B). Worker pods get theirs from the operator, not from the chart.
3. **Platform settings** a platform admin changes at runtime, stored in PostgreSQL and layered over the deployed value (Part C).
4. **Secrets** the chart references but never creates (Part D), and the ports and labels the network depends on (Part E).

How images and the chart reach a cluster is in [../developer/deployment.md](../developer/deployment.md); step lists for common changes are in [routine-tasks.md](routine-tasks.md).

---

## Part A — Environment variables

### How a release reads them

- Everything in `config/runtime.exs` is inside `if config_env() == :prod` (`config/runtime.exs:94`). In `dev` and `test` the values come from `config/config.exs` instead (`config/config.exs:61-114`: a Postgres on `localhost:55432`, MinIO on `:59000`, OpenBao on `:58200` with root token `troupe-dev-root`).
- There is no `RELEASE_NAME` switch. Five `*_AUTOSTART` flags decide which supervision tree starts: `TROUPE_OPERATOR_AUTOSTART` (`runtime.exs:98`), `TROUPE_PLANE_AUTOSTART` (`:182`), `TROUPE_WORKER_AUTOSTART` (`:347`), `TROUPE_DAEMON_AUTOSTART` (`:411`), `TROUPE_A2A_AUTOSTART` (`:415`). The image's entrypoint runs `/app/bin/${RELEASE_NAME} start` where `RELEASE_NAME` is baked in at build time (`docker/Dockerfile:74-78`).
- An unset variable and one set to `""` mean the same thing wherever `presence.()` is applied (`runtime.exs:3-9`), because a blank Helm value renders as `""`.
- The plane's database block is configured whenever `DATABASE_URL` is set, *outside* the autostart gate, so the migration Job (which runs with `TROUPE_PLANE_AUTOSTART=false`) can reach the repo (`runtime.exs:139-180`; `charts/troupe/templates/plane-deployment.yaml:92-95`).

Column key: **Default** is what the code uses when the variable is absent; **Req.** says whether the release refuses to start without it; **Helm** names the value or template that sets it, or "no Helm value".

### A.1 Operator release (`troupe_operator`)

| Variable | Default | Req. | What it controls | Helm | Read at |
|---|---|---|---|---|---|
| `TROUPE_OPERATOR_AUTOSTART` | unset (tree does not start) | yes | starts the operator supervision tree | fixed `"true"`, `operator-deployment.yaml:61-62` | `runtime.exs:98` |
| `TROUPE_PLANE_CONTROL_HOST` | `troupe-plane-control.troupe-system.svc` | no | host written into every worker pod's `TROUPE_PLANE_CONTROL` | `troupe-plane-control.<namespace>.svc`, `operator-deployment.yaml:65-66` | `runtime.exs:100-101`; `resources.ex:566-569` |
| `TROUPE_PLANE_CONTROL_PORT` | `4001` | no | port of the above; also the worker NetworkPolicy egress rule to the plane namespace | `plane.controlPort`, `operator-deployment.yaml:67-68` | `runtime.exs:102`; `resources.ex:318` |
| `TROUPE_PLANE_NAMESPACE` | `troupe-system` | no | namespace the operator watches; where `SecretMissing` looks for secrets; the namespace named in the worker egress rule | `namespace`, `operator-deployment.yaml:63-64` | `runtime.exs:103`; `supervisor.ex:46`; `reconciler.ex:185`; `resources.ex:314` |
| `TROUPE_BAO_ADDR` | `http://openbao.troupe-system.svc:8200` | no | copied into worker pods; if it names a `.svc` host an in-cluster NetworkPolicy egress rule is added | `bao.address`, `operator-deployment.yaml:90-91` | `runtime.exs:104`; `resources.ex:342,570` |
| `TROUPE_OBJECT_ENDPOINT` | `http://minio.troupe-system.svc:9000` | no | copied into worker pods; same in-cluster rule | `objectStore.endpoint`, `operator-deployment.yaml:92-93` | `runtime.exs:105-106`; `resources.ex:342,571` |
| `TROUPE_OBJECT_BUCKET` | `troupe-sessions` | no | copied into worker pods | `objectStore.bucket`, `operator-deployment.yaml:94-95` | `runtime.exs:107`; `resources.ex:572` |
| `TROUPE_INGRESS_CLASS` | `nginx` | no | `ingressClassName` of every per-pod Ingress; nginx annotations are written only for `nginx` | `operator.ingressClassName`, `operator-deployment.yaml:96-97` | `runtime.exs:108`; `resources.ex:187,253` |
| `TROUPE_WORKERS_TLS_SECRET` | unset | no | one TLS Secret shared by every pod Ingress (a wildcard); ignored when a cert issuer is set | `operator.tlsSecretName`, `operator-deployment.yaml:98-99` | `runtime.exs:109`; `resources.ex:233-237` |
| `TROUPE_WORKERS_CERT_ISSUER` | unset | no | cert-manager ClusterIssuer annotation on every pod Ingress, with per-pod secret `<profile>-<ordinal>-tls` | `operator.certIssuer`, `operator-deployment.yaml:100-101` | `runtime.exs:110`; `resources.ex:229-231,246` |
| `TROUPE_CILIUM_AVAILABLE` | unset (false) | no | `"true"` makes the operator write a `CiliumNetworkPolicy` with FQDN rules per profile | `operator.ciliumAvailable`, `operator-deployment.yaml:102-103` | `runtime.exs:111`; `resources.ex:385-404` |
| `TROUPE_MAX_PORTS` | `65536` | no | `+Q` in every worker pod's `ERL_FLAGS` | `operator.maxPorts`, `operator-deployment.yaml:71-72` | `runtime.exs:112`; `resources.ex:554` |
| `TROUPE_OBJECT_SECRET_NAME` | `troupe-object-store` | no | name of the Secret in each worker namespace holding `access-key-id` and `secret-access-key` | `objectStore.secretName`, `operator-deployment.yaml:69-70` | `runtime.exs:113-114`; `resources.ex:597-610` |
| `TROUPE_WORKERS_SCHEME` | `wss` | no | scheme of the endpoint a pod advertises | `operator.workersScheme`, `operator-deployment.yaml:73-74` | `runtime.exs:115`; `resources.ex:565` |
| `TROUPE_WORKERS_PORT` | unset | no | port appended to the advertised endpoint (kind uses `30080`) | `operator.workersPort`, `operator-deployment.yaml:75-78` | `runtime.exs:116`; `resources.ex:612-616` |
| `TROUPE_DRAIN_TIMEOUT_SECONDS` | `300` | no | `terminationGracePeriodSeconds` of worker pods. **Not** copied into the pod's env, so the worker's own drain timeout stays at its default 300 (see A.7) | `operator.drainTimeoutSeconds`, `operator-deployment.yaml:104-105` | `runtime.exs:117-118`; `resources.ex:493` |
| `TROUPE_IMAGE_PULL_SECRETS` | `""` (none) | no | comma-separated Secret names put on every worker pod as `imagePullSecrets` | `imagePullSecrets` joined, `operator-deployment.yaml:84-85` | `runtime.exs:121-126`; `resources.ex:497-501` |
| `TROUPE_WORKER_ALLOWED_ORIGINS` | `""` (every origin) | no | comma-separated browser origins, written to pods as `TROUPE_ALLOWED_ORIGINS` | `operator.workerAllowedOrigins`, `operator-deployment.yaml:88-89` | `runtime.exs:129-134`; `resources.ex:589-593` |
| `TROUPE_POLICY_NAME` | `default` | no | which `TroupePolicy` the reconciler and the delete handler read | **no Helm value** — `policy.name` names the CR but does not set this variable (see A.7) | `reconciler.ex:310`; `controller/worker_profile.ex:41` |
| `TROUPE_KUBE_CONTEXT` | unset | no | kubeconfig context, outside a pod only | no Helm value | `conn.ex:49` |
| `KUBECONFIG` | `~/.kube/config` | no | kubeconfig path, outside a pod only; in a pod the ServiceAccount token wins | no Helm value | `conn.ex:45-58` |
| `POD_NAME` | set by chart | — | downward-API pod name; not read by Troupe code under `apps/*/lib` (presumed consumed by Bonny's leader election). Unconfirmed. | `operator-deployment.yaml:106-107` | — |
| `TROUPE_SCHEDULERS`, `ERL_FLAGS` | set by chart | — | `+S` from `limits.cpu`, `+Q` from `operator.maxPorts`; read by the BEAM, not by Troupe | `operator-deployment.yaml:53-60` | — |

The module paths above are `apps/troupe_operator/lib/troupe/operator/`. `Troupe.Operator.Settings` (`settings.ex:11-55`) carries the same defaults as `runtime.exs`, so a variable missing from both is not possible.

### A.2 Plane release (`troupe_plane`)

| Variable | Default | Req. | What it controls | Helm | Read at |
|---|---|---|---|---|---|
| `DATABASE_URL` | none | yes when `TROUPE_PLANE_AUTOSTART=true` (`runtime.exs:183-190`) | `ecto://user:pass@host:port/db`; configured whenever set so the migration Job works | `plane.database.secretName` / `secretKey` as `secretKeyRef`, `plane-deployment.yaml:87-91` (Job) and `:278-282` | `runtime.exs:143,176-179` |
| `TROUPE_DB_SSL` | unset (no TLS) | no | `"true"` turns on `verify_peer` TLS with SNI set to the URL's host and HTTPS wildcard matching | **no Helm value** | `runtime.exs:150-169` |
| `TROUPE_DB_CACERT_FILE` | unset → OS roots (`:public_key.cacerts_get()`) | no | CA file to verify the database against | **no Helm value** | `runtime.exs:154-158` |
| `TROUPE_POOL_SIZE` | `10` **per replica** | no | Ecto pool size; two replicas hold twenty connections plus the migration's | **no Helm value** | `runtime.exs:171-178` |
| `TROUPE_PLANE_AUTOSTART` | unset | yes for a serving plane | starts the plane; the migration Job sets it `false` | `"true"` at `plane-deployment.yaml:207-208`; `"false"` at `:94-95` | `runtime.exs:182` |
| `TROUPE_SECRET_KEY_BASE` | none | yes (`runtime.exs:192-201`) | signs console session cookies; the dev default in `config.exs:52` is refused | `plane.secretKeyBase.secretName` / `secretKey`, `plane-deployment.yaml:283-287` | `runtime.exs:193,222` |
| `TROUPE_HTTP_PORT` | `4000` | no | Bandit listen port | `plane.httpPort`, `plane-deployment.yaml:209-210` | `runtime.exs:225` |
| `TROUPE_HOST` | `localhost` | no | Endpoint URL host; fallback for the token issuer when `TROUPE_BASE_URL` is unset | `plane.host`, `plane-deployment.yaml:213-214` | `runtime.exs:227,257` |
| `TROUPE_BASE_URL` | unset | effectively yes for console and MCP (see A.7) | `:base_url` (console redirect URI, RFC 9728 `resource`, default MCP scope, third accepted audience) and, with the `https://<host>` fallback, `:issuer` of plane tokens | `plane.baseUrl` defaulting to `https://<plane.host>`, `plane-deployment.yaml:215-216` | `runtime.exs:255-257,313-314` |
| `TROUPE_OIDC_SCOPES` | unset → `openid profile email offline_access` | no | comma- or space-separated scopes advertised at `/.well-known/troupe` and used by the console's authorize request | `plane.oidc.scopes` joined with `,`, rendered only when non-empty, `plane-deployment.yaml:235-239` | `runtime.exs:259-263,331`; `web/router.ex:59,69`; `web/admin_auth.ex:321` |
| `TROUPE_OIDC_MCP_SCOPE` | unset → `<base_url>/mcp/admin` | no | the scope the RFC 9728 document tells an MCP client to ask for (plus `offline_access`); set only where the app registration exposes the MCP scope under another name (commit `4083b1f`) | `plane.oidc.mcpScope`, rendered only when non-empty, `plane-deployment.yaml:240-244` | `runtime.exs:332-335`; `web/router.ex:311-338` |
| `TROUPE_APP_URL` | `/app` | no | where the index page at `/` links to the graphical client; empty renders no app door and the page says no GUI is mounted | `plane.appUrl`, `plane-deployment.yaml:220-221` | `runtime.exs:347`; `web/router.ex:52-58,346-351`; `web/index.ex` |
| `TROUPE_CLI_URL` | (empty) | no | where the index page at `/` links to the terminal client. Nothing here builds or serves one, so there is no default worth guessing: empty makes the page say to ask an administrator rather than link at a download that is not there | `plane.cliUrl`, `plane-deployment.yaml` | `runtime.exs`; `web/router.ex` `cli_url/0`; `web/index.ex` `binary_step/1` |
| `TROUPE_CORS_ORIGINS` | `""` (CORS off) | no | exact browser origins answered on `/rpc`, `/auth/exchange`, `/.well-known/*`; a separate GUI needs its origin here | `plane.corsOrigins` joined, `plane-deployment.yaml:219-220` | `runtime.exs:265-270,315` |
| `TROUPE_LOG_FORMAT` | unset (Elixir default formatter) | no | `"json"` installs `Troupe.Plane.LogFormatter` on the default handler, one JSON object per line with `request_id` and `session_id` | **no Helm value** | `runtime.exs:274-277`; `log_formatter.ex:22` |
| `RELEASE_DISTRIBUTION` | set by chart | — | `"name"` enables the libcluster Kubernetes topology; anything else runs unclustered | `plane.distribution`, `plane-deployment.yaml:261-262`; `"none"` on the Job (`:96-97`) | `runtime.exs:293` |
| `TROUPE_NODE_BASENAME` | `troupe-plane` | no | libcluster node basename | fixed when `distribution: name`, `plane-deployment.yaml:270-271` | `runtime.exs:301` |
| `TROUPE_PLANE_SELECTOR` | `app.kubernetes.io/component=plane` | no | label selector libcluster applies to *pods* (`kubernetes_ip_lookup_mode: :pods`) | `app.kubernetes.io/component=plane,app.kubernetes.io/instance=<release>`, `plane-deployment.yaml:274-275` | `runtime.exs:299-303` |
| `TROUPE_PLANE_NAMESPACE` | `troupe-system` | no | namespace libcluster searches | `namespace`, `plane-deployment.yaml:221-222` | `runtime.exs:304` |
| `POD_IP`, `RELEASE_NODE` | set by chart | — | `troupe-plane@<pod ip>`; read by the release scripts, not by Troupe | `plane-deployment.yaml:267-273` | — |
| `TROUPE_PLANE_CONTROL_PORT` | `4001` | no | the `gen_tcp` control listener workers dial | `plane.controlPort`, `plane-deployment.yaml:211-212` | `runtime.exs:316` |
| `TROUPE_GROUPS_CLAIM` | `groups` | no | deployed value of the `groups_claim` setting | `plane.groupsClaim`, `plane-deployment.yaml:227-228` | `runtime.exs:317`; `settings.ex:60-70` |
| `TROUPE_SCIM_TOKEN` | unset (SCIM answers 401) | no | static bearer the IdP presents on `/scim/v2/*` | `plane.scim.secretName` / `secretKey` when `plane.scim.enabled`, `plane-deployment.yaml:296-302` | `runtime.exs:318`; `web/router.ex:410-416` |
| `TROUPE_PLATFORM_ADMIN_GROUP` | unset (nobody is platform admin) | no | deployed value of the `platform_admin_group` setting | `plane.platformAdminGroup`, `plane-deployment.yaml:225-226` | `runtime.exs:319`; `settings.ex:50-59` |
| `TROUPE_PLANE_AUDIENCE` | `troupe-plane-api` | no | `aud` of plane tokens; `/rpc` and `/mcp` verify against it | **no Helm value** | `runtime.exs:320`; `oidc.ex:351`; `web/router.ex:230,428` |
| `TROUPE_PROVISIONING_MODE` | `direct` | no | `direct` or `gitops`, converted with `String.to_existing_atom/1`; deployed value of the `provisioning_mode` setting | `plane.provisioningMode`, `plane-deployment.yaml:223-224` | `runtime.exs:321-322` |
| `TROUPE_WORKER_IMAGE` | unset (`release` is refused) | no | the worker image a profile whose image is `release` runs; the plane writes those profiles again at start when their `WorkerProfile` carries another ([profiles-and-policy.md §9](profiles-and-policy.md#9-troupe-admin-profile-)) | `worker.image.repository`:`worker.image.tag`, the tag defaulting to the chart's `appVersion`, `plane-deployment.yaml` | `runtime.exs`; `provision.ex` `release_image/0`; `fleet/release_image.ex` |
| `TROUPE_OIDC_ISSUER` | none | yes (`runtime.exs:206-218,324`) | the identity provider; discovery is fetched from `<issuer>/.well-known/openid-configuration` | `plane.oidc.issuer`, `plane-deployment.yaml:229-230` | `oidc.ex:151,207` |
| `TROUPE_OIDC_CLIENT_ID` | none | yes | the app registration; also the accepted audiences `client_id`, `api://<client_id>` and, with a base URL, `<base_url>/mcp` | `plane.oidc.clientId`, `plane-deployment.yaml:231-232` | `runtime.exs:325`; `oidc.ex:107-120` |
| `TROUPE_OIDC_CLIENT_SECRET` | unset | no — console login fails without it, CLI device flow does not | redeems the authorization code at `/admin/callback` | `plane.oidc.secretName` / `secretKey`, `optional: true`, `plane-deployment.yaml:288-295` | `runtime.exs:326`; `web/admin_auth.ex:138` |
| `TROUPE_OIDC_AUTHORIZE_URL` | unset → `<issuer>/authorize` | no | where the console sends the browser | `plane.oidc.authorizeUrl`, `plane-deployment.yaml:233-234` | `runtime.exs:327`; `web/admin_auth.ex:325` |
| `TROUPE_OIDC_DEVICE_URL` | none | yes | device-authorization endpoint published to clients | `plane.oidc.deviceUrl`, `plane-deployment.yaml:245-246` | `runtime.exs:336`; `web/router.ex:67` |
| `TROUPE_OIDC_TOKEN_URL` | none | yes | token endpoint published to clients and used by the console | `plane.oidc.tokenUrl`, `plane-deployment.yaml:247-248` | `runtime.exs:337`; `web/admin_auth.ex:133` |
| `TROUPE_BREAKGLASS_TOKEN` | unset (no door; routes 404) | no | the break-glass token | `plane.breakglass.secretName` / `secretKey`, rendered only when `secretName` is set, `plane-deployment.yaml:303-311` | `runtime.exs:239`; `breakglass.ex:66,159` |
| `TROUPE_BREAKGLASS_SUBJECT` | `breakglass` | no | actor name written to the audit log | `plane.breakglass.subject`, `plane-deployment.yaml:312-313` | `runtime.exs:240`; `breakglass.ex:153-157` |
| `TROUPE_BREAKGLASS_LIFETIME_SECONDS` | `3600` | no | how long a break-glass cookie is honoured | `plane.breakglass.lifetimeSeconds`, `plane-deployment.yaml:314-315` | `runtime.exs:241-242`; `breakglass.ex:143-148` |
| `TROUPE_BAO_ADDR` | `http://openbao.troupe-system.svc:8200` | no | OpenBao address for transit signing | `bao.address`, `plane-deployment.yaml:249-250` | `runtime.exs:245`; `tokens.ex:201-206` |
| `TROUPE_BAO_TOKEN` | unset | no | a static OpenBao token; when set, no Kubernetes-auth login is attempted and a 403 is not retried | `bao.tokenSecretName` / `tokenSecretKey`, `plane-deployment.yaml:331-337` | `runtime.exs:246`; `tokens/credential.ex:49-54,165-173` |
| `TROUPE_BAO_AUTH_PATH` | `kubernetes` | no | OpenBao Kubernetes auth mount | `bao.authPath`, `plane-deployment.yaml:251-252` | `runtime.exs:247`; `tokens/credential.ex:120` |
| `TROUPE_BAO_ROLE` | `troupe-plane` | no | the auth role the plane logs in under | `bao.planeRole`, `plane-deployment.yaml:253-254` | `runtime.exs:248`; `tokens/credential.ex:121` |
| `TROUPE_BAO_JWT_PATH` | `/var/run/secrets/troupe/bao-token` | no | projected ServiceAccount token (audience `troupe-kms`, 3600 s) presented to OpenBao | fixed when no static token, `plane-deployment.yaml:344-345,373-382` | `runtime.exs:249`; `tokens/credential.ex:119` |
| `TROUPE_OBJECT_ENDPOINT` | unset (no object store configured) | no — needed for `mix troupe.index.rebuild` | S3 endpoint | `objectStore.endpoint`, `plane-deployment.yaml:255-256` | `runtime.exs:75-89,340-342` |
| `TROUPE_OBJECT_BUCKET` | `troupe-sessions` | no | bucket | `objectStore.bucket`, `plane-deployment.yaml:257-258` | `runtime.exs:83` |
| `TROUPE_OBJECT_ACCESS_KEY_ID` | unset | no | SigV4 key id | `objectStore.secretName` key `access-key-id`, `optional: true`, `plane-deployment.yaml:318-323` | `runtime.exs:84` |
| `TROUPE_OBJECT_SECRET_ACCESS_KEY` | unset | no | SigV4 secret | `objectStore.secretName` key `secret-access-key`, `optional: true`, `plane-deployment.yaml:324-329` | `runtime.exs:85` |
| `TROUPE_OBJECT_REGION` | `us-east-1` | no | SigV4 region. Rendered for the plane only; the operator never passes it to workers (see A.7) | `objectStore.region`, `plane-deployment.yaml:259-260` | `runtime.exs:86` |
| `TROUPE_POLICY_NAME` | `default` | no | which `TroupePolicy` the plane reads for fast-feedback checks | **no Helm value** | `cluster_policy.ex:94-97` |
| `TROUPE_KUBE_CONTEXT`, `KUBECONFIG` | unset / `~/.kube/config` | no | used by enrolment's TokenReview connection only outside a pod | no Helm value | `enrolment.ex:169-185` |
| `TROUPE_SCHEDULERS`, `ERL_FLAGS` | set by chart | — | `+S` from `limits.cpu`, `+Q` from `plane.maxPorts`, and `inet_dist_listen_min/max` pinned to `plane.distPort` when clustered | `plane-deployment.yaml:195-206`; Job `:85-86` | — |

Module paths above are `apps/troupe_plane/lib/troupe/plane/`. Application-environment keys that nothing in `config/` sets — `:k8s_conn`, `:gitops`, `:policy`, `:egress_allowed`, `:namespace`, `:namespace_prefix`, `:lease_timeout_ms`, `:disk_high_watermark`, `:disk_low_watermark`, `:gateway`, `:reconcile_threshold_micros`, `:transit[:mount]`, `:transit[:key]`, `:oidc[:plane_name]` — are listed in [AUDIT.md §3.1](../AUDIT.md) and the plane audit notes; the consequences of `:k8s_conn` and `:gateway` being unset are in [profiles-and-policy.md](profiles-and-policy.md) and [integrations.md](integrations.md).

### A.3 Worker release (`troupe_worker`)

Worker pods are created by the operator, so **the chart sets none of these**. The "Injected by" column names the line in `apps/troupe_operator/lib/troupe/operator/resources.ex` that writes the variable into the pod spec, or says it is not injected.

| Variable | Default | Req. | What it controls | Injected by | Read at |
|---|---|---|---|---|---|
| `TROUPE_WORKER_AUTOSTART` | unset | yes | starts the worker tree and sets `:troupe_core, usage_sink: Troupe.Worker.Usage` | `resources.ex:558` | `runtime.exs:347-353` |
| `TROUPE_PLANE_CONTROL` | unset (no plane link is started) | yes for a pod | `host[:port]` of the control listener; port defaults to 4001 | `resources.ex:566-569` | `runtime.exs:11-21,348,383` |
| `TROUPE_POD_ORDINAL` | unset | yes for a pod | the pod's own name (downward API); its trailing integer is the ordinal, the whole string is the `worker_id` tokens are addressed to | `resources.ex:575-578` | `runtime.exs:32-40,370` |
| `TROUPE_PROFILE` | unset | yes for a pod | profile name; part of the advertised endpoint | `resources.ex:559` | `runtime.exs:33,357` |
| `TROUPE_WORKERS_DOMAIN` | unset | yes for a pod | domain of the advertised endpoint `<scheme>://<ordinal>-<profile>.<domain>[:port]/v1/socket` | `resources.ex:564` | `runtime.exs:34,59-64` |
| `TROUPE_WORKERS_SCHEME` | `wss` | no | scheme of that endpoint | `resources.ex:565` | `runtime.exs:60` |
| `TROUPE_WORKERS_PORT` | unset | no | port of that endpoint | `resources.ex:612-616` (only when set) | `runtime.exs:61` |
| `TROUPE_SESSIONS_PER_POD` | `4` | no | the capacity claimed at enrolment and the pod's own limit | `resources.ex:573` | `runtime.exs:43,363` |
| `TROUPE_NODE_NAME` | unset | no | node name claimed at enrolment | **not injected** | `runtime.exs:46-48` |
| `TROUPE_HTTP_PORT` | `4000` | no | WebSocket and health port | **not injected** (the operator hard-codes 4000 in Services, Ingresses and probes, `resources.ex:152,175,199,508,525`) | `runtime.exs:361` |
| `TROUPE_HARNESS_PORT` | `4100` | no | raw NDJSON listener | **not injected**; no Service exposes it | `runtime.exs:362` |
| `TROUPE_MCP_SERVERS` | `"[]"` | no | JSON list of the profile's MCP servers, same shape a bundle carries | `resources.ex:668-698` | `runtime.exs:367` |
| `TROUPE_DRAIN_TIMEOUT_SECONDS` | `300` | no | how long a drain waits before cancelling | **not injected** (see A.7) | `runtime.exs:368-369` |
| `TROUPE_JWKS_PATH` | unset | no | on-disk cache of the plane's JWKS | **not injected**; the plane pushes `jwks.updated` on enrol instead | `runtime.exs:375` |
| `TROUPE_KMS_TOKEN_PATH` | `/var/run/secrets/troupe/kms-token` | no | projected token (audience `troupe-kms`) presented to OpenBao | path matches the projected volume, `resources.ex:717-723,757` | `runtime.exs:378-379` |
| `TROUPE_TOKEN_ISSUER` | unset (issuer not checked) | no | expected `iss` of session tokens | **not injected** | `runtime.exs:380` |
| `TROUPE_BAO_ADDR` | `http://openbao.troupe-system.svc:8200` | no | KV v2 address for session keys | `resources.ex:570` | `runtime.exs:385`; `kms/open_bao.ex:121` |
| `TROUPE_BAO_TOKEN` | unset → Kubernetes auth as role `troupe-worker` | no | static OpenBao token | **not injected** | `runtime.exs:386`; `kms/open_bao.ex:129-142` |
| `TROUPE_BAO_MOUNT` | `secret` | no | KV v2 mount | **not injected** | `runtime.exs:387`; `kms/open_bao.ex:124` |
| `TROUPE_OBJECT_ENDPOINT` | unset | yes for sessions | S3 endpoint | `resources.ex:571` | `runtime.exs:75-89,390-392` |
| `TROUPE_OBJECT_BUCKET` | `troupe-sessions` | no | bucket | `resources.ex:572` | `runtime.exs:83` |
| `TROUPE_OBJECT_ACCESS_KEY_ID` | unset | yes for sessions | from Secret `TROUPE_OBJECT_SECRET_NAME` key `access-key-id`, `optional: true` | `resources.ex:597-610` | `runtime.exs:84` |
| `TROUPE_OBJECT_SECRET_ACCESS_KEY` | unset | yes for sessions | key `secret-access-key`, `optional: true` | `resources.ex:597-610` | `runtime.exs:85` |
| `TROUPE_OBJECT_REGION` | `us-east-1` | no | SigV4 region. **Never injected**, so a worker always signs for `us-east-1` whatever `objectStore.region` says | — | `runtime.exs:86` |
| `TROUPE_MAX_FRAME_BYTES` | `16777216` | no | largest WebSocket frame accepted before a token is seen | **not injected** | `runtime.exs:401` |
| `TROUPE_ALLOWED_ORIGINS` | `""` (every origin) | no | browser origins the WebSocket upgrade admits | `resources.ex:589-593` from `TROUPE_WORKER_ALLOWED_ORIGINS` | `runtime.exs:402-406` |
| `TROUPE_BASE_URL` | unset | no | **the LLM endpoint** (`llm.endpoint`) — a different meaning from the plane's | `resources.ex:623` | `apps/troupe_core/lib/troupe/config.ex:139-152` |
| `TROUPE_PROVIDER` | unset (core default) | no | `anthropic`, `openai` or `fake`; the CRD defaults `llm.provider` to `openai` | `resources.ex:624` | `config.ex:141` |
| `TROUPE_MODEL` | unset | no | `llm.model` | `resources.ex:626,649-650` | `config.ex:143` |
| `TROUPE_API_KEY` | unset | no | `secretKeyRef` to `llm.secretRef` (key default `api-key`), **not** optional — a missing Secret is a pod stuck in `CreateContainerConfigError` | `resources.ex:629-644` | `config.ex:142` |
| `TROUPE_FAKE_SCRIPT` | unset | no | script for the fake provider | not injected | `config.ex:144` |
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` | unset | no | provider fallbacks when no `TROUPE_API_KEY` | not injected | `llm/providers/anthropic.ex:264`; `llm/providers/openai.ex:312` |
| `TROUPE_SMALL_MODEL` | — | — | injected from `llm.smallModel` but **read by nothing** | `resources.ex:627` | — |
| `TROUPE_NAMESPACE` | — | — | injected but **read by nothing** | `resources.ex:560-563` | — |
| `TROUPE_CONFIG_CHANNEL` | — | — | injected from `configBundleChannel` but **read by nothing** | `resources.ex:574` | — |
| `<credentialRef>` (default `TROUPE_MCP_<NAME>_TOKEN`) | unset | no | one per MCP server with a `secretRef`; `secretKeyRef` `optional: true` | `resources.ex:668-677`; name from `worker_profile.ex:62-68` | `apps/troupe_protocol/lib/troupe/mcp/server.ex:81-88` |
| `HOSTNAME` | set by Kubernetes | — | pod name reported in status and dormancy messages | — | `worker/plane/commands.ex:182`; `worker/session/manager.ex:260` |
| `TROUPE_SCHEDULERS`, `ERL_FLAGS` | injected | — | `+S` from `limits.cpu`, `+Q` from `TROUPE_MAX_PORTS` | `resources.ex:542-555` | — |

### A.4 A2A facade release (`troupe_a2a`)

| Variable | Default | Req. | What it controls | Helm | Read at |
|---|---|---|---|---|---|
| `TROUPE_A2A_AUTOSTART` | unset | yes | starts the Bandit listener | fixed `"true"`, `a2a-deployment.yaml:82-83` | `runtime.exs:415` |
| `TROUPE_A2A_PUBLIC_URL` | none | yes (`runtime.exs:420-427`) | origin written into every agent card and artifact URI | `a2a.publicUrl` defaulting to `https://<a2a.host>`, `a2a-deployment.yaml:88-89` | `runtime.exs:437` |
| `TROUPE_A2A_PORT` | `4002` | no | listen port | `a2a.port`, `a2a-deployment.yaml:84-85` | `runtime.exs:431` |
| `TROUPE_A2A_PLANE_URL` | `http://troupe-plane.troupe-system.svc:4000` | no | where `/rpc` and `/auth/exchange` are reached | `a2a.planeUrl`, `a2a-deployment.yaml:86-87` | `runtime.exs:435-436` |
| `TROUPE_A2A_MAX_STREAMS` | `200` | no | open SSE streams per replica; 429 beyond | `a2a.maxStreams`, `a2a-deployment.yaml:90-91` | `runtime.exs:438` |
| `TROUPE_A2A_VISIBILITY` | `private` | no | visibility a task's session is created with (`private` or `team`) | `a2a.visibility`, `a2a-deployment.yaml:92-93` | `runtime.exs:441` |
| `RELEASE_DISTRIBUTION` | — | — | fixed `none` | `a2a-deployment.yaml:94-95` | — |
| `TROUPE_SCHEDULERS`, `ERL_FLAGS` | set by chart | — | `+S`, `+Q` from `a2a.maxPorts` | `a2a-deployment.yaml:74-81` | — |

### A.5 Daemon and client binary (`troupe`)

Not an admin concern beyond knowing they exist; details are in [../developer/local-setup.md](../developer/local-setup.md) and [../user/cli-reference.md](../user/cli-reference.md).

| Variable | Read at | Purpose |
|---|---|---|
| `TROUPE_DAEMON_AUTOSTART` | `runtime.exs:411` | starts the local gateway daemon in a prod build |
| `TROUPE_CONFIG_HOME`, `XDG_CONFIG_HOME` | `apps/troupe_core/lib/troupe/paths.ex:73-84` | where `config.yaml` and `agents/` live |
| `TROUPE_STATE_HOME`, `XDG_STATE_HOME`, `LOCALAPPDATA`, `APPDATA` | `paths.ex:73-91` | state and config roots per OS |
| `TROUPE_DAEMON_SOCKET`, `XDG_RUNTIME_DIR` | `apps/troupe_protocol/lib/troupe/protocol/endpoint.ex:30,116-127` | daemon socket discovery |
| `TROUPE_DAEMON_COMMAND` | `apps/troupe_protocol/lib/troupe/protocol/daemon.ex` | how a client spawns a local daemon. The `__BURRITO_BIN_PATH` fallback went with the packaged binary: a caller that does not set this gets `:no_daemon_command` |
| `USER`, `USERNAME` | `apps/troupe_gateway/lib/troupe/gateway/connection.ex:466` | local subject name |
| `TROUPE_PROVIDER`, `TROUPE_BASE_URL`, `TROUPE_API_KEY`, `TROUPE_MODEL`, `TROUPE_FAKE_SCRIPT` | `apps/troupe_core/lib/troupe/config.ex:139-152` | core LLM config overrides (also on a pod, A.3) |
| `TROUPE_BAO_ADDR`, `TROUPE_BAO_TOKEN` | `apps/troupe_protocol/lib/troupe/kms/open_bao.ex:121,129` | fallbacks when `:troupe_worker, :kms` is not configured |

### A.6 Build-time

| Variable | Read at | Purpose |
|---|---|---|
| `MIX_ENV` | `docker/Dockerfile:20`; `.github/workflows/ci.yml:72,287` | `prod` in images and Burrito builds |
| `RELEASE` (build arg) → `RELEASE_NAME` | `docker/Dockerfile:13,50,74,78` | which of the four server releases an image runs |
| `BURRITO_TARGET` | `apps/troupe_core/lib/troupe/release.ex:74`; `ci.yml:288` | client binary target |
| `TROUPE_REAPER_TARGETS` | `apps/troupe_core/lib/mix/tasks/compile.reaper.ex:78-84`; `ci.yml:289` | which reaper triples to build (`all` in CI) |
| `TARGET_ABI` | `release.ex:91` (in an error message only) | `musl` for the Linux binary |
| `TROUPE_REGISTRY`, `TROUPE_IMAGE_TAG`, `TROUPE_PUSH`, `TROUPE_KIND_CLUSTER` | `scripts/build-images:19-22` | where images go; `TROUPE_PUSH=true` pushes, otherwise `kind load` |

See [../developer/ci-cd.md](../developer/ci-cd.md) for the CI matrix.

### A.7 Variables with two meanings, and variables nobody reads

- **`TROUPE_BASE_URL` means two things.** On the plane it is the public URL and token issuer (`runtime.exs:255-257,313-314`). On a worker it is the LLM endpoint the operator copies from `llm.endpoint` (`resources.ex:623`; `config.ex:141`). Never set it on a plane to a model gateway or on a worker to the plane ([AUDIT.md §3.4](../AUDIT.md)).
- **`TROUPE_BASE_URL` is effectively mandatory on a plane.** With only `TROUPE_HOST`, `:base_url` stays `nil`, the RFC 9728 document's `resource` becomes `/mcp` and its `scopes_supported` empty (`web/router.ex:294-338`), the third accepted audience is missing (`oidc.ex:115-120`), and the console redirect URI falls back to `http://localhost:4000/admin/callback` (`web/admin_auth.ex:338-341`). The chart always renders it (`plane-deployment.yaml:215-216`), so this only bites hand-written manifests ([AUDIT.md §3.10](../AUDIT.md)).
- **Injected but unread:** `TROUPE_SMALL_MODEL`, `TROUPE_NAMESPACE`, `TROUPE_CONFIG_CHANNEL` (`resources.ex:560-574,627`). Nothing under `apps/*/lib` reads them; `Troupe.Config.merge_env/1` reads only the five variables at `config.ex:139-145`. A profile's `llm.smallModel` therefore has no effect on a pod ([AUDIT.md §3.3](../AUDIT.md)).
- **`TROUPE_DRAIN_TIMEOUT_SECONDS` is not passed to pods.** The operator uses it for `terminationGracePeriodSeconds` (`resources.ex:493`) but does not put it in the container env, so a worker's own drain timeout is always its default 300 s (`runtime.exs:368-369`). Raising `operator.drainTimeoutSeconds` lengthens the grace period without lengthening the worker's wait.
- **`TROUPE_POLICY_NAME` has no Helm value.** `policy.name` (`values.yaml:234`) names the `TroupePolicy` the chart installs and binds to the admission policy (`policy-default.yaml:7`; `admission-policy.yaml:138`), but neither the operator nor the plane deployment sets `TROUPE_POLICY_NAME`, so both read `default` (`reconciler.ex:310`; `cluster_policy.ex:94-97`). A `policy.name` other than `default` leaves the operator reporting `PolicyViolation: NoPolicy` on every profile (`reconciler.ex:320-331`).
- **`TROUPE_OBJECT_REGION` never reaches workers** (A.3). On Scaleway the plane signs for `fr-par` and the pods for `us-east-1`. Unconfirmed whether Scaleway accepts a mismatched region; see [AUDIT.md §4](../AUDIT.md) (infra note 14).
- **`TROUPE_OIDC_SCOPES`** was uncommitted at audit time and is now commit `6c29471`. Its default no longer includes `groups`, because Entra refuses a scope of that name with `AADSTS650053` (`web/router.ex:48-59`). **`TROUPE_OIDC_MCP_SCOPE`** followed in `4083b1f`: the MCP scope is now named after the resource (`<base_url>/mcp/admin`) because a client must send that URL as RFC 8707's `resource` and Entra refused the old `api://<client-id>/admin` pairing with `AADSTS9010010` (`web/router.ex:311-320`); the app registration has to expose that name (`values.yaml:150-154`).

---

## Part B — Helm values

Chart `troupe` version `0.2.0`, `appVersion "0.2.0"` (`charts/troupe/Chart.yaml:5-6`). An empty image tag falls back to `appVersion` (`plane-deployment.yaml:76,164`; `operator-deployment.yaml:38`; `a2a-deployment.yaml:64`). CRDs live in `charts/troupe/crds/` and are installed once, never upgraded, by Helm (`values.yaml:5-9`). Line numbers in the first column are `charts/troupe/values.yaml`; template paths are relative to `charts/troupe/templates/`.

### B.1 Every value

| Value (line) | Default | Consumed at | Becomes |
|---|---|---|---|
| `namespace` (3) | `troupe-system` | `namespace.yaml:4`; every `metadata.namespace`; `operator-deployment.yaml:64,66`; `plane-deployment.yaml:222` | the Namespace; `TROUPE_PLANE_NAMESPACE`; the control host `troupe-plane-control.<ns>.svc` |
| `imagePullSecrets` (16) | `[]` | `plane-deployment.yaml:58-63,146-151`; `operator-deployment.yaml:20-25,84-85`; `a2a-deployment.yaml:46-51` | `imagePullSecrets` on plane, Job, operator, a2a; `TROUPE_IMAGE_PULL_SECRETS` (csv) |
| `networkPolicy.enabled` (23) | `true` | `network-policy.yaml:1`; `a2a-deployment.yaml:146` | plane, operator and a2a NetworkPolicies |
| `operator.image.repository` (27) | `ghcr.io/objective-mj/troupe-operator` | `operator-deployment.yaml:38` | container image |
| `operator.image.tag` (28) | `""` → appVersion | `operator-deployment.yaml:38` | image tag |
| `operator.image.pullPolicy` (29) | `IfNotPresent` | `operator-deployment.yaml:39` | `imagePullPolicy` |
| `operator.replicas` (30) | `1` | `operator-deployment.yaml:11` | Deployment replicas (leader elected by Lease) |
| `operator.resources` (31-33) | 100m/128Mi req, 500m/512Mi lim | `operator-deployment.yaml:108`; `limits.cpu` feeds `TROUPE_SCHEDULERS` (`:53-58`) | container resources, `+S` |
| `operator.ciliumAvailable` (37) | `false` | `operator-deployment.yaml:102-103` | `TROUPE_CILIUM_AVAILABLE` |
| `operator.ingressClassName` (41) | `nginx` | `operator-deployment.yaml:96-97` | `TROUPE_INGRESS_CLASS` |
| `operator.workersScheme` (44) | `wss` | `operator-deployment.yaml:73-74` | `TROUPE_WORKERS_SCHEME` |
| `operator.workersPort` (45) | `""` | `operator-deployment.yaml:75-78` | `TROUPE_WORKERS_PORT` (only when set) |
| `operator.workerAllowedOrigins` (49) | `[]` | `operator-deployment.yaml:88-89` | `TROUPE_WORKER_ALLOWED_ORIGINS` (csv) |
| `operator.maxPorts` (52) | `65536` | `operator-deployment.yaml:60,71-72` | `+Q` in `ERL_FLAGS`; `TROUPE_MAX_PORTS` |
| `operator.certIssuer` (64) | `""` | `operator-deployment.yaml:100-101` | `TROUPE_WORKERS_CERT_ISSUER` |
| `operator.tlsSecretName` (65) | `""` | `operator-deployment.yaml:98-99` | `TROUPE_WORKERS_TLS_SECRET` |
| `operator.drainTimeoutSeconds` (66) | `300` | `operator-deployment.yaml:104-105` | `TROUPE_DRAIN_TIMEOUT_SECONDS` |
| `plane.enabled` (70) | `true` | `plane-deployment.yaml:1`; `network-policy.yaml:11` | whether the plane is rendered at all |
| `plane.image.repository` / `tag` / `pullPolicy` (72-74) | `ghcr.io/objective-mj/troupe-plane` / `""` / `IfNotPresent` | `plane-deployment.yaml:76-77` (Job), `:164-165` | image for plane and migration Job |
| `plane.replicas` (75) | `2` | `plane-deployment.yaml:127,131,383`; `_helpers.tpl:31-35` | Deployment replicas; `Recreate` when 1; PDB `minAvailable: 1` when >1; render fails when >1 with `distribution` not `name` |
| `plane.host` (76) | `plane.example.test` | `plane-deployment.yaml:213-214,434,438` | `TROUPE_HOST`; Ingress host and TLS host |
| `plane.baseUrl` (79) | `""` → `https://<host>` | `plane-deployment.yaml:215-216` | `TROUPE_BASE_URL` |
| `plane.appUrl` (83) | `/app` | `plane-deployment.yaml:220-221` | `TROUPE_APP_URL`; the GUI's own chart mounts it at this path on the same host |
| `plane.cliUrl` (88) | (empty) | `plane-deployment.yaml` | `TROUPE_CLI_URL`; the terminal client is published from another repository and this chart does not serve it |
| `plane.corsOrigins` (82) | `[]` | `plane-deployment.yaml:219-220` | `TROUPE_CORS_ORIGINS` (csv) |
| `plane.ingressClassName` (83) | `nginx` | `plane-deployment.yaml:431` | Ingress class |
| `plane.certIssuer` (86) | `""` | `plane-deployment.yaml:408-413` | `cert-manager.io/cluster-issuer` annotation |
| `plane.tlsSecretName` (87) | `""` | `plane-deployment.yaml:432-436` | Ingress `tls.secretName` |
| `plane.ingress.enabled` (89) | `true` | `plane-deployment.yaml:399` | whether the Ingress is rendered |
| `plane.ingress.bodySize` (92) | `1m` | `plane-deployment.yaml:420` | `proxy-body-size` annotation |
| `plane.ingress.rateLimit.rps` / `burstMultiplier` / `connections` (98-100) | `20` / `5` / `100` | `plane-deployment.yaml:421-429` | `limit-rps`, `limit-burst-multiplier`, `limit-connections` annotations; the whole block `null` turns them off |
| `plane.resources` (102-103) | 200m/256Mi req, 1/1Gi lim | `plane-deployment.yaml:98` (Job), `:347`; `limits.cpu` feeds `TROUPE_SCHEDULERS` (`:195-200`) | container resources, `+S` |
| `plane.controlPort` (105) | `4001` | `plane-deployment.yaml:32,170,211-212`; `operator-deployment.yaml:67-68`; `network-policy.yaml:48` | Service `troupe-plane-control`; `TROUPE_PLANE_CONTROL_PORT` on plane and operator; NetworkPolicy port |
| `plane.httpPort` (106) | `4000` | `plane-deployment.yaml:19,168,209-210,447`; `network-policy.yaml:36` | Service `troupe-plane`; `TROUPE_HTTP_PORT`; Ingress backend; NetworkPolicy port |
| `plane.distPort` (110) | `9100` | `plane-deployment.yaml:175,203`; `network-policy.yaml:59` | `inet_dist_listen_min/max` in `ERL_FLAGS`; container port `dist`; NetworkPolicy port |
| `plane.maxPorts` (112) | `65536` | `plane-deployment.yaml:86,203,205` | `+Q` on plane and Job |
| `plane.provisioningMode` (115) | `direct` | `plane-deployment.yaml:223-224` | `TROUPE_PROVISIONING_MODE` |
| `plane.platformAdminGroup` (118) | `troupe-platform-admins` | `plane-deployment.yaml:225-226` | `TROUPE_PLATFORM_ADMIN_GROUP` |
| `plane.groupsClaim` (119) | `groups` | `plane-deployment.yaml:227-228` | `TROUPE_GROUPS_CLAIM` |
| `plane.distribution` (125) | `name` | `plane-deployment.yaml:131,171-176,202-206,261-276`; `network-policy.yaml:49-60`; `_helpers.tpl:31-35` | `RELEASE_DISTRIBUTION`; epmd and dist ports; `POD_IP`, `RELEASE_NODE`, `TROUPE_NODE_BASENAME`, `TROUPE_PLANE_SELECTOR`; dist NetworkPolicy rule; `Recreate` strategy when not `name` |
| `plane.database.secretName` / `secretKey` (129-130) | `troupe-plane-database` / `url` | `plane-deployment.yaml:87-91,278-282` | `DATABASE_URL` via `secretKeyRef` |
| `plane.secretKeyBase.secretName` / `secretKey` (134-135) | `troupe-plane-secret-key-base` / `value` | `plane-deployment.yaml:283-287` | `TROUPE_SECRET_KEY_BASE` |
| `plane.oidc.issuer` (137) | `""` | `plane-deployment.yaml:229-230` | `TROUPE_OIDC_ISSUER` |
| `plane.oidc.clientId` (138) | `""` | `plane-deployment.yaml:231-232` | `TROUPE_OIDC_CLIENT_ID` |
| `plane.oidc.authorizeUrl` (141) | `""` | `plane-deployment.yaml:233-234` | `TROUPE_OIDC_AUTHORIZE_URL` |
| `plane.oidc.deviceUrl` (142) | `""` | `plane-deployment.yaml:245-246` | `TROUPE_OIDC_DEVICE_URL` |
| `plane.oidc.tokenUrl` (143) | `""` | `plane-deployment.yaml:247-248` | `TROUPE_OIDC_TOKEN_URL` |
| `plane.oidc.scopes` (149) | `[]` → four OIDC scopes | `plane-deployment.yaml:235-239` | `TROUPE_OIDC_SCOPES` (csv), only when non-empty |
| `plane.oidc.mcpScope` (154) | `""` → `<baseUrl>/mcp/admin` | `plane-deployment.yaml:240-244` | `TROUPE_OIDC_MCP_SCOPE`, only when non-empty (commit `4083b1f`) |
| `plane.oidc.secretName` / `secretKey` (155-156) | `troupe-plane-oidc` / `client-secret` | `plane-deployment.yaml:288-295` | `TROUPE_OIDC_CLIENT_SECRET`, `optional: true`, only when `secretName` set |
| `plane.breakglass.secretName` / `secretKey` / `subject` / `lifetimeSeconds` (166-169) | `""` / `token` / `breakglass` / `3600` | `plane-deployment.yaml:303-316` | `TROUPE_BREAKGLASS_TOKEN`, `_SUBJECT`, `_LIFETIME_SECONDS`, all only when `secretName` set |
| `plane.scim.enabled` / `secretName` / `secretKey` (171-173) | `false` / `troupe-plane-scim` / `token` | `plane-deployment.yaml:296-302` | `TROUPE_SCIM_TOKEN` when enabled |
| `worker.image.repository` / `tag` | `ghcr.io/objective-mj/troupe-worker` / `""` → `appVersion` | `plane-deployment.yaml` | `TROUPE_WORKER_IMAGE` on the plane; what a profile whose image is `release` runs. The policy must allow the repository |
| `a2a.enabled` (180) | `false` | `a2a-deployment.yaml:10`; `network-policy.yaml:29-34` | whether the facade is rendered; admits facade pods on the plane's HTTP port |
| `a2a.image.repository` / `tag` / `pullPolicy` (182-184) | `ghcr.io/objective-mj/troupe-a2a` / `""` / `IfNotPresent` | `a2a-deployment.yaml:64-65` | image |
| `a2a.replicas` (187) | `1` | `a2a-deployment.yaml:37` | replicas |
| `a2a.host` (188) | `a2a.example.test` | `a2a-deployment.yaml:89,132,136` | default `publicUrl`; Ingress host |
| `a2a.publicUrl` (191) | `""` → `https://<host>` | `a2a-deployment.yaml:88-89` | `TROUPE_A2A_PUBLIC_URL` |
| `a2a.planeUrl` (196) | `http://troupe-plane.troupe-system.svc:4000` | `a2a-deployment.yaml:86-87` | `TROUPE_A2A_PLANE_URL` |
| `a2a.port` (197) | `4002` | `a2a-deployment.yaml:27,68,84-85,145,167` | Service, container port, `TROUPE_A2A_PORT`, Ingress backend, NetworkPolicy port |
| `a2a.maxStreams` (200) | `200` | `a2a-deployment.yaml:90-91` | `TROUPE_A2A_MAX_STREAMS` |
| `a2a.visibility` (204) | `private` | `a2a-deployment.yaml:92-93` | `TROUPE_A2A_VISIBILITY` |
| `a2a.ingressClassName` (205) | `nginx` | `a2a-deployment.yaml:129` | Ingress class |
| `a2a.tlsSecretName` (206) | `""` | `a2a-deployment.yaml:130-134` | Ingress TLS secret |
| `a2a.maxPorts` (208) | `65536` | `a2a-deployment.yaml:81` | `+Q` |
| `a2a.resources` (210-211) | 100m/128Mi req, 500m/512Mi lim | `a2a-deployment.yaml:96` | resources, `+S` |
| `bao.address` (214) | `http://openbao.troupe-system.svc:8200` | `plane-deployment.yaml:249-250`; `operator-deployment.yaml:90-91` | `TROUPE_BAO_ADDR` on plane and operator (and, via the operator, workers) |
| `bao.authPath` (218) | `kubernetes` | `plane-deployment.yaml:251-252` | `TROUPE_BAO_AUTH_PATH` |
| `bao.planeRole` (219) | `troupe-plane` | `plane-deployment.yaml:253-254` | `TROUPE_BAO_ROLE` |
| `bao.tokenSecretName` (222) | `""` | `plane-deployment.yaml:103-118,331-346,367-382` | when set: `TROUPE_BAO_TOKEN`; when empty: projected token volume and `TROUPE_BAO_JWT_PATH` |
| `bao.tokenSecretKey` (223) | `token` | `plane-deployment.yaml:337` | key of the static token |
| `objectStore.endpoint` (226) | `http://minio.troupe-system.svc:9000` | `plane-deployment.yaml:255-256`; `operator-deployment.yaml:92-93` | `TROUPE_OBJECT_ENDPOINT` on plane and operator |
| `objectStore.bucket` (227) | `troupe-sessions` | `plane-deployment.yaml:257-258`; `operator-deployment.yaml:94-95` | `TROUPE_OBJECT_BUCKET` |
| `objectStore.region` (228) | `us-east-1` | `plane-deployment.yaml:259-260` only | `TROUPE_OBJECT_REGION` on the plane; **not** on the operator or workers |
| `objectStore.secretName` (229) | `troupe-object-store` | `plane-deployment.yaml:317-330`; `operator-deployment.yaml:69-70` | plane `secretKeyRef`s (optional); `TROUPE_OBJECT_SECRET_NAME` for workers |
| `policy.install` (233) | `true` | `policy-default.yaml:1` | whether the default `TroupePolicy` is rendered (`helm.sh/resource-policy: keep`, `:10`) |
| `policy.name` (234) | `default` | `policy-default.yaml:7`; `admission-policy.yaml:138` | CR name and admission `paramRef`. Does **not** set `TROUPE_POLICY_NAME` (A.7) |
| `policy.allowedImageRepositories` (235-236) | `[ghcr.io/objective-mj/troupe-worker]` | `policy-default.yaml:12` | `spec.allowedImageRepositories` |
| `policy.maxReplicas` (237) | `8` | `policy-default.yaml:13` | `spec.maxReplicas` |
| `policy.maxSessionsPerPod` (238) | `8` | `policy-default.yaml:14` | `spec.maxSessionsPerPod` |
| `policy.maxResources.cpu` / `memory` (240-241) | `"4"` / `8Gi` | `policy-default.yaml:15` | `spec.maxResources` |
| `policy.allowedEgress` (242-244) | `["*.anthropic.com", github.com]` | `policy-default.yaml:16` | `spec.allowedEgress` |
| `policy.allowedStorageClasses` (245-246) | `[standard]` | `policy-default.yaml:17` | `spec.allowedStorageClasses` |
| `policy.orgVolume` (247) | `{}` | `policy-default.yaml:18-20` | `spec.orgVolume`, only when non-empty |
| `policy.namespacePrefix` (248) | `troupe-w-` | `policy-default.yaml:21` | `spec.namespacePrefix` |
| `policy.workersDomain` (249) | `workers.example.test` | `policy-default.yaml:22` | `spec.workersDomain` |
| `admission.install` (255) | `true` | `admission-policy.yaml:1` | `ValidatingAdmissionPolicy` + binding (`failurePolicy: Fail`, `validationActions: [Deny]`, `parameterNotFoundAction: Deny`) |

Things that are **not** chart values and have to be set elsewhere: worker profiles, images, resources and team volumes (custom resources — [profiles-and-policy.md](profiles-and-policy.md)); the LLM gateway (a profile field plus egress); database TLS and pool size; `TROUPE_LOG_FORMAT`, `TROUPE_PLANE_AUDIENCE`, `TROUPE_POLICY_NAME`, `TROUPE_MAX_FRAME_BYTES`; the ingress controller, cert-manager and OpenBao server themselves (`deploy/scaleway/*`).

### B.2 The three overlays

Only values that differ from `values.yaml` are listed. Line numbers are within each file. None of the three overlay files changed in `4083b1f`, so none sets `plane.oidc.mcpScope`.

| Value | `values.yaml` | `values.small.yaml` | `values.scaleway.yaml` | `dev/kind/values.yaml` |
|---|---|---|---|---|
| `operator.image.repository` | `ghcr.io/objective-mj/troupe-operator` | `rg.fr-par.scw.cloud/troupe/troupe-operator` (28) | same (17) | default |
| `operator.image.tag` | `""` | `"0.2.0"` (29) | `"0.2.0"` (18) | `dev` (8) |
| `operator.resources` | 100m/128Mi – 500m/512Mi | 50m/96Mi – 300m/256Mi (35-36) | 100m/128Mi – 1/512Mi (21-22) | 100m/128Mi – 1/512Mi (10-11) |
| `operator.ciliumAvailable` | `false` | `true` (37) | `true` (25) | default |
| `operator.certIssuer` | `""` | `letsencrypt` (45) | `letsencrypt` (36) | default |
| `operator.workersScheme` / `workersPort` | `wss` / `""` | same | same | `ws` / `30080` (15-16) |
| `plane.image.repository` / `tag` | ghcr / `""` | `rg.fr-par.scw.cloud/troupe/troupe-plane` / `"0.2.0"` (53-54) | same (44-45) | default / `dev` (20) |
| `plane.replicas` | `2` | `1` (61) | `2` (49) | `1` (23) |
| `plane.distribution` | `name` | `none` (62) | `name` (50) | `none` (24) |
| `plane.host` | `plane.example.test` | `troupe.example.com` (63) | same (51) | `plane.localtest.me` (25) |
| `plane.baseUrl` | `""` | `https://troupe.example.com` (64) | same (52) | `http://plane.localtest.me:30080` (29) |
| `plane.tlsSecretName` | `""` | `troupe-plane-tls` (70) | `troupe-plane-tls` (57) | `""` (31) |
| `plane.certIssuer` | `""` | `""` (69) | `""` (56) | default |
| `plane.resources` | 200m/256Mi – 1/1Gi | 100m/256Mi – 500m/768Mi (85-86) | default (61-62) | 100m/256Mi – 1/1Gi (35-36) |
| `plane.oidc.issuer` … `tokenUrl` | `""` | `https://login.example.com` + `/oauth2/v2.0/{authorize,devicecode,token}`, client `troupe` (101-105) | same (82-86) | Dex at `http://dex.localtest.me:30080/dex`, client `troupe` (38-42) |
| `plane.oidc.secretName` | `troupe-plane-oidc` | `""` (106) | `""` (89) | `""` (45) |
| `plane.scim` | `enabled: false`, `secretName: troupe-plane-scim` | `enabled: false` only (120-121) | `enabled: false` only (103-104) | default |
| `bao.tokenSecretName` | `""` | `""` (127) | `""` (116) | `troupe-bao-token` (50) |
| `objectStore.endpoint` | `http://minio.troupe-system.svc:9000` | `https://s3.fr-par.scw.cloud` (130) | same (123) | minio (54) |
| `objectStore.region` | `us-east-1` | `fr-par` (132) | `fr-par` (125) | `us-east-1` (56) |
| `policy.allowedImageRepositories` | ghcr worker | `rg.fr-par.scw.cloud/troupe/troupe-worker` (139) | same (132) | ghcr (63) |
| `policy.maxReplicas` | `8` | `3` (145) | `8` (133) | `2` (64) |
| `policy.maxSessionsPerPod` | `8` | `4` (149) | `8` (134) | `4` (65) |
| `policy.maxResources` | 4 / 8Gi | 2 / 4Gi (154-155) | 4 / 8Gi (136-137) | 2 / 4Gi (66) |
| `policy.allowedEgress` | `*.anthropic.com`, `github.com` | `llm-gw.itmindsinternal.dk`, `github.com`, `*.github.com` (157-159) | same (142-144) | those three plus `*.anthropic.com` (70-76) |
| `policy.allowedStorageClasses` | `standard` | `scw-bssd`, `scw-sfs` (165-166) | same (150-151) | `standard` (78) |
| `policy.workersDomain` | `workers.example.test` | `workers.example.com` (169) | same (154) | `workers.localtest.me` (80) |
| `networkPolicy.enabled` | `true` | `true` (24) | default | default — kind's CNI does not enforce it ([AUDIT.md §4.16](../AUDIT.md)) |

Three notes on the overlays:

- **Nothing in the repository issues `troupe-plane-tls`.** Both Scaleway files set `plane.tlsSecretName: troupe-plane-tls` with `plane.certIssuer: ""`, and `deploy/scaleway/cluster-issuer.yaml` is HTTP-01 only. Discrepancy: `docs/deploying-on-scaleway.md:127-137,180` describes a DNS-01 wildcard and lists `troupe-workers-tls` and `troupe-plane-tls` as "written by cert-manager"; the values files instead use `operator.certIssuer: letsencrypt` (per-pod HTTP-01) and leave the plane's certificate to somebody ([AUDIT.md §2](../AUDIT.md)).
- The small and Scaleway `plane.scim` blocks omit `secretName`; Helm merges with the default, so `troupe-plane-scim` still applies if `enabled` is flipped on.
- `plane.distribution: none` with `replicas: 1` rolls by `Recreate`, so an upgrade is a few seconds without a plane (`plane-deployment.yaml:131-138`; `values.small.yaml:55-62`).

---

## Part C — Platform settings

`Troupe.Plane.Settings` (`apps/troupe_plane/lib/troupe/plane/settings.ex`) is a registry of what a platform admin may change without a rollout, stored in the `platform_settings` table (migration `20260913000011_platform_settings.exs`).

**Precedence** (`settings.ex:364-393`): a stored row that parses as the declared type → the deployed value (`Application.get_env` from the variable in Part A) → the fallback the release ships. `reset` deletes the row rather than writing today's default into it (`settings.ex:342-352`). A stored value that no longer parses falls back to the deployed value (`:369-377`).

**Freshness**: reads go through an ETS table with a five-second life (`settings.ex:220-221,469-488`); the writer invalidates its own node immediately (`:337,447-452`), so a change is visible at once on the replica that made it and within five seconds on the others.

| Key | Group | Type | Editable | Deployed from | Fallback | Effect | Lines |
|---|---|---|---|---|---|---|---|
| `platform_admin_group` | administration | string | yes | `TROUPE_PLATFORM_ADMIN_GROUP` | none | immediate | 50-59 |
| `groups_claim` | administration | string | yes | `TROUPE_GROUPS_CLAIM` | `groups` | immediate | 60-70 |
| `provisioning_mode` | provisioning | enum `direct`, `gitops` | yes | `TROUPE_PROVISIONING_MODE` | `direct` | immediate | 71-82 |
| `default_budget_micros` | team_defaults | integer | yes | — | `0` (unlimited) | next team enabled | 83-92 |
| `default_budget_period` | team_defaults | enum `monthly`, `daily` | yes | — | `monthly` | next team enabled | 93-104 |
| `default_idle_timeout_seconds` | team_defaults | integer | yes | — | `1800` | next team enabled | 105-114 |
| `default_erase_after_days` | team_defaults | integer | yes | — | `365` | next team enabled | 115-123 |
| `default_bundle_channel` | sessions | string | yes | — | `stable` | next session | 124-133 |
| `issuer` | deployment | string | **no** | `TROUPE_OIDC_ISSUER` | — | restart | 135-145 |
| `client_id` | deployment | string | **no** | `TROUPE_OIDC_CLIENT_ID` | — | restart | 146-156 |
| `client_secret` | deployment | secret | **no** | `TROUPE_OIDC_CLIENT_SECRET` | — | restart | 157-168 |
| `audience` | deployment | string | **no** | `TROUPE_PLANE_AUDIENCE` | `troupe-plane-api` | restart | 169-180 |
| `base_url` | deployment | string | **no** | `TROUPE_BASE_URL` | — | restart | 181-191 |
| `scim_token` | deployment | secret | **no** | `TROUPE_SCIM_TOKEN` | — | restart | 192-203 |
| `breakglass_token` | deployment | secret | **no** | `TROUPE_BREAKGLASS_TOKEN` | — | restart | 204-215 |

Effect wording as the console prints it: `immediate` = "Takes effect on the next request", `next_team` = "Applies to teams enabled after the change", `next_session` = "Applies to sessions started after the change", `restart` = "Set at deploy time; changing it needs a rollout" (`settings.ex:312-315`). Secrets are reported as `set`/unset and never returned (`settings.ex:298-303,401`). `TROUPE_OIDC_SCOPES` and `TROUPE_OIDC_MCP_SCOPE` are not in the registry; they are deployment-only and invisible to `admin.settings.list`.

Discrepancies and caveats:

- `default_budget_period` offers `monthly` or `daily` (`settings.ex:97`), the API describes "monthly or daily" (`admin/api.ex:107`) and the Teams page offers both (`web/live/teams.ex:207-208`), but `Identity.Team` accepts only `monthly` or `never` (`identity/team.ex:69`) and the ledger never windows spend by period (`ledger.ex:69-78`). Enabling a team while the default is `daily` will fail the changeset. [AUDIT.md §2, §4.9](../AUDIT.md).
- `default_bundle_channel` has no reader beyond the registry ([AUDIT.md §4.10](../AUDIT.md)); a profile's channel is `configBundleChannel` on the CR (default `stable`, `charts/troupe/crds/workerprofile.yaml:99`).
- `platform_admin_group` and `groups_claim` are what `Admin.actor_for/1` and `Login.from_claims/1` read (`login.ex:63-71`), so a wrong value locks everyone out at their next request; the console will not save `platform_admin_group` until `admin.identity.check` has passed for the value in the field (`web/live/settings.ex:38,90`).

**How to change one** (all four surfaces reach the same `Settings.put/3`):

| Surface | How |
|---|---|
| Console | `/admin/settings` (`web/admin_router.ex:55`); readable by team admins, writable by platform admins only |
| JSON-RPC | `admin.setting.put {key, value}` and `admin.setting.reset {key}` (`admin/api.ex:532-563`), platform admin only (`admin.ex:447-479`) |
| MCP | tools `admin_setting_put` and `admin_setting_reset` (dots become underscores, `admin/mcp.ex:211`) |

Values are always sent as strings and parsed against the type (`settings.ex:409-441`); an enum is matched against the declared atoms rather than converted (`:417-426`).

---

## Part D — Secrets the chart expects

Troupe creates no Secrets (`values.yaml:11-16,126-130`). Every one below must exist before the pod that references it starts.

| Secret | Namespace | Keys | Referenced by | When needed |
|---|---|---|---|---|
| `troupe-plane-database` (`plane.database.secretName`) | `troupe-system` | `url` | plane and migration Job, `plane-deployment.yaml:87-91,278-282` | always |
| `troupe-plane-secret-key-base` (`plane.secretKeyBase.secretName`) | `troupe-system` | `value` (≥ 64 bytes) | plane, `plane-deployment.yaml:283-287` | always |
| `troupe-plane-oidc` (`plane.oidc.secretName`) | `troupe-system` | `client-secret` | plane, `optional: true`, `plane-deployment.yaml:288-295` | console login (authorization-code redemption, `web/admin_auth.ex:138`). Both Scaleway overlays set `secretName: ""`, which means no console login |
| `troupe-object-store` (`objectStore.secretName`) | `troupe-system` | `access-key-id`, `secret-access-key` | plane, `optional: true`, `plane-deployment.yaml:317-330` | `mix troupe.index.rebuild` and any plane read of manifests |
| `troupe-object-store` (`TROUPE_OBJECT_SECRET_NAME`) | **every** `troupe-w-<profile>` | same two keys | worker pods, `optional: true`, `resources.ex:597-610` | every session (a pod without them crashes in the signer, `resources.ex:595-596`) |
| break-glass token (`plane.breakglass.secretName`, your name) | `troupe-system` | `token` (`plane.breakglass.secretKey`) | plane, `plane-deployment.yaml:303-316` | only when the door is wanted |
| `troupe-plane-scim` (`plane.scim.secretName`) | `troupe-system` | `token` | plane when `plane.scim.enabled`, `plane-deployment.yaml:296-302` | SCIM push |
| `troupe-bao-token` (`bao.tokenSecretName`) | `troupe-system` | `token` | plane, `plane-deployment.yaml:331-337` | **dev only** (`dev/kind/values.yaml:50-51`, `dev/kind/dependencies.yaml:36-42`); production uses the projected ServiceAccount token |
| LLM secret (profile `llm.secretRef.name`) | `troupe-w-<profile>` | `llm.secretRef.key`, default `api-key` (`crds/workerprofile.yaml:59-63`) | worker `TROUPE_API_KEY`, **not** optional, `resources.ex:629-644` | every profile with `llm.secretRef` |
| `troupe-mcp-<server>` | `troupe-w-<profile>` | `token` | worker `<credentialRef>`, `optional: true`, `resources.ex:668-677`; name from `bundles.ex:484-486` | every bundle MCP server with a `credential_ref` |
| pull secrets (`imagePullSecrets`) | `troupe-system` **and** every `troupe-w-<profile>` | `.dockerconfigjson` | plane, Job, operator, a2a (`plane-deployment.yaml:58-63,146-151`; `operator-deployment.yaml:20-25`; `a2a-deployment.yaml:46-51`) and worker pods (`resources.ex:497-501`) | private registries |
| `troupe-plane-tls` (`plane.tlsSecretName`) | `troupe-system` | `tls.crt`, `tls.key` | plane Ingress, `plane-deployment.yaml:432-436` | when TLS terminates at the plane's Ingress; written by cert-manager only if `plane.certIssuer` is set |
| `a2a.tlsSecretName` | `troupe-system` | `tls.crt`, `tls.key` | a2a Ingress, `a2a-deployment.yaml:130-134` | with the facade |
| worker TLS: `<profile>-<ordinal>-tls` per pod, or `TROUPE_WORKERS_TLS_SECRET` shared | `troupe-w-<profile>` | `tls.crt`, `tls.key` | per-pod Ingress, `resources.ex:229-237` | per pod is written by cert-manager when `operator.certIssuer` is set; the shared one is yours |

**Caveat on `SecretMissing`.** The operator's reconciler checks whether a profile's LLM and MCP secrets exist in `settings.plane_namespace` — `troupe-system` — (`apps/troupe_operator/lib/troupe/operator/reconciler.ex:184-195`), while the pods resolve every `secretKeyRef` in their own namespace `troupe-w-<profile>`. In addition the operator's ClusterRole grants no verb on `secrets` (`charts/troupe/templates/operator-rbac.yaml:15-46`), so the in-cluster `get` is expected to be Forbidden and the condition to read `SecretMissing: True` regardless. Discrepancy: `ARCHITECTURE.md:693-697` and `docs/deploying-on-scaleway.md:182-197` say the condition clears when the secret exists in the worker namespace. Put the secrets where the pods read them (`troupe-w-<profile>`); treat the condition as unreliable until the reconciler changes. [AUDIT.md §2, §4.4](../AUDIT.md).

---

## Part E — Ports and network policy

### Ports

| Port | Who listens | Exposed how | Source |
|---|---|---|---|
| 4000 | plane HTTP (`/rpc`, `/mcp`, console, discovery) | Service `troupe-plane` → Ingress `plane.host` | `values.yaml:106`; `plane-deployment.yaml:12-20,166-168,437-447` |
| 4000 | worker WebSocket `/v1/socket`, `/health/live`, `/health/ready` | per-pod Service `<profile>-<ordinal>` → Ingress `<ordinal>-<profile>.<workersDomain>` | `resources.ex:152,175,199,508`; `runtime.exs:361` |
| 4001 | plane control listener (NDJSON over TCP) | Service `troupe-plane-control`; **never through an Ingress** | `values.yaml:104-105`; `plane-deployment.yaml:22-33,169-170`; `runtime.exs:316` |
| 4002 | A2A facade | Service `troupe-a2a` → Ingress `a2a.host` | `values.yaml:197`; `a2a-deployment.yaml:17-28,135-145` |
| 4100 | worker raw NDJSON harness | no Service; in-pod only | `runtime.exs:358-362` |
| 4369 | epmd on plane pods (only with `distribution: name`) | pod-to-pod only | `plane-deployment.yaml:171-173`; `network-policy.yaml:58` |
| 9100 | Erlang distribution on plane pods (`plane.distPort`) | pod-to-pod only | `values.yaml:110`; `plane-deployment.yaml:174-175,203`; `network-policy.yaml:59` |
| 8200 / 9000 / 5432 | OpenBao, MinIO, Postgres (defaults) | in-cluster Services, not part of this chart | `values.yaml:214,226`; `dev/kind/dependencies.yaml` |
| 8080 | the GUI | a separate repository; not in this chart | see [integrations.md](integrations.md) |

### Namespace labels

- `troupe.dev/ingress=true` on the namespace running the ingress controller. The plane's NetworkPolicy admits HTTP only from namespaces carrying it (`network-policy.yaml:26-36`), the a2a policy likewise (`a2a-deployment.yaml:163-167`), and every worker NetworkPolicy admits port 4000 only from it (`resources.ex:284-291`). Helm cannot label a namespace it did not create; the command is in `deploy/scaleway/ingress-nginx.values.yaml:37-45` and [routine-tasks.md](routine-tasks.md). Without it a worker Ingress answers 503 (`docs/deploying-on-scaleway.md:368`).
- `troupe.dev/workers=true` on every worker namespace, written by the operator when it creates the namespace (`resources.ex:61-73`). The plane's policy admits the control port only from namespaces carrying it and from operator pods (`network-policy.yaml:42-48`). A namespace created by an older operator gets the label on its next reconcile (`docs/deploying-on-scaleway.md:324-327`).

### NetworkPolicies the chart and the operator write

| Policy | Ingress admitted | Egress | Source |
|---|---|---|---|
| `troupe-plane` (plane pods) | HTTP from `troupe.dev/ingress=true` namespaces (and a2a pods when enabled); control port from `troupe.dev/workers=true` namespaces and operator pods; 4369 + `distPort` from plane pods when clustered | unrestricted | `network-policy.yaml:11-61` |
| `troupe-operator` | nothing (`ingress: []`) | unrestricted | `network-policy.yaml:63-77` |
| `troupe-a2a` | `a2a.port` from `troupe.dev/ingress=true` namespaces | unrestricted | `a2a-deployment.yaml:146-168` |
| `troupe-w-<profile>` (worker pods) | TCP 4000 from `troupe.dev/ingress=true` namespaces | DNS (kube-dns 53); plane namespace on the control port; `0.0.0.0/0` except RFC 1918 and link-local on 443 and 80; plus a namespace rule for OpenBao and object storage when their hosts are `*.svc` | `resources.ex:275-383` |
| `troupe-egress` (CiliumNetworkPolicy, only with `ciliumAvailable`) | — | `toFQDNs` for the LLM endpoint, MCP servers, `egress.fqdns` and `gitHosts` (`matchPattern` for wildcards, `matchName` otherwise) plus kube-dns | `resources.ex:385-417` |

Egress from the plane and operator is deliberately unrestricted by the chart (`network-policy.yaml:2-5`). Without Cilium the worker's FQDN egress is the wide CIDR rule and a documented gap (`resources.ex:270-274`, `values.yaml:34-37`).

### Ingress annotations and limits

| Ingress | Annotations | Source |
|---|---|---|
| plane | `proxy-read-timeout: 3600`, `proxy-send-timeout: 3600`, `proxy-body-size: <plane.ingress.bodySize>` (default `1m`), `limit-rps: 20`, `limit-burst-multiplier: 5`, `limit-connections: 100` (per client IP; `rateLimit: null` disables), `cert-manager.io/cluster-issuer` when `plane.certIssuer` | `plane-deployment.yaml:407-429`; `values.yaml:90-100` |
| a2a | `proxy-buffering: off`, `proxy-read-timeout: 3600`, `proxy-send-timeout: 3600`, `proxy-body-size: 2m` | `a2a-deployment.yaml:118-127` |
| worker (nginx class only) | `proxy-read-timeout: 3600`, `proxy-send-timeout: 3600`, `limit-connections: 50`, `cert-manager.io/cluster-issuer` when set | `resources.ex:243-264` |
| ingress-nginx controller (Scaleway) | `use-proxy-protocol: true`, `proxy-read-timeout: 3600`, `proxy-send-timeout: 3600`, `proxy-body-size: 16m`; LB annotations `scw-loadbalancer-type: LB-S`, `proxy-protocol-v2: true` | `deploy/scaleway/ingress-nginx.values.yaml:13-35` |

Request bodies: the plane's JSON parser accepts 4 MiB (`web/router.ex:37-43`); the control channel frames are capped at 8 MiB and worker WebSocket frames at `TROUPE_MAX_FRAME_BYTES` (16 MiB). The Scaleway controller's `proxy-body-size: 16m` exists so a large `input.send` is refused at the worker rather than the proxy (`ingress-nginx.values.yaml:33-35`).
