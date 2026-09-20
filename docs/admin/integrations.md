# Integrations

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).
>
> Commit `4083b1f` (`TROUPE_OIDC_MCP_SCOPE`, `plane.oidc.mcpScope`) landed while this track was being written and is covered; line numbers are from that tree. Unprefixed plane modules are under `apps/troupe_plane/lib/troupe/plane/`.

Every external system a Troupe deployment talks to, with what the code requires of it. Variables and Helm values are in [configuration.md](configuration.md); step lists in [routine-tasks.md](routine-tasks.md).

---

## 1. Identity provider (OIDC)

Troupe is a plain relying party. Four things are required of the provider (`values.scaleway.yaml:77-80`; `oidc.ex:1-15`):

| Requirement | Why | Source |
|---|---|---|
| **Discovery** at `<issuer>/.well-known/openid-configuration` with a `jwks_uri` | provider tokens are verified against the published JWKS; the plane caches it in `persistent_term` and refetches at most once a minute after a bad signature | `oidc.ex:143-219` |
| The `issuer` in discovery equal to `TROUPE_OIDC_ISSUER` | `iss` is checked on every token | `oidc.ex:175-179,259-271` |
| **Device authorization grant** for a public client | `troupe login` runs in a terminal and polls; the plane publishes `device_authorization_endpoint` and `token_endpoint` at `/.well-known/troupe` | `web/router.ex:63-77`; `values.scaleway.yaml:78-80` |
| **Authorization code + client secret** for the console, redirect URI `<base_url>/admin/callback` | the console verifies an `id_token` redeemed with `client_secret`; `openid` must be in scope or no id_token is issued | `web/admin_auth.ex:128-169,308-341` |
| A **group claim** in the token (id_token for the console and CLI; access token for MCP) | `platform_admin_group` and team membership are read from the claim named by `groups_claim` (default `groups`). **Group membership is a claim the provider is configured to emit, not a scope**: asking for `groups` as a scope makes Entra refuse with `AADSTS650053` | `login.ex:63-71`; `web/router.ex:48-59`; commit `6c29471` |
| A SPA/loopback redirect for the GUI and MCP clients | the GUI and an OAuth-capable MCP client authenticate in the browser | `docs/plans/admin-surface.md:87-90`; troupe-gui repository |
| Audiences `client_id`, `api://<client_id>` **and** `<base_url>/mcp` accepted for `/mcp`; the MCP scope is `<base_url>/mcp/admin` unless `TROUPE_OIDC_MCP_SCOPE` says otherwise | an id_token is addressed to the client, an access token to the API under whichever identifier URI the client asked for; all three are identifier URIs of one registration. The scope is named after the resource because an MCP client must send `https://<plane>/mcp` as RFC 8707's `resource`, and Entra refused the old `api://<client-id>/admin` pairing with `AADSTS9010010` (commit `4083b1f`) | `oidc.ex:95-120`; `web/router.ex:311-338`; `values.yaml:150-154` |

Default scopes are `openid profile email offline_access` (`web/router.ex:59`); the console asks for `openid profile email` unless `TROUPE_OIDC_SCOPES` says otherwise (`web/admin_auth.ex:321`). `offline_access` is what gets the CLI a refresh token (`web/router.ex:327-329`).

**Entra specifics visible in the repository**: the values placeholders use `/oauth2/v2.0/{authorize,devicecode,token}` (`values.small.yaml:101-105`); `admin.identity.check` exists partly for "an Entra tenant configured with a v2 issuer and a v1 token endpoint" (`oidc.ex:303-305`); for MCP the app registration needs an App ID URI, one delegated scope, access tokens at version 2, the `groups` claim on access tokens as well as id tokens, and the client's loopback redirect — scripted for the IT Minds tenant in the gitignored `.local/scaleway/entra-expose-mcp-api.sh` (`docs/plans/admin-surface.md:87-90`). `groups_claim` is `groups` on Entra; some providers use `roles` (`settings.ex:66-68`).

**Check it**:

```bash
troupe admin identity check
```

Four checks with timings: discovery answers and names the same issuer; the JWKS has keys; the configured token and device endpoints match what discovery publishes; and how many known people carry the platform-admin group, and whether you are one (`oidc.ex:221-345`; `admin.ex:494-570`). `troupe admin identity check <group>` tests a candidate group before you save it. The response also prints the redirect URI to compare against the registration by eye, because nothing can prove it from here (`oidc.ex:232-235`; `admin.ex:526-530`).

**Discrepancy**: `docs/deploying-on-scaleway.md:56-57` lists "a `groups` claim" among the four requirements, which is right, but `values.scaleway.yaml:79` and the older discovery document asked for `groups` as a scope; the default no longer does.

---

## 2. OpenBao

Two engines, three policies, two auth roles.

| Piece | Requirement | Source |
|---|---|---|
| **Transit** engine mounted at `transit` with key `troupe-session-tokens`, type `ecdsa-p256`, not exportable | the plane signs plane tokens with `POST /v1/transit/sign/troupe-session-tokens` (`marshaling_algorithm: jws`) and publishes the JWKS from `GET /v1/transit/keys/troupe-session-tokens` (every version) | `tokens.ex:28,71-146,208-209`; `dev/kind/dependencies.yaml:231-232` |
| **KV v2** mounted at `secret` (`TROUPE_BAO_MOUNT`) | per-session data keys at `troupe/teams/<team>/sessions/<id>`; erasure deletes the metadata path so every version goes | `apps/troupe_protocol/lib/troupe/kms/open_bao.ex:1-58,124` |
| **Kubernetes auth** at mount `kubernetes` (`TROUPE_BAO_AUTH_PATH`), configured with a **reviewer JWT** — a ServiceAccount bound to `system:auth-delegator` | without one OpenBao reviews a token with the token itself and every login is `permission denied` with nothing in any log | `dev/kind/dependencies.yaml:185-242`; `docs/deploying-on-scaleway.md:159-163` |
| Role `troupe-worker`: bound SA `troupe-worker`, any namespace, `audience=troupe-kms`, the worker policy | worker pods log in with the projected `kms-token` at `/var/run/secrets/troupe/kms-token` | `dependencies.yaml:261-266`; `open_bao.ex:126-142`; `runtime.exs:378-379` |
| Role `troupe-plane`: bound SA `troupe-plane` in `troupe-system`, the plane policy plus signing | the plane logs in with the projected `bao-token` (audience `troupe-kms`, 3600 s) and caches the client token until 60 s before its lease ends; a 403 is retried once after a fresh login | `dependencies.yaml:268-272`; `tokens/credential.ex:1-24,32-33,116-141`; `plane-deployment.yaml:373-382` |
| Policies | `Troupe.KMS.Policy.worker/2`, `plane/1`, `signing/2` — see [roles-and-permissions.md §8](roles-and-permissions.md#8-openbao-policies) | `apps/troupe_protocol/lib/troupe/kms/policy.ex` |

The dev role for the plane at `dependencies.yaml:268-272` attaches only the `troupe-plane` KV policy; the signing policy on `transit/*` is not attached there because the dev root token is used. A production role for the plane needs **both** `Troupe.KMS.Policy.plane/1` and `Troupe.KMS.Policy.signing/2`. The dev manifest also installs one wide worker policy over `teams/+/` rather than the per-profile policy the code renders; nothing in the repository installs per-profile policies in a cluster — that is a manual or external step. Unconfirmed how the live deployment does it ([AUDIT.md §4.7](../AUDIT.md)).

**Static token** (`TROUPE_BAO_TOKEN`, `bao.tokenSecretName`): development only (`values.yaml:220-223`). A plane with neither a static token nor a readable projected JWT logs one error naming both options and answers `/.well-known/jwks.json` with 503 (`tokens/credential.ex:19-23,128-140`; `web/router.ex:93-98`).

**Seal and replicas — the reality vs the guide**: `deploy/scaleway/openbao.values.yaml` runs **one replica** with Raft, `tls_disable = 1`, an 8Gi `sbs-default` volume, **Shamir seal with a single share kept in a Kubernetes Secret and unsealed by a sidecar**, audit device off, UI, injector and CSI off (`openbao.values.yaml:11-33,35-98`). Discrepancy: `docs/deploying-on-scaleway.md:41-44,156` says three replicas and auto-unseal via Scaleway Key Manager; the values file explains why that is not possible (Key Manager speaks none of OpenBao's seal APIs). What the single-share seal protects — a stolen PVC — and does not — cluster admin — is stated at `openbao.values.yaml:28-33`. Live sessions survive an OpenBao restart because a worker holds its key in memory; a session cannot be *opened* until it is back (`:13-18`). There are **no Raft snapshots** in the repository ([backup-restore.md](backup-restore.md)).

Install command: `openbao.values.yaml:3-5`.

---

## 3. PostgreSQL

| Item | Detail | Source |
|---|---|---|
| Connection | `DATABASE_URL` as `ecto://user:pass@host:port/db`, from Secret `troupe-plane-database` key `url` | `runtime.exs:143,176-179`; `docs/deploying-on-scaleway.md:177` |
| TLS | off unless `TROUPE_DB_SSL=true`, which verifies the server against `TROUPE_DB_CACERT_FILE` or the OS roots with SNI = the URL's host and HTTPS wildcard matching. **No Helm value** for either | `runtime.exs:144-169` |
| Pool | `TROUPE_POOL_SIZE`, 10 **per replica** plus the migration Job's; a small managed instance that allows 25 needs it lowered. **No Helm value** | `runtime.exs:171-178` |
| Migrations | a Helm `pre-install,pre-upgrade` hook Job `troupe-plane-migrate` (weight −5, `backoffLimit: 1`, kept on failure) runs `/app/bin/troupe_plane eval "Troupe.Plane.Release.migrate()"`; never from application boot | `plane-deployment.yaml:35-118`; `release.ex:1-25` |
| Rollback | `Troupe.Plane.Release.rollback(Troupe.Plane.Repo, <version>)` via `bin/troupe_plane eval`; nothing calls it | `release.ex:27-32` |
| Schema | 20 tables from 11 migrations under `apps/troupe_plane/priv/repo/migrations/` (identity, fleet, sessions, ledger and audit, team admins, bundle summary, session status, service principals, triggers, usage watermark, platform settings); primary keys `binary_id`, timestamps `utc_datetime_usec` | `config/config.exs:57-59`; [AUDIT.md §1.4](../AUDIT.md) |
| Extensions | none — no migration runs `CREATE EXTENSION` | grep of `priv/repo/migrations/*.exs` |
| Versions | CI and docker-compose use `postgres:16`; the kind manifest `postgres:18.1-bookworm`. Unconfirmed which major the live plane runs | `dev/kind/dependencies.yaml:77`; [AUDIT.md §4](../AUDIT.md) |
| Never stored | session content (`repo.ex:5-8`) | |

What the database is authoritative for, and what it is not, is in [backup-restore.md](backup-restore.md). Managed PostgreSQL with PITR is the guide's recommendation (`docs/deploying-on-scaleway.md:19,149`).

---

## 4. Object storage (S3)

| Item | Detail | Source |
|---|---|---|
| Protocol | S3 with SigV4 (`Troupe.ObjectStore`); endpoint, bucket, key id, secret, region from `TROUPE_OBJECT_*` | `runtime.exs:73-89`; `apps/troupe_protocol/lib/troupe/object_store.ex` |
| Layout | `sessions/<id>/{manifest.json, segments/<epoch>-<first>-<last>.seg, snapshots/<seq>.snap, workspace/<seq>.<ext>, blobs/<sha>}`; segments are AES-256-GCM under a per-session key, manifests plaintext | [AUDIT.md §1.4](../AUDIT.md); `apps/troupe_protocol/lib/troupe/sessions/storage.ex` |
| Who writes | workers (seal every 60 s and at turn end, snapshot every 500 events, archive workspace at dormancy); the plane reads manifests only in `mix troupe.index.rebuild` | `apps/troupe_worker/lib/troupe/worker/session/sealer.ex:28-31`; `apps/troupe_plane/lib/mix/tasks/troupe.index.rebuild.ex` |
| **Versioning must be on** | erasure destroys the key first, then deletes every version; a bucket without versioning makes "every version" vacuous rather than false | `values.scaleway.yaml:118-121`; `docs/deploying-on-scaleway.md:71-76`; `erasure.ex:5-11`; `dev/kind/dependencies.yaml:129-150` |
| Credentials in **two namespaces** | Secret `troupe-object-store` with `access-key-id` and `secret-access-key` in `troupe-system` (plane, optional) **and in every `troupe-w-<profile>`** (workers, optional in the spec but required to work) | `plane-deployment.yaml:317-330`; `resources.ex:595-610` |
| Region | `TROUPE_OBJECT_REGION` reaches the plane only; workers always sign for `us-east-1` | `plane-deployment.yaml:259-260`; `resources.ex:532-585` |
| Lifecycle, replication | nothing in the repository | [AUDIT.md §4.8](../AUDIT.md) |

Scaleway: `https://s3.fr-par.scw.cloud`, region `fr-par` (`values.scaleway.yaml:122-126`).

---

## 5. LLM gateway

Troupe has no price table and calls whatever OpenAI-compatible or Anthropic endpoint a profile names (`ARCHITECTURE.md:924-930`).

| Item | Detail | Source |
|---|---|---|
| Per profile | `llm.endpoint` → worker `TROUPE_BASE_URL`; `llm.provider` (`openai` = Chat Completions, which a LiteLLM gateway serves; `anthropic`; `fake`); `llm.model` → `TROUPE_MODEL`; `llm.secretRef` → `TROUPE_API_KEY` from a Secret in the worker namespace, key `api-key` | `crds/workerprofile.yaml:46-63`; `resources.ex:618-647` |
| Request | `openai`: `POST <endpoint>/v1/chat/completions` with `Authorization: Bearer`, `stream_options.include_usage`, `user` = the session owner; `anthropic`: `POST /v1/messages` with `x-api-key`. `/v1` is not doubled if already present | core/worker audit notes; `apps/troupe_core/lib/troupe/llm/providers/{openai,anthropic}.ex` |
| Cost and request id | read from response **headers** once in the shared HTTP path: `x-litellm-call-id` or `x-request-id` → `request_id`; `x-litellm-response-cost` → `cost_micros`. Absent → cost 0 and synthetic id `seq:<session>:<n>` | `apps/troupe_core/lib/troupe/llm/message.ex:57-60`; `ARCHITECTURE.md:915-930` |
| Egress | the endpoint's host must be in `TroupePolicy.allowedEgress` (`llm-gw.itmindsinternal.dk` in both Scaleway files) and, with Cilium, is an FQDN rule | `values.scaleway.yaml:141-144`; `apps/troupe_protocol/lib/troupe/worker_profile.ex:171-179` |
| Reconciliation | `mix troupe.ledger.reconcile` fetches `GET <base_url>/spend/logs?start_date&end_date` with `Authorization: Bearer <key>` and compares by request id. It reads `Application.get_env(:troupe_plane, :gateway)` — `%{base_url or spend_url, key}` — **which nothing in the repository sets**, so the task answers `could not reach the gateway: :no_gateway_configured` until it is configured by hand (a release config overlay or `bin/troupe_plane eval`) | `reconcile.ex:185-222`; `lib/mix/tasks/troupe.ledger.reconcile.ex:37-40`; [AUDIT.md §3](../AUDIT.md) (plane note) |
| Unverified | `x-litellm-response-cost` on **streamed** responses is assumed present; not tested against a gateway | [AUDIT.md §3.17](../AUDIT.md) |

The kind bring-up uses `TROUPE_GATEWAY_URL` default `https://llm-gw.itmindsinternal.dk/v1`, model `code-default` and a Secret `llm-credentials` filled from `ITM_LLM_GW_KEY` (`scripts/remote-up`; `dev/kind/dependencies.yaml:44-52`).

---

## 6. Kubernetes

| Item | Requirement | Source |
|---|---|---|
| Cluster | Kapsule with **Cilium** in the guide; any CNI that enforces `NetworkPolicy` works, kind's does not and says nothing | `docs/deploying-on-scaleway.md:18,112`; `values.yaml:18-21` |
| Version | `ValidatingAdmissionPolicy` is GA from **1.30**; `admission.install: false` falls back to the operator's check alone. CI validates the rendered chart against 1.31.0 with kubeconform | `values.yaml:251-255`; `.github/workflows/ci.yml` (chart job) |
| CRDs | `charts/troupe/crds/*.yaml`, installed by Helm on first install and **never upgraded**; apply them yourself on every upgrade | `values.yaml:5-9`; `docs/deploying-on-scaleway.md:322-324` |
| ingress-nginx | `deploy/scaleway/ingress-nginx.values.yaml`: one replica, LB-S with PROXY protocol v2, `proxy-read/send-timeout 3600`, `proxy-body-size 16m`; then label the namespace `troupe.dev/ingress=true` | `ingress-nginx.values.yaml:1-62` |
| cert-manager | `deploy/scaleway/cluster-issuer.yaml`: ClusterIssuer `letsencrypt`, ACME HTTP-01 over the `nginx` class, one certificate per pod hostname. No DNS-01 solver, so no wildcard | `cluster-issuer.yaml:1-30` |
| Storage classes | Scaleway: `scw-bssd` (block, RWO) for pod disks, `scw-sfs` (File Storage, RWX) for team volumes, `sbs-default` for OpenBao; the policy must list what profiles may name | `values.scaleway.yaml:145-151`; `openbao.values.yaml:38-42` |
| Labels | `troupe.dev/ingress=true` on the ingress namespace (yours), `troupe.dev/workers=true` on worker namespaces (operator's) | [configuration.md Part E](configuration.md#part-e--ports-and-network-policy) |
| RBAC | [roles-and-permissions.md §7](roles-and-permissions.md#7-kubernetes-rbac-the-chart-grants) | |

---

## 7. MCP servers

Two directions.

**Servers a bundle declares** (Troupe as client): declared once in the bundle, projected onto the profile CR by the plane, injected by the operator as `TROUPE_MCP_SERVERS` plus one optional env var per credential, discovered by the pod with `tools/list` over streamable HTTP (protocol `2025-06-18`), allowlisted at discovery. What the operator has to provide: the Secret `troupe-mcp-<server>` key `token` in each worker namespace, and the host in `allowedEgress`. Details in [bundles-and-triggers.md §1](bundles-and-triggers.md#1-config-bundles).

**The plane as an MCP server** (`POST /mcp`, `admin/mcp.ex`): every admin method as a tool, same actor as `/rpc`, no session, no streaming. Two ways to connect a model (`ARCHITECTURE.md:637-642`; `apps/troupe_ctl/lib/troupe/ctl/mcp.ex:1-12`):

```bash
claude mcp add --transport http troupe https://<plane>/mcp --client-id <app registration> --callback-port 33418
```

```bash
claude mcp add troupe -- troupe mcp
```

The first does OAuth against the identity provider — the app registration must carry `<base_url>/mcp` as an identifier URI alongside `api://<client_id>`, expose the delegated scope `<base_url>/mcp/admin` (or the name you set in `plane.oidc.mcpScope`), put the group claim on access tokens and allow the loopback redirect (§1; `web/router.ex:311-338`) — and the client learns where to authenticate from the 401's `WWW-Authenticate: … resource_metadata=` and the RFC 9728 document at `/.well-known/oauth-protected-resource[/mcp]` (`web/router.ex:79-91,279-338`). The second bridges stdio to `/mcp` with the plane token `troupe login` can mint, renewed every 10 minutes (`ctl/mcp.ex:45,148-160`). The tool list is not filtered by role; destructive tools need `confirm` (`admin/mcp.ex:17-36`).

---

## 8. SCIM

| Item | Detail | Source |
|---|---|---|
| Endpoints | `GET/POST /scim/v2/Users`, `GET/PUT/PATCH/DELETE /scim/v2/Users/:id`, `GET/POST /scim/v2/Groups`, `PUT/PATCH /scim/v2/Groups/:id` | `web/router.ex:168-177,342-408` |
| Token | Rotated on the console's **Identity provider** card (`admin.scim.rotate`), kept as a salted hash on the `scim_connector` row and shown once; *or* `TROUPE_SCIM_TOKEN` from Secret `troupe-plane-scim` key `token` when `plane.scim.enabled: true`. Either opens the door; neither set → every SCIM request is 401 | `scim/connector.ex`; `web/router.ex` `scim_authorised?/1`; `plane-deployment.yaml:296-302` |
| Status | `admin.scim.get`: `last_seen_at`/`last_seen_op` stamped on an authorised request at most once a minute; `teams_from_groups` makes a pushed group a team on arrival (off by default) | `scim/connector.ex`; `scim.ex` `maybe_enable_team/1` |
| Semantics | the subject is `externalId`, else `userName` — it must be what later appears as `sub`; group membership is **replaced** per push; `DELETE` deactivates rather than deletes; list responses are unpaginated | `scim.ex:1-15,36-73,109-119` |
| Without SCIM | `Login.from_claims/1` builds the same rows from the token's group claim at every sign-in; both paths end in `Identity` so the teams are the same | `login.ex:1-14` |

---

## 9. Hatchet and webhooks

Not in this repository. Webhook triggers (`source.kind: webhook`) expect an external executor to receive the webhook and call `trigger.fire` with an idempotency key; Hatchet is the executor the prose names, and no client, chart or manifest for it exists here ([bundles-and-triggers.md §3](bundles-and-triggers.md#3-triggers); [AUDIT.md §3.11, §4.18](../AUDIT.md)).

---

## 10. The GUI

The browser client lives in a separate repository (`troupe-gui`). What this deployment must provide for it (`troupe-gui/docs/AUDIT.md:85`): its origin in `plane.corsOrigins` → `TROUPE_CORS_ORIGINS` (exact origin, comma-separated; `runtime.exs:265-270`; `web/cors.ex`), its origin in `operator.workerAllowedOrigins` → `TROUPE_ALLOWED_ORIGINS` on every worker pod (`resources.ex:589-593`), a SPA redirect registered at the identity provider, and — if it is served from the same ingress — a host of its own (port 8080 in that repository, not in this chart). The plane's CORS plug answers only two-segment `/.well-known/<doc>` paths, not `/.well-known/oauth-protected-resource/mcp` (plane audit note 14). Its admin guide is meant to be at [../../../troupe-gui/docs/admin/README.md](../../../troupe-gui/docs/admin/README.md); that file did not exist when this was written.
