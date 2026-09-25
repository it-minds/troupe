# Integrations

Every external system a deployment talks to, and what the code requires of it. Variables
and Helm values are in [configuration.md](configuration.md).

## 1. Identity provider (OIDC)

Troupe is a plain relying party. Of the provider it needs:

| Requirement | Why |
|---|---|
| **Discovery** at `<issuer>/.well-known/openid-configuration`, naming the same issuer, with a `jwks_uri` | tokens are verified against the JWKS, cached and refetched at most once a minute after a bad signature; `iss` is checked exactly |
| **Device authorization grant** for a public client | the TUI signs in from a terminal; the plane publishes the device and token endpoints at `/.well-known/troupe` |
| **Authorization code + client secret** for the console, redirect URI `<base_url>/admin/callback` | the console redeems the code for an `id_token`, so `openid` must be in scope |
| A **group claim** in id tokens (and in access tokens, for MCP) | admin and team membership are read from the claim `groups_claim` names. It is a claim, **not a scope**: asking Entra for a `groups` scope refuses every sign-in (`AADSTS650053`) |
| Redirects for the GUI and for OAuth-capable MCP clients (loopback) | both sign in in a browser |
| For MCP: `<base_url>/mcp` as an identifier URI beside `api://<client_id>`, the delegated scope `<base_url>/mcp/admin` (or `plane.oidc.mcpScope`), groups on access tokens | an MCP client sends `https://<plane>/mcp` as RFC 8707's `resource`, and Entra refused the older `api://<client-id>/admin` pairing (`AADSTS9010010`) |

Default scopes are `openid profile email offline_access`; `offline_access` is what gets a
client a refresh token. `subject_claim` names the claim that is the person (`sub`; `oid` for
Entra with SCIM, whose `sub` is pairwise). `admin.identity.check` runs four timed checks —
discovery names the same issuer, the JWKS has keys, the configured endpoints match
discovery, and how many known people carry the admin group (and whether you do) — and
prints the redirect URI to compare with the registration by eye. With a group argument it
tests a candidate before you save it. The console's **Identity provider** card configures
all of this at runtime, behind the same check. Authentik specifically:
[authentik.md](authentik.md).

## 2. OpenBao

| Piece | Requirement |
|---|---|
| **Transit** at `transit`, key `troupe-session-tokens`, `ecdsa-p256`, not exportable | the plane signs plane tokens with it and publishes every key version as its JWKS |
| **KV v2** at `secret` | per-session data keys at `troupe/teams/<team>/sessions/<id>`; erasure deletes the metadata path so every version goes |
| **Kubernetes auth** at `kubernetes`, with a **reviewer JWT** (a ServiceAccount bound to `system:auth-delegator`) | without one every login is `permission denied` and nothing says why |
| Role `troupe-worker` (ServiceAccount `troupe-worker`, any namespace, audience `troupe-kms`) | worker pods log in with their projected `kms-token` |
| Role `troupe-plane` (ServiceAccount `troupe-plane` in `troupe-system`), with the plane **and** signing policies | the plane logs in with its projected `bao-token`, caches the client token, retries a 403 once after a fresh login |

The policies are in [roles-and-permissions.md §8](roles-and-permissions.md#8-openbao-policies);
the commands, in development shape, in `dev/kind/dependencies.yaml`. A plane with neither
a static token nor a readable projected token logs one error naming both and answers
`/.well-known/jwks.json` with 503.

`deploy/scaleway/openbao.values.yaml` runs **one replica** with Raft and a **Shamir seal
with a single share kept in a Kubernetes Secret and unsealed by a sidecar**, because
Scaleway Key Manager speaks none of OpenBao's seal APIs; the file says what that protects
(a stolen volume) and what not (a cluster admin). Live sessions survive an OpenBao restart
because a worker holds its key in memory; nothing can be *opened* until it is back. There
are no Raft snapshots ([backup-restore.md](backup-restore.md)).

## 3. PostgreSQL

- `DATABASE_URL` from `troupe-plane-database`. TLS only with `TROUPE_DB_SSL=true`; pool
  `TROUPE_POOL_SIZE`, 10 per replica plus the migration Job's — lower it for a small managed
  instance. Neither has a Helm value.
- Migrations run in a Helm `pre-install,pre-upgrade` hook Job, `troupe-plane-migrate`
  (kept with its logs on failure), never at boot. `Troupe.Plane.Release.rollback/2` exists;
  nothing calls it.
- No extensions. Session content is never stored here. Managed PostgreSQL with PITR is
  the recommendation.

## 4. Object storage (S3)

- S3 with SigV4. Layout `sessions/<id>/{manifest.json, segments/…, snapshots/…,
  workspace/…, blobs/…}`: segments AES-256-GCM under a per-session key, manifests plaintext.
  Workers write (seal every 60 s and at a turn's end, snapshot every 500 events, archive the
  workspace at dormancy); the plane reads manifests only to rebuild its index.
- **Versioning must be on.** Erasure destroys the key first, then every version; without
  versioning "every version" means nothing.
- Credentials `troupe-object-store` in `troupe-system` **and every worker namespace**.
- `TROUPE_OBJECT_REGION` reaches the plane only; workers sign for `us-east-1`.
- No lifecycle or replication rules are configured by anything here.

## 5. LLM gateway

Troupe keeps no price table of its own; a profile names any OpenAI-compatible or Anthropic
endpoint, and, for models that endpoint does not price, `llm.prices`.

- Per profile: `llm.endpoint`, `llm.provider`, `llm.model`, and `llm.secretRef` for the key
  ([profiles-and-policy.md §1](profiles-and-policy.md#1-what-an-administrator-sets)). The
  endpoint's host must be in `allowedEgress`.
- `openai` posts to `<endpoint>/v1/chat/completions` with a bearer token and
  `stream_options.include_usage`; `anthropic` to `/v1/messages` with `x-api-key`. `/v1` is
  not doubled.
- The request id comes from `x-litellm-call-id` or `x-request-id`, the cost from
  `x-litellm-response-cost`. A streamed response carries no cost header, because the
  headers go out before the first token, so the pod prices the call from the profile's
  `llm.prices` and marks it `priced_locally`. Without either the cost is 0, the pod's log
  says so once a session, and without an id the id is synthetic.
- `mix troupe.ledger.reconcile` compares a window of recorded usage with the gateway's
  `GET /spend/logs` by request id and exits non-zero over 1 000 000 micros of drift. It
  reads `:troupe_plane, :gateway` (`base_url` or `spend_url`, and `key`), which no
  configuration here sets, so it answers `:no_gateway_configured` until someone does.

## 6. Kubernetes

| Item | Requirement |
|---|---|
| CNI | one that enforces NetworkPolicy (kind's does not, silently); Cilium for egress by hostname |
| Version | ≥ 1.30 for `ValidatingAdmissionPolicy`; `admission.install: false` leaves the operator's check alone. CI validates the chart against 1.31 |
| CRDs | installed by Helm once and never upgraded: apply `charts/troupe/crds/` on every upgrade |
| ingress-nginx | `deploy/scaleway/ingress-nginx.values.yaml`; then label its namespace `troupe.dev/ingress=true` |
| cert-manager | `deploy/scaleway/cluster-issuer.yaml`: ClusterIssuer `letsencrypt`, HTTP-01, one certificate per pod hostname, no wildcard |
| Storage classes | on Scaleway `scw-bssd` (block) for pod disks, `scw-sfs` (RWX) for team volumes, `sbs-default` for OpenBao; the policy lists what profiles may name |

## 7. MCP

**Servers a bundle declares** (Troupe as client) are declared once in the bundle, projected
onto the profile by the plane, injected by the operator, and discovered by the pod over
streamable HTTP. The operator provides the `troupe-mcp-<server>` Secret in each worker
namespace and the host in `allowedEgress` ([bundles-and-triggers.md §1](bundles-and-triggers.md#1-config-bundles)).

**The plane as an MCP server** (`POST /mcp`): every admin method as a tool, the same actor
as `/rpc`, no session content. An OAuth-capable client needs only the URL and the app
registration's client id:

```bash
claude mcp add --transport http troupe https://<plane>/mcp --client-id <app registration> --callback-port 33418
```

It learns where to authenticate from the 401's `WWW-Authenticate … resource_metadata=` and
the RFC 9728 document at `/.well-known/oauth-protected-resource`. Destructive tools need
`confirm`.

## 8. SCIM

| Item | Detail |
|---|---|
| Endpoints | `/scim/v2/Users[/:id]` and `/scim/v2/Groups[/:id]`: create, list with a filter, replace, patch, delete |
| Token | minted on the console's Identity provider card (`admin.scim.rotate`, shown once, kept as a salted hash), or the deployment's `TROUPE_SCIM_TOKEN`. Either opens the door; neither, and every request is 401 |
| Status | `admin.scim.get`: the last authorised request; `teams_from_groups` (off by default) makes a pushed group a team |
| Semantics | the subject is `externalId`, else `userName`, and must match what sign-in uses; membership is replaced per push; deleting a user deactivates it, deleting a group empties it; one `<attribute> eq "<value>"` filter, anything else refused; no pagination, bulk or `/Schemas` |
| Without SCIM | sign-in builds the same rows from the group claim; a person who has left is only noticed at their next sign-in |

## 9. The GUI

The chart serves `clients/gui` at `gui.basePath` (`/app`) on the plane's host — same
origin, so no CORS entry. A GUI served from anywhere else needs its origin in
`plane.corsOrigins` and `operator.workerAllowedOrigins`, and its redirect registered at the
identity provider, which also has to allow its origin for the device grant. The plane
answers CORS on `/.well-known/<doc>` paths, not on
`/.well-known/oauth-protected-resource/mcp`.
