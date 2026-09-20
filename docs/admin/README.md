# Troupe — administrator documentation

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).
>
> Commit `4083b1f` (`TROUPE_OIDC_MCP_SCOPE`, `plane.oidc.mcpScope`) landed while this track was being written and is covered; line numbers in this tree are from that commit.

> **Re-audited 2026-09-14.** The client apps were deleted; this repository ships four
> images and the chart. The `troupe admin …` commands used throughout this track are the
> **terminal client's** rendering of the admin API, and that client is published from its
> own repository — `plane.cliUrl` is where you tell the front page it lives. Every command
> shown has three equivalents that do ship here: an `admin.*` JSON-RPC method at
> `POST /rpc`, the same method as an MCP tool at `POST /mcp`, and a page in the console at
> `/admin`. [roles-and-permissions.md §9](roles-and-permissions.md#9-the-admin-method-table)
> is the method table; a step written as a command is a step, not a dependency on a binary.

## Who this is for

You operate a Troupe deployment: you install the Helm chart, run PostgreSQL, object storage, OpenBao and an identity provider beside it, set its configuration, and manage teams, worker profiles, policy, bundles, triggers, principals, backups and monitoring. Every claim in this tree names the file and line that decides it. Where prose in the repository disagrees with the code, the code is documented and the stale text is named as a `Discrepancy`; where the code could not settle a question, it is marked `Unconfirmed` with a pointer into [AUDIT.md](../AUDIT.md).

Other tracks: [developer](../developer/README.md) (build, deploy, CI, architecture), [user](../user/README.md) (the CLI and what a session can do — deprecated), the [whitepaper](../whitepaper.md) (why it is built this way), and the [A2A facade](../a2a.md).

## The documents

| Document | What it covers |
|---|---|
| [configuration.md](configuration.md) | **The reference.** Every environment variable per release (A), every Helm value and the three overlay files (B), the platform settings registry (C), every Secret the chart expects (D), ports, labels and NetworkPolicies (E) |
| [roles-and-permissions.md](roles-and-permissions.md) | Identity from the provider, the three admin roles, service principals, break-glass, session roles, how each surface authenticates, Kubernetes RBAC and OpenBao policies, and the full table of 38 admin methods across console, CLI, JSON-RPC and MCP |
| [profiles-and-policy.md](profiles-and-policy.md) | `WorkerProfile` field by field, everything the operator creates for one, status conditions, upgrades, `TroupePolicy` and its double enforcement, `TeamVolume`, direct versus GitOps provisioning, the profile editor and CLI, egress, sizing |
| [bundles-and-triggers.md](bundles-and-triggers.md) | Config bundles (schema, validation, publish/retire, adoption, the directory layout, MCP secret convention), service principals, triggers and the in-plane scheduler, unattended session terms, the A2A facade, team defaults and the budget model |
| [integrations.md](integrations.md) | Exact requirements for the identity provider, OpenBao, PostgreSQL, object storage, the LLM gateway, Kubernetes, MCP servers, SCIM, Hatchet, the GUI |
| [authentik.md](authentik.md) | Connecting a plane to Authentik: which string is the person and why it cannot be fixed later, the objects to create, the cutover order, SCIM with a dry run first, and what was not verified |
| [backup-restore.md](backup-restore.md) | Where state lives and which copy is authoritative, `scripts/pitr-drill`, the rebuild and reconcile tasks, erasure semantics, what is missing, and a restore procedure |
| [monitoring.md](monitoring.md) | Health endpoints, Kubernetes signals, the console, the audit log, JSON logs, telemetry events (no exporter exists), fleet mechanics, and the failure table |
| [routine-tasks.md](routine-tasks.md) | Step lists with exact commands: install, upgrade, teams, grants, admins, principals, bundles, MCP servers, drains, settings, break-glass, SCIM, A2A, rotations, audit, erasure, drills, rebuilds, decommissioning |

## Ten things to know before the first `helm install`

1. **Troupe creates no Secrets.** Every one in [configuration.md Part D](configuration.md#part-d--secrets-the-chart-expects) must exist first, and the object-store, LLM, MCP and pull secrets must exist in **every** worker namespace as well as `troupe-system`.
2. **CRDs are installed once by Helm and never upgraded.** `kubectl apply -f charts/troupe/crds/` on every upgrade (`charts/troupe/values.yaml:5-9`).
3. **Label the ingress namespace** `troupe.dev/ingress=true`, or every worker Ingress answers 503 ([configuration.md Part E](configuration.md#part-e--ports-and-network-policy)).
4. **Platform admin comes from an identity-provider group**, read from a token claim — never from a scope. Ask for `groups` as a scope and Entra refuses every sign-in ([roles-and-permissions.md §2](roles-and-permissions.md#2-the-three-admin-roles); [integrations.md §1](integrations.md#1-identity-provider-oidc)).
5. **Bucket versioning must be on**, or erasure's promise is vacuous ([integrations.md §4](integrations.md#4-object-storage-s3)).
6. **The plane's Kubernetes connection for provisioning (`:k8s_conn`) is set by nothing in the repository.** Direct-mode `profile put` saves the row and reports `not_applied`; apply the CR yourself until that is resolved ([profiles-and-policy.md §7](profiles-and-policy.md#7-provisioning-how-the-planes-row-becomes-a-cr); [AUDIT.md §3.1](../AUDIT.md)).
7. **`SecretMissing` looks in the wrong namespace with a permission it does not have**; do not trust it ([configuration.md Part D](configuration.md#part-d--secrets-the-chart-expects)).
8. **Nothing restarts a drained worker pod.** The StatefulSet is `OnDelete`; after `troupe admin pod drain`, `kubectl delete pod` yourself ([profiles-and-policy.md §4](profiles-and-policy.md#4-how-an-upgrade-works)).
9. **Triggers, principals, settings and the audit trail live only in PostgreSQL.** The session index is rebuildable from object storage; those are not ([backup-restore.md §1](backup-restore.md#1-where-state-lives-and-which-copy-is-authoritative)).
10. **There is no metrics exporter, no backup CronJob, no OpenBao snapshot and no webhook endpoint** in the repository ([monitoring.md](monitoring.md); [backup-restore.md §3](backup-restore.md#3-what-the-repository-does-not-provide); [bundles-and-triggers.md §3](bundles-and-triggers.md#3-triggers)).

---

## Self-check

There is **no `.env.example` in the repository**, so the variable list below was derived from `config/runtime.exs`, `config/config.exs` and every `System.get_env` call under `apps/*/lib` ([AUDIT.md §1.5](../AUDIT.md)). Markdown tables have no per-row anchors; each name links to the section of [configuration.md](configuration.md) whose table holds its row.

### (a) Every environment variable

**Operator release** — [configuration.md A.1](configuration.md#a1-operator-release-troupe_operator):
`TROUPE_OPERATOR_AUTOSTART`, `TROUPE_PLANE_CONTROL_HOST`, `TROUPE_PLANE_CONTROL_PORT`, `TROUPE_PLANE_NAMESPACE`, `TROUPE_BAO_ADDR`, `TROUPE_OBJECT_ENDPOINT`, `TROUPE_OBJECT_BUCKET`, `TROUPE_INGRESS_CLASS`, `TROUPE_WORKERS_TLS_SECRET`, `TROUPE_WORKERS_CERT_ISSUER`, `TROUPE_CILIUM_AVAILABLE`, `TROUPE_MAX_PORTS`, `TROUPE_OBJECT_SECRET_NAME`, `TROUPE_WORKERS_SCHEME`, `TROUPE_WORKERS_PORT`, `TROUPE_DRAIN_TIMEOUT_SECONDS`, `TROUPE_IMAGE_PULL_SECRETS`, `TROUPE_WORKER_ALLOWED_ORIGINS`, `TROUPE_POLICY_NAME`, `TROUPE_KUBE_CONTEXT`, `KUBECONFIG`, `POD_NAME`, `TROUPE_SCHEDULERS`, `ERL_FLAGS`.

**Plane release** — [configuration.md A.2](configuration.md#a2-plane-release-troupe_plane):
`DATABASE_URL`, `TROUPE_DB_SSL`, `TROUPE_DB_CACERT_FILE`, `TROUPE_POOL_SIZE`, `TROUPE_PLANE_AUTOSTART`, `TROUPE_SECRET_KEY_BASE`, `TROUPE_HTTP_PORT`, `TROUPE_HOST`, `TROUPE_BASE_URL`, `TROUPE_OIDC_SCOPES`, `TROUPE_OIDC_MCP_SCOPE`, `TROUPE_CORS_ORIGINS`, `TROUPE_LOG_FORMAT`, `RELEASE_DISTRIBUTION`, `TROUPE_NODE_BASENAME`, `TROUPE_PLANE_SELECTOR`, `TROUPE_PLANE_NAMESPACE`, `POD_IP`, `RELEASE_NODE`, `TROUPE_PLANE_CONTROL_PORT`, `TROUPE_GROUPS_CLAIM`, `TROUPE_SCIM_TOKEN`, `TROUPE_PLATFORM_ADMIN_GROUP`, `TROUPE_PLANE_AUDIENCE`, `TROUPE_PROVISIONING_MODE`, `TROUPE_OIDC_ISSUER`, `TROUPE_OIDC_CLIENT_ID`, `TROUPE_OIDC_CLIENT_SECRET`, `TROUPE_OIDC_AUTHORIZE_URL`, `TROUPE_OIDC_DEVICE_URL`, `TROUPE_OIDC_TOKEN_URL`, `TROUPE_BREAKGLASS_TOKEN`, `TROUPE_BREAKGLASS_SUBJECT`, `TROUPE_BREAKGLASS_LIFETIME_SECONDS`, `TROUPE_BAO_ADDR`, `TROUPE_BAO_TOKEN`, `TROUPE_BAO_AUTH_PATH`, `TROUPE_BAO_ROLE`, `TROUPE_BAO_JWT_PATH`, `TROUPE_OBJECT_ENDPOINT`, `TROUPE_OBJECT_BUCKET`, `TROUPE_OBJECT_ACCESS_KEY_ID`, `TROUPE_OBJECT_SECRET_ACCESS_KEY`, `TROUPE_OBJECT_REGION`, `TROUPE_POLICY_NAME`, `TROUPE_KUBE_CONTEXT`, `KUBECONFIG`, `TROUPE_SCHEDULERS`, `ERL_FLAGS`.

**Worker release** — [configuration.md A.3](configuration.md#a3-worker-release-troupe_worker):
`TROUPE_WORKER_AUTOSTART`, `TROUPE_PLANE_CONTROL`, `TROUPE_POD_ORDINAL`, `TROUPE_PROFILE`, `TROUPE_WORKERS_DOMAIN`, `TROUPE_WORKERS_SCHEME`, `TROUPE_WORKERS_PORT`, `TROUPE_SESSIONS_PER_POD`, `TROUPE_NODE_NAME`, `TROUPE_HTTP_PORT`, `TROUPE_HARNESS_PORT`, `TROUPE_MCP_SERVERS`, `TROUPE_DRAIN_TIMEOUT_SECONDS`, `TROUPE_JWKS_PATH`, `TROUPE_KMS_TOKEN_PATH`, `TROUPE_TOKEN_ISSUER`, `TROUPE_BAO_ADDR`, `TROUPE_BAO_TOKEN`, `TROUPE_BAO_MOUNT`, `TROUPE_OBJECT_ENDPOINT`, `TROUPE_OBJECT_BUCKET`, `TROUPE_OBJECT_ACCESS_KEY_ID`, `TROUPE_OBJECT_SECRET_ACCESS_KEY`, `TROUPE_OBJECT_REGION`, `TROUPE_MAX_FRAME_BYTES`, `TROUPE_ALLOWED_ORIGINS`, `TROUPE_BASE_URL`, `TROUPE_PROVIDER`, `TROUPE_MODEL`, `TROUPE_API_KEY`, `TROUPE_FAKE_SCRIPT`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `TROUPE_SMALL_MODEL` (unread), `TROUPE_NAMESPACE` (unread), `TROUPE_CONFIG_CHANNEL` (unread), `<credentialRef>` per MCP server (default `TROUPE_MCP_<NAME>_TOKEN`), `HOSTNAME`, `TROUPE_SCHEDULERS`, `ERL_FLAGS`.

**A2A release** — [configuration.md A.4](configuration.md#a4-a2a-facade-release-troupe_a2a):
`TROUPE_A2A_AUTOSTART`, `TROUPE_A2A_PUBLIC_URL`, `TROUPE_A2A_PORT`, `TROUPE_A2A_PLANE_URL`, `TROUPE_A2A_MAX_STREAMS`, `TROUPE_A2A_VISIBILITY`, `RELEASE_DISTRIBUTION`, `TROUPE_SCHEDULERS`, `ERL_FLAGS`.

**Daemon and client binary** — [configuration.md A.5](configuration.md#a5-daemon-and-client-binary-troupe):
`TROUPE_DAEMON_AUTOSTART`, `TROUPE_CONFIG_HOME`, `XDG_CONFIG_HOME`, `TROUPE_STATE_HOME`, `XDG_STATE_HOME`, `LOCALAPPDATA`, `APPDATA`, `TROUPE_DAEMON_SOCKET`, `XDG_RUNTIME_DIR`, `TROUPE_DAEMON_COMMAND`, `__BURRITO_BIN_PATH`, `__BURRITO`, `TROUPE_MCP_CONFIG`, `HOME`, `USER`, `USERNAME`, plus the five core LLM overrides and the two OpenBao fallbacks listed there.

**Build-time** — [configuration.md A.6](configuration.md#a6-build-time):
`MIX_ENV`, `RELEASE` → `RELEASE_NAME`, `BURRITO_TARGET`, `TROUPE_REAPER_TARGETS`, `TARGET_ABI`, `TROUPE_REGISTRY`, `TROUPE_IMAGE_TAG`, `TROUPE_PUSH`, `TROUPE_KIND_CLUSTER`.

Variables with no Helm value, called out in [configuration.md A.7](configuration.md#a7-variables-with-two-meanings-and-variables-nobody-reads): `TROUPE_DB_SSL`, `TROUPE_DB_CACERT_FILE`, `TROUPE_POOL_SIZE`, `TROUPE_LOG_FORMAT`, `TROUPE_PLANE_AUDIENCE`, `TROUPE_POLICY_NAME`, `TROUPE_MAX_FRAME_BYTES`, `TROUPE_KUBE_CONTEXT`, `KUBECONFIG`, `TROUPE_BAO_MOUNT`, `TROUPE_HARNESS_PORT`, `TROUPE_NODE_NAME`, `TROUPE_JWKS_PATH`, `TROUPE_TOKEN_ISSUER`, `TROUPE_KMS_TOKEN_PATH`.

### (b) Every Helm value — [configuration.md B.1](configuration.md#b1-every-value)

`namespace`, `imagePullSecrets`, `networkPolicy.enabled`;
`operator.image.repository`, `operator.image.tag`, `operator.image.pullPolicy`, `operator.replicas`, `operator.resources`, `operator.ciliumAvailable`, `operator.ingressClassName`, `operator.workersScheme`, `operator.workersPort`, `operator.workerAllowedOrigins`, `operator.maxPorts`, `operator.certIssuer`, `operator.tlsSecretName`, `operator.drainTimeoutSeconds`;
`plane.enabled`, `plane.image.repository`, `plane.image.tag`, `plane.image.pullPolicy`, `plane.replicas`, `plane.host`, `plane.baseUrl`, `plane.corsOrigins`, `plane.ingressClassName`, `plane.certIssuer`, `plane.tlsSecretName`, `plane.ingress.enabled`, `plane.ingress.bodySize`, `plane.ingress.rateLimit.rps`, `plane.ingress.rateLimit.burstMultiplier`, `plane.ingress.rateLimit.connections`, `plane.resources`, `plane.controlPort`, `plane.httpPort`, `plane.distPort`, `plane.maxPorts`, `plane.provisioningMode`, `plane.platformAdminGroup`, `plane.groupsClaim`, `plane.distribution`, `plane.database.secretName`, `plane.database.secretKey`, `plane.secretKeyBase.secretName`, `plane.secretKeyBase.secretKey`, `plane.oidc.issuer`, `plane.oidc.clientId`, `plane.oidc.authorizeUrl`, `plane.oidc.deviceUrl`, `plane.oidc.tokenUrl`, `plane.oidc.scopes`, `plane.oidc.mcpScope`, `plane.oidc.secretName`, `plane.oidc.secretKey`, `plane.breakglass.secretName`, `plane.breakglass.secretKey`, `plane.breakglass.subject`, `plane.breakglass.lifetimeSeconds`, `plane.scim.enabled`, `plane.scim.secretName`, `plane.scim.secretKey`;
`a2a.enabled`, `a2a.image.repository`, `a2a.image.tag`, `a2a.image.pullPolicy`, `a2a.replicas`, `a2a.host`, `a2a.publicUrl`, `a2a.planeUrl`, `a2a.port`, `a2a.maxStreams`, `a2a.visibility`, `a2a.ingressClassName`, `a2a.tlsSecretName`, `a2a.maxPorts`, `a2a.resources`;
`bao.address`, `bao.authPath`, `bao.planeRole`, `bao.tokenSecretName`, `bao.tokenSecretKey`;
`objectStore.endpoint`, `objectStore.bucket`, `objectStore.region`, `objectStore.secretName`;
`policy.install`, `policy.name`, `policy.allowedImageRepositories`, `policy.maxReplicas`, `policy.maxSessionsPerPod`, `policy.maxResources.cpu`, `policy.maxResources.memory`, `policy.allowedEgress`, `policy.allowedStorageClasses`, `policy.orgVolume`, `policy.namespacePrefix`, `policy.workersDomain`;
`admission.install`.

The three overlays (`charts/troupe/values.small.yaml`, `charts/troupe/values.scaleway.yaml`, `dev/kind/values.yaml`) are compared in [configuration.md B.2](configuration.md#b2-the-three-overlays).

### (c) Every admin method — [roles-and-permissions.md §9](roles-and-permissions.md#9-the-admin-method-table)

`admin.overview`, `admin.profiles.list`, `admin.profile.get`, `admin.profile.put`, `admin.profile.preview`, `admin.profile.delete`, `admin.pod.drain`, `admin.teams.list`, `admin.team.enable`, `admin.team.update`, `admin.team.grant`, `admin.team.revoke`, `admin.team.admin.add`, `admin.team.admin.remove`, `admin.sessions.list`, `admin.session.erase`, `admin.bundles.list`, `admin.bundle.get`, `admin.bundle.validate`, `admin.bundle.publish`, `admin.bundle.retire`, `admin.mcp.check`, `admin.audit.list`, `admin.provisioning.mode`, `admin.settings.list`, `admin.setting.put`, `admin.setting.reset`, `admin.identity.check`, `admin.principals.list`, `admin.principal.create`, `admin.principal.rotate`, `admin.principal.disable`, `admin.triggers.list`, `admin.trigger.put`, `admin.trigger.delete`, `admin.trigger.run`, `admin.runs.list` — 38, each with role, risk, arguments, audit action, console page, CLI command and MCP tool name. The three non-admin harness methods an operator also meets — `trigger.fire`, `session.grant`, `session.review` — are in [bundles-and-triggers.md](bundles-and-triggers.md) and [roles-and-permissions.md §5](roles-and-permissions.md#5-session-roles-and-scopes).

### (d) Every Secret — [configuration.md Part D](configuration.md#part-d--secrets-the-chart-expects)

`troupe-plane-database` (`url`), `troupe-plane-secret-key-base` (`value`), `troupe-plane-oidc` (`client-secret`), `troupe-object-store` (`access-key-id`, `secret-access-key`) in `troupe-system` **and** in every `troupe-w-<profile>`, the break-glass Secret (`token`, name of your choice), `troupe-plane-scim` (`token`), `troupe-bao-token` (`token`, development only), the profile's LLM Secret (`api-key` by default) per worker namespace, `troupe-mcp-<server>` (`token`) per worker namespace, pull secrets in `troupe-system` and every worker namespace, `troupe-plane-tls`, the A2A TLS secret, and the worker TLS secrets (`<profile>-<ordinal>-tls` per pod, or the shared `operator.tlsSecretName`).

### Not covered, and why

- **The GUI's admin guide** (`troupe-gui/docs/admin/README.md`) did not exist when this was written; what the plane must provide for the GUI is in [integrations.md §10](integrations.md#10-the-gui).
- **Hatchet** and any webhook receiver: not in this repository ([bundles-and-triggers.md §3](bundles-and-triggers.md#3-triggers)).
- **Installing per-profile OpenBao worker policies in a cluster**: the code renders them, nothing installs them; the dev manifest installs one wide policy ([integrations.md §2](integrations.md#2-openbao)).
- **The live deployment's actual values, image tags and secrets**: all under the gitignored `.local/` ([AUDIT.md §4.1](../AUDIT.md)).
- **Who consumes `POD_NAME`** on the operator, **whether `admin.team.update`'s advertised `cache_eviction_days`, `pins_allowed`, `volume_size`, `volume_storage_class` are persisted**, and **who restarts a drained pod**: marked Unconfirmed where they appear.
- **`erase_after_days` retention**: recorded on the team, acted on by nothing found ([AUDIT.md §3.5](../AUDIT.md)).
- Every open item in [AUDIT.md §4](../AUDIT.md) that the code could not settle is referenced from the document where it matters rather than answered here.
