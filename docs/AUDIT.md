# Documentation audit — troupe-remote

Audited against commit `4083b1f` on branch `main`, 2026-09-13. The audit began at
`3f7c91f` with five uncommitted files whose single functional change was the
`plane.oidc.scopes` → `TROUPE_OIDC_SCOPES` override and the removal of `groups` from the
default OIDC scope list; that change was committed as `6c29471` while the documents were
being written. A further commit, `4083b1f`, then renamed the MCP scope advertised in the
RFC 9728 document from `api://<client_id>/admin` to `<base_url>/mcp/admin`, added
`TROUPE_OIDC_MCP_SCOPE` (Helm `plane.oidc.mcpScope`) to override it, and added
`<base_url>/mcp` as a third accepted audience for provider tokens at `POST /mcp`
(`config/runtime.exs`, `charts/troupe/values.yaml`,
`charts/troupe/templates/plane-deployment.yaml`, `apps/troupe_plane/lib/troupe/plane/web/router.ex`,
`apps/troupe_plane/lib/troupe/plane/oidc.ex`). Line citations in every track were re-based
on `4083b1f`; the variable counts in §1.5 below were taken before it and are one short for
the plane — [admin/configuration.md](admin/configuration.md) is the authoritative list.

This file is the Phase 1 output: what the repository actually contains, what could not be
confirmed from code, and where the existing prose disagrees with the code. The four
documentation tracks under `docs/` were written from it. Nothing in this file is a
recommendation; it is an inventory.

---

## 1. Inventory

### 1.1 Umbrella apps and releases

Nine Mix apps under `apps/`, five releases in `mix.exs:44-101`. `ARCHITECTURE.md:19-30` still
says "four releases" and eight apps; `troupe_a2a` was added in stage 5.

| App | In release(s) | Responsibility | Depends on (in umbrella) |
|---|---|---|---|
| `troupe_protocol` | all | Wire format, events + hash chain, JSON-RPC, error table, reference Elixir client, endpoint discovery, token verification, bundle + agent-definition parsing, KMS (OpenBao) client, S3 object store and session storage layout, MCP client, `TroupePolicy`/`WorkerProfile` parsing, schema gen/diff tasks | — |
| `troupe_core` | `troupe`, `troupe_worker` | Sessions: agent state machine, tools, durable log, index, providers, compaction, budgets, watch mode, sandbox, reaper, skills, usage fold | `troupe_protocol` |
| `troupe_gateway` | `troupe`, `troupe_worker` | The daemon: transports (Unix socket, loopback TCP, WebSocket), connections, subscriptions, scopes, idempotency, worktrees | `troupe_core`, `troupe_protocol` |
| `troupe_tui` | `troupe` | Terminal UI, now the protocol test harness (`README.md:318-322`) | `troupe_protocol` |
| `troupe_ctl` | `troupe` | CLI: local commands, `login`, `--remote`, `admin`, `mcp`, `daemon` | `troupe_protocol` |
| `troupe_worker` | `troupe_worker` | A pod: plane link, sealing, restore, auth, bundles, MCP discovery, usage sink, drain, disk | `troupe_core`, `troupe_protocol`, `troupe_gateway` |
| `troupe_plane` | `troupe_plane` | Control plane: Phoenix/Bandit endpoint, OIDC relying party, harness API `/rpc`, admin context with four renderings, control channel to workers, ledger, triggers, settings | `troupe_protocol` |
| `troupe_operator` | `troupe_operator` | Bonny operator reconciling `WorkerProfile`/`TeamVolume` into namespaces of pods | `troupe_protocol` |
| `troupe_a2a` | `troupe_a2a` | A2A facade: every profile as an agent; client of `/rpc` and worker sockets only | `troupe_protocol` |

Boundaries are enforced by `mix troupe.boundaries`
(`apps/troupe_core/lib/mix/tasks/troupe.boundaries.ex:29-51`): `troupe_tui`, `troupe_ctl`,
`troupe_a2a` may call only `troupe_protocol`; `troupe_plane` never calls `troupe_core` or
`troupe_gateway`; `troupe_operator` never calls `troupe_core`, `troupe_gateway` or
`troupe_plane`; `Troupe.Plane.Web.Live.*` may call only `Troupe.Plane.Admin` among
`Troupe.Plane.*`.

Detailed module inventories, per app, are in the track documents:
[developer/architecture.md](developer/architecture.md) and [whitepaper.md](whitepaper.md).

### 1.2 HTTP and socket surfaces

**Plane** (`apps/troupe_plane/lib/troupe/plane/web/router.ex`, `admin_router.ex`, `endpoint.ex`):

| Surface | Auth | Notes |
|---|---|---|
| `GET /healthz` | none | liveness |
| `GET /.well-known/troupe` | none | discovery for clients: issuer, client id, device/token endpoints, scopes, `plane.rpc`, `plane.jwks`, protocol version |
| `GET /.well-known/jwks.json` | none | plane token keys from OpenBao transit; 503 if OpenBao unreachable |
| `GET /.well-known/oauth-protected-resource[/mcp]` | none | RFC 9728 document for MCP clients |
| `POST /auth/exchange` | credential in body | `{id_token}` or `{client_id, client_secret}` → plane token (≤ 15 min) |
| `POST /rpc` | plane bearer token | harness API + `admin.*` methods |
| `POST /mcp` | plane token **or** provider token | admin methods as MCP tools; `GET`/`DELETE` are 405 |
| `/scim/v2/Users[/:id]`, `/scim/v2/Groups[/:id]` | static SCIM bearer | 401 unless `TROUPE_SCIM_TOKEN` set |
| `/admin/login`, `/callback`, `/denied`, `/logout` | browser | authorization-code login with client secret |
| `GET`/`POST /admin/breakglass` | token in form | 404 unless `TROUPE_BREAKGLASS_TOKEN` is configured |
| `/admin`, `/admin/workers[/:profile]`, `/admin/teams`, `/admin/sessions`, `/admin/bundles`, `/admin/triggers[/:team]`, `/admin/audit`, `/admin/settings` | cookie; platform admin, team admin or live break-glass | LiveView console |
| `/admin/profile/new`, `/admin/profile/:profile` | platform admin only | profile editor |
| `/live` | cookie | LiveView socket |
| TCP `:4001` (control) | Kubernetes `TokenReview` | worker control channel, NDJSON JSON-RPC, never through ingress |

**Worker pod** (`apps/troupe_worker/lib/troupe/worker/harness.ex`, `apps/troupe_gateway/lib/troupe/gateway/web.ex`):
`GET /health/live`, `GET /health/ready` (503 while draining), `GET /v1/socket` WebSocket on
port 4000; raw NDJSON on port 4100. Every protocol command in
`apps/troupe_gateway/lib/troupe/gateway/dispatch.ex:41-74` is served.

**A2A facade** (`apps/troupe_a2a/lib/troupe/a2a/router.ex:37-64`): `GET /healthz`,
`GET /a2a/:profile/.well-known/agent-card.json`, `POST /a2a/:profile` (JSON-RPC:
`message/send`, `message/stream`, `tasks/get`, `tasks/cancel`, `tasks/resubscribe`,
`agent/getAuthenticatedExtendedCard`), `GET /a2a/tasks/:task_id/artifacts/:hash`.

**Local daemon**: Unix socket `$XDG_RUNTIME_DIR/troupe/daemon.sock` or loopback TCP with a
token in `daemon.json` (`apps/troupe_protocol/lib/troupe/protocol/endpoint.ex`). The daemon
does **not** serve a WebSocket; `docs/plans/README.md:52` lists that as still to do and
`apps/troupe_gateway/lib/troupe/gateway/daemon.ex` has no `Gateway.Web` child.

### 1.3 Protocol commands, events, errors

Commands and their scopes (`dispatch.ex:41-74`): observe — `subscribe`, `unsubscribe`,
`session.list`, `session.get`, `fs.list`, `fs.read`, `blob.get`, `fleet.get`,
`workspace.recent`, `workspace.search`, `worktree.list`, `presence.set`; control —
`input.send`, `turn.cancel`, `profile.switch`, `approval.respond`, `todo.edit`, `fs.upload`,
`tools.register`, `tools.unregister`; admin — `session.create`, `session.archive`,
`session.pin`, `session.unpin`, `session.erase`, `worktree.remove`, `watch.set`. Plus
`initialize` and `auth.refresh` handled in the connection. Server → client request:
`tool.invoke`. Notifications: `event`, `resync_required`, `auth.expiring`, `auth.expired`.

Plane `/rpc` harness methods (`apps/troupe_plane/lib/troupe/plane/harness.ex:49-64`): `me`,
`teams.list`, `profiles.list`, `sessions.list`, `session.get`, `session.open`, `token.mint`,
`session.create`, `session.pin`, `session.unpin`, `session.erase`, `session.grant`,
`session.review`, `trigger.fire`. Admin methods: 38 entries in
`apps/troupe_plane/lib/troupe/plane/admin/api.ex:185-707`, listed in
[admin/roles-and-permissions.md](admin/roles-and-permissions.md).

Event types: 32 durable types are emitted by code; six schema entries have no emitter in this
repository (`session_resumed`, `session_read_only`, `session_archived`, `session_erased`,
`acl_granted`, `acl_revoked`), and the ephemeral `progress` has none either. The committed
schema index (`protocol/schema/v1/index.json`) has 74 documents. Error codes −32700…−32014
are in `apps/troupe_protocol/lib/troupe/protocol/error.ex:14-38`.

### 1.4 Data stores

PostgreSQL (plane only), 20 tables from 11 migrations under
`apps/troupe_plane/priv/repo/migrations/`: users, groups, memberships, teams, grants,
profiles, workers, config_bundles, sessions, session_acls, anchors, tombstones,
usage_records, budget_reservations, audit_events, team_admins, service_principals,
triggers, trigger_runs, platform_settings. Never session content
(`apps/troupe_plane/lib/troupe/plane/repo.ex:5-8`).

OpenBao: transit key `troupe-session-tokens` for plane token signing
(`apps/troupe_plane/lib/troupe/plane/tokens.ex`); KV v2 per-session data keys under
`troupe/teams/<team>/sessions/<id>` written by workers only
(`apps/troupe_protocol/lib/troupe/kms/open_bao.ex`).

Object storage (S3): `sessions/<id>/{manifest.json, segments/, snapshots/, workspace/, blobs/}`
(`apps/troupe_protocol/lib/troupe/sessions/storage.ex`), written by workers; the plane reads
only manifests during `mix troupe.index.rebuild`.

Kubernetes API: the plane writes `WorkerProfile`, reads `TroupePolicy`, creates
`TokenReview`; the operator owns everything in `troupe-w-<profile>` namespaces.

Local daemon: JSONL logs and blobs under `$XDG_STATE_HOME/troupe/sessions/`.

### 1.5 Configuration inputs

Every environment variable, its default and what it controls is tabulated in
[admin/configuration.md](admin/configuration.md) (runtime) and
[developer/local-setup.md](developer/local-setup.md) (development). Every Helm value is
mapped to the template and variable it feeds in the same admin document. Counts: 26 operator
variables, 47 plane variables, 30 worker variables, 6 A2A variables, 1 daemon variable;
82 values in `charts/troupe/values.yaml`.

**There is no `.env.example` in this repository.** The only `*.env*` file is
`.local/scaleway/secrets.env`, which is gitignored (`.gitignore:13`) and was not opened.
The self-check at the end of each track document therefore covers every variable read in
`config/runtime.exs`, `config/config.exs` and `System.get_env` calls under `apps/*/lib`
instead.

Platform settings that an operator can change without a redeploy
(`apps/troupe_plane/lib/troupe/plane/settings.ex:49-216`): `platform_admin_group`,
`groups_claim`, `provisioning_mode`, `default_budget_micros`, `default_budget_period`,
`default_idle_timeout_seconds`, `default_erase_after_days`, `default_bundle_channel`.
Read-only, deployment-owned: `issuer`, `client_id`, `client_secret`, `audience`, `base_url`,
`scim_token`, `breakglass_token`.

### 1.6 CI

`.github/workflows/ci.yml`: nine jobs — `check` (compile with warnings as errors, format
check, credo strict, boundaries, migrate, test ×10 against a Postgres service), `chart`
(helm lint, a negative render test, kubeconform), `protocol` (schema diff, schema
freshness, Python conformance client), `images` (four server images to a registry, on push
only), `build` (five Burrito targets on native runners with a smoke test), `containers`
(clean ubuntu + alpine run), `installer-sh`, `installer-ps1`, `release` (GitHub release on
`v*` tags). **There is no deployment step to any environment.** Every step is listed in
[developer/ci-cd.md](developer/ci-cd.md).

### 1.7 User-facing features confirmed from code

Listed with the implementing file in [user/features.md](user/features.md). In short: sessions
on a team's worker pods or the local daemon; streaming transcripts; approvals with
allow / deny / allow-for-session, first answer wins; plan and build agents plus subagents;
task lists a person can edit; watch mode (`AI!`, `AI?`, `AI` comments); worktrees for a
second local session; file browse, read and upload; large results as blobs; presence;
budgets; pin, archive, erase; skills and MCP tools from a profile's bundle; personal
MCP connectors registered with consent; unattended sessions from triggers and from A2A
callers; token accounting per session.

### 1.8 Admin-only capabilities confirmed from code

Two roles (`platform_admin` from an identity-provider group; `team_admin` assigned per team),
break-glass, service principals, provisioning modes `direct` and `gitops`, `TroupePolicy`
limits with admission and operator enforcement, bundle publish/retire, triggers, platform
settings, audit trail, SCIM. All in [admin/](admin/README.md).

---

## 2. Where prose contradicts code

Trust the code. Each line names the stale text and the code that decides.

| Claim | Where | Code says |
|---|---|---|
| "No MCP client" | `README.md:326` | `apps/troupe_protocol/lib/troupe/mcp/client.ex` exists; Troupe is also an MCP *server* at `POST /mcp` |
| "JSON-RPC over a Unix socket" as *the* protocol | `README.md:9`, `:262` | three transports (`PROTOCOL.md:14-47`); remote clients use WebSocket |
| "Four releases", eight apps, no `troupe_a2a` | `ARCHITECTURE.md:19-30` | `mix.exs:44-101` defines five releases; `apps/` has nine |
| `troupe_protocol` has "no I/O beyond a socket" | `ARCHITECTURE.md:23` | it holds the KMS client, S3 client, MCP client and policy parsing |
| "there is no break-glass" | `ARCHITECTURE.md:673`, `apps/troupe_plane/lib/troupe/plane/admin.ex:24-25` | `Troupe.Plane.Breakglass` exists and `Admin.actor_for_session/1` honours it (`admin.ex:131-142`). The word means two things in the docs: no access to session content (true) and the emergency console login (exists) |
| "three renderings" of the admin context | `admin.ex:5`, `DECISIONS.md` #152, parity test title | four: console, `/rpc`, CLI, MCP (`admin/api.ex:16-17`) |
| `session.create` order "capacity → budget → row" | `harness.ex:18` | row first, then capacity, budget, push, token (`harness.ex:149-166`) |
| Budget period "monthly or daily" | `settings.ex:97`, `admin/api.ex:107`, `live/teams.ex:207-208` | `Identity.Team` changeset accepts only `monthly` and `never` (`identity/team.ex:69`); the ledger never windows spend by period (`ledger.ex:69-78`) |
| Plane may write `TeamVolume` | `provision.ex:5-7`, `apps/troupe_plane/mix.exs:51-53` | only `WorkerProfile` is written |
| Every object the operator writes "carries an owner reference" | `apps/troupe_operator/lib/troupe/operator/resources.ex:10-12` | none do (`resources.ex:784-786`, `DECISIONS.md` #39); pruning uses labels |
| `Resources.for_profile/2` | `ARCHITECTURE.md:323` | arity 3 (`resources.ex:21-22`) |
| `SecretMissing` clears when the secret exists in the worker namespace | `ARCHITECTURE.md:693-697`, `docs/deploying-on-scaleway.md:182-197` | the reconciler checks `troupe-system` (`reconciler.ex:185-190`), pods resolve `secretKeyRef` in `troupe-w-<profile>`, and the operator's ClusterRole grants no verb on `secrets` (`charts/troupe/templates/operator-rbac.yaml:16-46`) |
| **Enter** on an agent row opens its transcript | `README.md:97-98` | no such key handler (`apps/troupe_tui/lib/troupe/ui/tui/server.ex:97-108`); Up/Down already focus |
| `troupe hq` shows remote sessions | `README.md:303-305` | `--remote` applies to `tui`, `run`, `resume`, `sessions` only (`apps/troupe_ctl/lib/troupe/cli.ex:183-186`) |
| `troupe ctl token --scope observe` | `PROTOCOL.md:516` | no `ctl` or `token` command exists (`cli.ex:633-660`) |
| Python client is `troupe_client.py`, ~180 lines | `PROTOCOL.md:4-5` | `clients/python/troupe.py`, 225 lines |
| Event table | `PROTOCOL.md:196-227` | omits `session_tainted`, `tools_registered`, `tools_unregistered`, `mounts_resolved`, `published`, `config_upgraded`, `watch_notice`, `agent_state` (all emitted) |
| Scope table | `PROTOCOL.md:511-513` | omits `auth.refresh`, `session.grant`, `session.review`, `trigger.fire` and every plane `/rpc` method |
| "builds all three server images" | `docs/deploying-on-scaleway.md:119`, `ci.yml:184` | four (`docker/Dockerfile:1`, `ci.yml:143`) |
| Push images with `scripts/build-images` | `docs/deploying-on-scaleway.md:116-120` | the script pushes only with `TROUPE_PUSH=true` (`scripts/build-images:34-36`) |
| Worker TLS via a wildcard issued over DNS-01 | `docs/deploying-on-scaleway.md:127-137` | both Scaleway values files set `operator.certIssuer: letsencrypt` (per-pod HTTP-01) and `deploy/scaleway/cluster-issuer.yaml:5-16` is HTTP-01 only. Nothing in the repo issues `troupe-plane-tls` (`plane.certIssuer: ""`) |
| OpenBao "three replicas, auto-unseal via Scaleway Key Manager" | `docs/deploying-on-scaleway.md:41-44, 156` | `deploy/scaleway/openbao.values.yaml:20-33, 54`: one replica, Shamir seal, single share |
| "CI has never run", "Nothing here has run on Scaleway" | `docs/deploying-on-scaleway.md:335-339, 351` | commit `9ae7d3c` ("Deploying it on a real cluster, and the bugs only a cluster finds") and the small-release change list in the same document describe a real deployment. Not resolvable from code alone; see open question 1 |
| `values.yaml` A2A NetworkPolicy caveat | `charts/troupe/values.yaml:192-195` | `network-policy.yaml:29-34` already admits facade pods |
| Disk pressure "puts sessions to sleep" and "stops accepting placements" | `apps/troupe_worker/lib/troupe/worker/disk.ex:10-14` | only cache eviction is implemented (`disk/watch.ex:106-140`) |
| Blobs: "any event field over 16 KiB" | `apps/troupe_core/lib/troupe/session/blobs.ex:5` | only tool-result content is spilled (`agent/server.ex:1054-1058, 1147-1156`) |
| Remote endpoint advertises `worktrees: false` | `apps/troupe_gateway/lib/troupe/gateway/connection.ex:412` | `Dispatch` still serves `worktree.*` on a pod |
| `README.md:149` `priv/examples/config.gateway.yaml` | | actual path `apps/troupe_core/priv/examples/config.gateway.yaml` |
| `README.md:292` `send_input/4` | | `send_input/5` |
| `ARCHITECTURE.md:3`, `DECISIONS.md:4`, `spec.md:2` extend `../troupe/*.md` | | no sibling checkout exists here; the stage-0 architecture is not in this repository |
| `docs/plans/README.md:5-6` "the fifth is not built" | | its own table marks stage 6 part 1 and the admin surface as built |
| Status system reads `docs/design/admin/tokens.json` at compile time | `apps/troupe_plane/lib/troupe/plane/web/live/status.ex:9` | reads `priv/design/statuses.json`, which `mix troupe.admin.tokens` generates |
| `config/runtime.exs:236` names `Troupe.Plane.Web.Breakglass` | | module is `Troupe.Plane.Breakglass` |
| `apps/troupe_operator/mix.exs:15`, `apps/troupe_worker/mix.exs:15` "(stage 2)" | | descriptions predate stages 3–6 |
| Formatter covers the code | implied by `mix check` | root `.formatter.exs:3` globs `{config,lib,test}/**` relative to the umbrella root and no `apps/*/.formatter.exs` exists, so `mix format --check-formatted` never inspects `apps/**`. Credo does (`.credo.exs:29-32`) |

---

## 3. Findings from code that the docs should carry as caveats

These are not doc/code disagreements; they are behaviours a reader would not expect.

1. **`:k8s_conn` is never configured.** `Troupe.Plane.Provision` and
   `Troupe.Plane.ClusterPolicy` read `Application.get_env(:troupe_plane, :k8s_conn)`
   (`provision.ex:245`, `cluster_policy.ex:67`) and nothing under `config/` or `apps/*/lib`
   sets it. In a deployed plane, direct-mode `admin.profile.put` therefore reports
   `state: :not_applied, reason: :no_cluster` and the policy check allows every egress host
   with one warning. Enrolment builds its own connection (`enrolment.ex:169-185`) and is
   unaffected. Confirm whether this is intended (a release hook, or a deployment that only
   drafts profiles) before documenting direct provisioning as working.
2. **Team volumes are mounted on pods but not into sessions.** The operator mounts
   `/mnt/teams/<name>` and `/mnt/org`, but `Troupe.Worker.Session.Restore.start/3` passes no
   `:mounts` to `Troupe.resume/2`, so a restored session's mount table is `session:/` plus
   `skills:/` only. `publish`/`import` have nowhere to go on a pod today.
3. **`TROUPE_SMALL_MODEL`, `TROUPE_NAMESPACE`, `TROUPE_CONFIG_CHANNEL`** are injected into
   worker pods (`resources.ex:560-574, 627`) but nothing in `apps/*/lib` reads them;
   `Troupe.Config.merge_env/1` reads only `TROUPE_PROVIDER`, `TROUPE_BASE_URL`,
   `TROUPE_API_KEY`, `TROUPE_MODEL`, `TROUPE_FAKE_SCRIPT` (`config.ex:139-145`). A profile's
   `llm.smallModel` therefore has no effect on a pod.
4. **`TROUPE_BASE_URL` means two things**: the plane's public URL and token issuer on a
   plane, the LLM endpoint on a worker.
5. **Session pins are not persisted** locally (`apps/troupe_core/lib/troupe.ex:309`,
   `sessions/index.ex:325`), and no retention code exists in the daemon; the plane keeps
   `pinned` on its row.
6. **`admin.audit.list` is not team-scoped**: a team admin reads every team's changes
   (`admin.ex:893-897`).
7. **`admin.sessions.list` ignores its documented `team` filter** (`sessions.ex:454-483`).
8. **`Admin.team_spend/1`** maps `&1.amount_micros` over a map returned by
   `Ledger.open_reservations/1` (`admin.ex:1144-1145` vs `ledger.ex:162-170`); `team_detail/1`
   handles the same value with `Map.values/1`. Not executed here; from reading only.
9. **Per-request OpenBao call**: `/rpc` and `/mcp` authentication fetch the transit key on
   every request (`router.ex:229`, `tokens.ex:139-146`); no cache was found.
10. **`TROUPE_BASE_URL` is effectively mandatory** for the console and MCP: with only
    `TROUPE_HOST` set, the RFC 9728 `resource` becomes `/mcp` and the console redirect URI
    falls back to `http://localhost:4000/admin/callback` (`router.ex:298`, `admin_auth.ex:339`).
11. **Webhook triggers have no endpoint in this repository**; `source.kind: webhook` is
    accepted (`triggers/trigger.ex:24`) and an external executor is expected to call
    `trigger.fire`.
12. **Triggers, principals and runs are not rebuildable from object storage**
    (`docs/plans/remote-triggers.md:218-221`); only the session index is. The deploy guide
    does not say so.
13. **The operator never deletes a pod.** An `OnDelete` upgrade only reports
    `UpgradePending`; `admin.pod.drain` lives in the plane and the plane's Role has no pod
    delete either. Who restarts a drained pod is not answered by code.
14. **Worker probes and CI**: the operator's cluster suites and the plane's enrolment tests
    skip without a kubeconfig, so the `check` job never exercises them.
15. **Erlang cookie across image versions**: `mix release` generates a cookie per build and
    no `rel/` overlay pins it; with `distribution: name` a rolling update between two image
    builds may not cluster during the rollout.
16. **The `images` CI job pushes `sha-<7>` tags on every branch push.**
17. **`x-litellm-response-cost` on streamed responses** is read from headers and assumed
    present (`REPORT.md:1249-1253`); not verified against a gateway.
18. **Provider string becomes an atom** with `String.to_atom/1`
    (`apps/troupe_core/lib/troupe/llm/provider.ex:75`).
19. **The daemon's `troupe sessions` can start a daemon** (it connects with `spawn: true`,
    `cli.ex:188-206`) although `protocol/daemon.ex:73-75` says listing should not.
20. `clients/python/__pycache__/troupe.cpython-312.pyc` is tracked in git.
21. **The worker image may ship without `reaper`.** `docker/Dockerfile` installs no Zig in
    its build stage (`docker/Dockerfile:15-17`), `.dockerignore:17` excludes any prebuilt
    `apps/*/priv/reaper`, and `mix compile.reaper` is a no-op with a warning when `zig` is
    absent (`apps/troupe_core/lib/mix/tasks/compile.reaper.ex:14, 45`). `Troupe.Reaper.path/0`
    then answers `{:error, :reaper_missing}` (`apps/troupe_core/lib/troupe/reaper.ex:21-24`),
    which is what `shell` and the ripgrep path of `grep` return in a pod. Every reaper-backed
    smoke test in CI runs the Burrito client binary, not the worker image. Not executed here;
    from reading the build files only.

---

## 4. Open questions

Things the docs mark as unconfirmed rather than assert.

1. **Is there a live deployment, and on what values?** Git history and `.local/scaleway/`
   suggest yes; `docs/deploying-on-scaleway.md:335-353` says no. The repository records no
   image tags, values or secrets for it (all under gitignored `.local/`).
2. **Which forge runs CI**, and which jobs are required checks? No branch protection lives
   in the repo; `ci.yml:4-6` targets GitHub and Forgejo; installers default to
   `github.com/objective-mj/troupe`. Has any `images` or `release` job ever succeeded?
3. **How does a deployed plane get a Kubernetes connection** for provisioning and policy
   (finding 1)?
4. **Where should LLM and MCP secrets live**: `troupe-system` (what `SecretMissing` checks)
   or `troupe-w-<profile>` (what pods read)? Both, until the reconciler changes?
5. **Who issues `troupe-plane-tls`** in the Scaleway values, and is the worker wildcard or
   per-pod HTTP-01 the intended shape?
6. **Database TLS and pool size** on a managed instance: `TROUPE_DB_SSL`,
   `TROUPE_DB_CACERT_FILE`, `TROUPE_POOL_SIZE` have no Helm values. How is the live plane
   configured?
7. **OpenBao durability**: single replica, Shamir seal with the key in a Kubernetes Secret,
   no Raft snapshots, audit device off. Accepted risk or gap?
8. **Object storage protection** beyond versioning (lifecycle, replication): none in repo.
9. **Budget periods**: is `monthly`/`daily`/`never` meant to converge, and should
   `spent_micros/1` window by period?
10. **`default_bundle_channel`** setting has no reader beyond the registry.
11. **Team volumes on the worker side** (finding 2): planned, or wired elsewhere?
12. **Remote blob durability**: local blobs are erased at dormancy and never uploaded
    (`Troupe.Sessions.Storage.put_blob/1` has no caller in the worker).
13. **Unemitted schema events** (`session_resumed`, `session_read_only`, `session_archived`,
    `session_erased`, `acl_granted`, `acl_revoked`, `progress`): reserved, or emitted by a
    component not in this repo?
14. **`TROUPE_OIDC_SCOPES`** is uncommitted in the working tree; the docs describe it with
    that caveat.
15. **Version and tags**: everything is `0.2.0`; the live plane reportedly runs plane
    `0.2.6` and operator `0.2.2` (from a session note, not from the repository). What is the
    tagging rule?
16. **NetworkPolicies have never been exercised**: `dev/kind/values.yaml` leaves them on
    against a CNI that does not enforce them.
17. **`troupe hq` remote**, **`fs.upload` in the GUI**, **HQ Review view in the TUI**
    (`docs/plans/remote-triggers.md` §5): planned or dropped?
18. **Hatchet** workflows and the LiteLLM A2A conformance run live outside this repo and
    have not been run (`REPORT.md:1095-1099`).

---

## 5. Method

Six read-only passes over the tree: plane; core/worker/gateway/protocol; operator/A2A/CLI/TUI
plus CRDs, Python client and reaper; infrastructure, chart, CI and config; the existing prose
documents; and the GUI repository (its own `docs/AUDIT.md`). Every claim above was checked
against a file in the working tree on 2026-09-13; nothing was executed except
`git status`, `git diff`, `git log` and `git ls-files`.
