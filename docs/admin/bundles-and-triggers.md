# Bundles, principals, triggers and the A2A facade

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../history/AUDIT.md).
>
> Commit `4083b1f` (`TROUPE_OIDC_MCP_SCOPE`, `plane.oidc.mcpScope`) landed while this track was being written and is covered; line numbers are from that tree. Unprefixed module paths are under `apps/troupe_plane/lib/troupe/plane/`.

What a profile carries beyond a model (bundles), who may start work without a person (service principals), what starts it (triggers), and how other agents reach it (A2A). What a user sees of these is in [../user/features.md](../user/features.md).

---

## 1. Config bundles

A bundle is one versioned, hashed, immutable JSON document assigned to profiles by **channel** (`bundles.ex:1-32`). `Troupe.Protocol.Bundle` (`apps/troupe_protocol/lib/troupe/protocol/bundle.ex`) owns the shape so the plane, the worker and the console check the same thing.

### Schema 1

```json
{"schema": 1,
 "agents":      [{"name": "reviewer", "definition": "---\nmode: primary\n---\nYou review…"}],
 "skills":      [{"name": "review-checklist", "description": "How we review…",
                  "files": {"SKILL.md": "…", "checklist.md": "…"}}],
 "mcp_servers": [{"name": "jira", "url": "https://mcp.jira.example/mcp",
                  "credential_ref": "JIRA_MCP_TOKEN", "header": "authorization",
                  "timeout_ms": 30000, "permission": "ask",
                  "tools": ["search_issues", "get_issue"]}]}
```
(`protocol/bundle.ex:10-19`)

A document with no `schema` key is **schema 0**: a free-form map of which only `mcp_servers` (name, url, `credential_ref` or `secret_ref`, header, timeout) is read; accepted for planes upgraded under one, never written again (`:21-23,240-264`).

### Validation rules (`protocol/bundle.ex:266-508`)

| Rule | Source |
|---|---|
| whole document ≤ 4 MiB (the plane's JSON body limit, `web/router.ex:43`) | 285-289 |
| only the keys `schema`, `agents`, `skills`, `mcp_servers` | 291-297 |
| names `^[a-z0-9][a-z0-9-]{0,63}$` (`AgentDefinition.valid_name?`), unique per kind | 313-320, 322-334 |
| an agent's `definition` must parse as frontmatter + prompt; it may list only skills the bundle has; it may replace a built-in (`build`, `plan`, `general`, `explore`) only with `override: true` | 322-363; built-ins from `bundles.ex:43-48` |
| a skill needs `files["SKILL.md"]`; its frontmatter `name`, if present, must be its own; file names relative, no `..`, all text; ≤ 512 KiB per skill | 365-425 |
| an MCP `url` must be `https://`, or `http://` to a `.svc` host; its host must pass the caller's egress check (the plane's `TroupePolicy`); `credential_ref` must look like an env var `^[A-Z][A-Z0-9_]{1,63}$` and never a value; `permission` is `ask` (default) or `auto`; `tools` is `"all"` (default) or a list of names | 427-507 |

The plane adds the egress rule through `ClusterPolicy.egress_allowed?/1` (`bundles.ex:60-74`) — which, with no `:k8s_conn`, allows every host and warns once (`cluster_policy.ex:57-60`; [profiles-and-policy.md §7](profiles-and-policy.md#7-provisioning-how-the-planes-row-becomes-a-cr)). `admin.bundle.validate` and `admin.mcp.check` run the same checks without publishing.

### Publish, retire, channels, versions

- `admin.bundle.publish {channel, content}` validates, assigns the channel's **next** version number, stores the document with `hash = sha256:<canonical JSON>` and a summary, and then (a) broadcasts `config.updated {channel, version, bundle_hash, mcp_servers}` to every pod of every profile on the channel and (b) rewrites `mcpServers` on those profiles' CRs (`bundles.ex:76-127,215-240,418-449`). History is append-only; a rollback is a new version with the old content (`admin/api.ex:464-479`).
- **Adoption**: pods report the newest hash they hold in every heartbeat; `admin.bundle.get` shows per profile which pods are `current`, `ahead` (a newer version of the same channel, which happens after a retire) and `stale` (`bundles.ex:246-286`).
- **How a pod picks up a version**: on `config.updated` it calls `bundle.fetch` over the control channel, verifies the hash, materialises `bundles/<hash>/{agents/<name>.md, skills/<name>/…, bundle.json}` and hands the MCP servers to the worker's MCP registry; a pod that missed the push catches up at its next heartbeat comparison (`bundles.ex:215-227`; `protocol/bundle.ex:143-192`; `ARCHITECTURE.md:403-409`).
- **Session pinning**: a new version applies to **new sessions only**; a running session keeps the version recorded in its `session_created`. Retiring a version (`admin.bundle.retire`) is what ends that: a session pinned to a retired version moves to the channel's current version at its next activation with a durable `config_upgraded` event (`bundles.ex:5-15,166-213`). A channel with nothing published offers the built-in agents only (`bundles.ex:321-347`).
- The channel a profile follows is `configBundleChannel` (default `stable`); the `default_bundle_channel` setting has no reader ([configuration.md Part C](configuration.md#part-c--platform-settings)).

### The directory `troupe admin bundle publish CHANNEL DIR` assembles

The client assembles it and posts the result; the layout it expects, which the plane
validates against `Troupe.Protocol.Bundle`, is:

```
agents/<name>.md          one agent definition each; the name is the file name
skills/<name>/SKILL.md    a skill, with every regular file beside it (recursively)
mcp.yaml | mcp.json       a list of servers, or an object with the list under mcp_servers
```

A skill's description is read from the `SKILL.md` frontmatter. The result is `{"schema": 1, "agents": […], "skills": […], "mcp_servers": […]}` and the plane validates it; a directory with none of the three parts is refused. Publishing the directory and publishing the console's JSON of the same content produce the same hash (`ctl/admin.ex:179-184`). A FILE argument that is a plain JSON file is sent as-is.

### MCP server entries and the Secret convention

| Field | Meaning | Default |
|---|---|---|
| `name` | server name, also the tool prefix `mcp.<server>.<tool>` | required |
| `url` | streamable-HTTP endpoint | required |
| `credential_ref` (or legacy `secret_ref`) | the **environment variable** the pod finds the token in — never a value | none (server called without a credential) |
| `header` | header the token is sent in; `authorization` gets a `Bearer ` prefix unless the value already has a space | `authorization` |
| `timeout_ms` | per-call timeout | 30000 |
| `permission` | default tool permission, `ask` or `auto`; an agent definition may tighten it | `ask` |
| `tools` | allowlist applied at discovery — an unlisted tool is absent, not denied | `all` |

(`protocol/bundle.ex:52-60,429-450`; `apps/troupe_protocol/lib/troupe/mcp/server.ex:60-106`)

On publish the plane projects each server onto the profile CR as `{name, url, header?, timeoutMs?, credentialRef, secretRef: {name: "troupe-mcp-<server>", key: "token"}}` (`bundles.ex:451-486`). The operator turns that into an env var named by `credentialRef` (default `TROUPE_MCP_<NAME>_TOKEN`) from a `secretKeyRef` marked `optional: true` (`resources.ex:666-698`). So for every server with a `credential_ref`, **create Secret `troupe-mcp-<server>` with key `token` in every `troupe-w-<profile>` namespace whose profile follows that channel** ([configuration.md Part D](configuration.md#part-d--secrets-the-chart-expects)). The server's host must also be in the policy's `allowedEgress`, or the publish is refused (when the plane can read the policy) and the pods cannot reach it (when Cilium enforces it).

Personal MCP servers a user registers from their own client are separate: they arrive through `tools.register` under consent and are never configured into a pod (`ARCHITECTURE.md:840-841`).

---

## 2. Service principals

Covered in [roles-and-permissions.md §3](roles-and-permissions.md#3-service-principals). The admin verbs:

| Action | Command | Method | Effect |
|---|---|---|---|
| create | `troupe admin principal create TEAM NAME PROFILES` (comma-separated) | `admin.principal.create` | secret printed **once**; profiles must be within the team's grants (`principals.ex:26-59`) |
| rotate | `troupe admin principal rotate SUBJECT` | `admin.principal.rotate` (destructive) | old secret stops immediately (`principals.ex:61-73`) |
| disable | `troupe admin principal disable SUBJECT` | `admin.principal.disable` (destructive) | refused at next exchange and next `/rpc` call; sessions kept (`principals.ex:75-86`) |
| list | `troupe admin principal list TEAM` | `admin.principals.list` | subject, profiles, last use, enabled — never a secret or hash (`admin.ex:1166-1180`) |

A principal exchanges its secret at `POST /auth/exchange` with `{"client_id": "svc:<team>/<name>", "client_secret": "…"}` (`web/router.ex:104-120,215-216`) and can then call `session.create`, `session.open`, `token.mint`, `input.send` and `trigger.fire` for the triggers that run as it — and no `admin.*` method.

---

## 3. Triggers

A trigger is a row the plane stores and a caller fires; firing creates a session **as the trigger's principal** through the same `session.create` a person's client uses, so grant, budget, agent and term checks all apply (`triggers.ex:1-16`).

### Fields (`triggers/trigger.ex:28-82`)

| Field | Type / validation | Default | Meaning |
|---|---|---|---|
| `team` (`team_id`) | required | — | owning team; `trigger.put` takes `team` by name |
| `name` | `^[a-z0-9][a-z0-9-]{0,62}$`, unique per team | — | |
| `principal` (`principal_id`) | required; a subject or id of a principal **in the same team** (`triggers.ex:501-518`) | — | who the session runs as |
| `profile` | required | — | profile the session starts on; must be among the principal's profiles |
| `agent` | optional | — | which primary agent to start |
| `enabled` | boolean | `true` | a disabled trigger refuses `fire` with `forbidden` (`triggers.ex:210-212`) |
| `source` | required; `{"kind": "schedule", "cron": "…", "tz"?: "UTC"}` or `{"kind": "webhook", …}` | — | see below |
| `prompt_template` | ≤ 65 536 bytes | `""` | rendered with `{{a.b.c}}` placeholders |
| `terms` | object with only `budget_micros`, `max_turns`, `wall_clock_seconds`, `approvals` (`triggers.ex:33,520-535`) | `{}` | see §4 |
| `visibility` | `private` or `team` | `team` | visibility of the sessions it creates |
| `review` | `required` or `none` | `required` | whether a person is expected to close the loop |
| `notify` | list of subjects | `[]` | each is granted `collaborator` on every run's session (`triggers.ex:338-352`) |
| `concurrency` | 1..100 | 1 | cap on live runs; a firing over it records a `skipped` run |

**Cron** (`triggers/cron.ex:1-16`): five fields `minute hour day-of-month month day-of-week`; each takes `*`, `*/n`, a number, `a,b`, `a-b`, `a-b/n`; day-of-week 0–7 with 0 and 7 both Sunday; **UTC only** — `tz` other than `UTC`/`Etc/UTC` is refused (`triggers/trigger.ex:84-113`). No names, no `@daily`, no seconds.

**Template** (`triggers/template.ex`): `{{event.issue.key}}`, `{{event.labels.0}}`, `{{trigger.name}}`, `{{run.idempotency_key}}`, `{{run.fired_at}}`; a missing path renders empty; nothing is escaped (`template.ex:1-13`; values from `triggers.ex:314-323`). The session title is `<name> YYYY-MM-DD HH:MM` and its origin `{kind: trigger, trigger, run}` (`triggers.ex:324-336`).

### The in-plane scheduler (`triggers/scheduler.ex`)

- One `:global` singleton across the cluster, started on demand by a `Keeper` on every replica (every 30 s), ticking **every 30 s** (`:17-20,34,128-162`).
- Each tick reads every enabled trigger whose `source.kind` is `schedule`, computes the latest cron minute at or before now, and fires it once with idempotency key `cron:<trigger id>:<minute ISO8601>` if that minute is later than `last_fired_at` (`:58-87`). `mark_fired` is a conditional update, so two schedulers advance the mark once between them (`triggers.ex:111-129`).
- A plane that was down fires each trigger **once** for the latest missed minute, not once per missed minute (`:11-15`).
- A trigger that has **never fired** is fired only if its due minute is within the last **120 s**; otherwise its first firing is its next minute (`:36-38,83-85`).
- No webhooks, no retries beyond the next tick (`:22-23`). A tick that raises is logged and the next one runs (`:110-124`).

### Runs and states (`triggers/run.ex`, `triggers.ex:395-428`)

The row stores only what the plane decided at firing: `created`, `skipped` (concurrency cap) or `failed` (the create itself failed). Everything after is read from the session's status columns:

| Reported state | Meaning |
|---|---|
| `created` | run row exists, session not yet active (or `idle` and dormant) |
| `running` | session active and thinking/acting |
| `waiting` | session waiting on an approval |
| `done` | session `done` with reason `finished`, `budget_exhausted` or none |
| `failed` | stored `failed`, or session `interrupted`, or `done` for any other reason, or the session row is gone |
| `skipped` | over the concurrency cap; no session |

`event` on a run is capped at 16 KiB — the issue key and title, never a whole webhook body (`triggers.ex:28-37,537-541`).

### `trigger.fire` idempotency (`triggers.ex:198-312`)

`trigger.fire {trigger, idempotency_key, event}` on `/rpc`, callable by the trigger's principal or an admin of its team, writes the run row **first** so two callers racing on one key are decided by the unique index. The same key returns the same run: a `skipped` run stays skipped, a `failed` run is retried, a run with a session is handed that session and a fresh token. `admin.trigger.run` fires by hand with a manual key naming the caller and the minute (`PROTOCOL.md:757-770`).

### Webhooks and Hatchet

`source.kind: webhook` is accepted (`triggers/trigger.ex:24,94-95`) but **there is no webhook endpoint in this repository**: an executor outside the plane terminates the webhook and calls `trigger.fire` (`triggers/trigger.ex:5-8`; [AUDIT.md §3.11](../history/AUDIT.md)). Hatchet is named as that executor throughout the prose and is **not in this repository** — no client code, no chart ([AUDIT.md §4.18](../history/AUDIT.md)). A plane without it has schedules from the in-plane scheduler and nothing else.

### Where triggers live

Triggers, principals and runs are rows in PostgreSQL only; unlike the session index they are **not rebuildable from object storage** ([backup-restore.md](backup-restore.md); [AUDIT.md §3.12](../history/AUDIT.md)).

---

## 4. Unattended session terms

`session.create` (and therefore every trigger and A2A task) accepts `terms` (`harness.ex:34-35,45,312-346`):

| Term | Range | Default | Effect |
|---|---|---|---|
| `budget_micros` | ≥ 1, then capped to what the team has left (`harness.ex:329-346`) | the default slice, 5 000 000 micros (`harness.ex:35,488-491`) | what the session reserves each time it activates |
| `max_turns` | 1–500 | the agent's own (40) | ends the session `done` with `budget_exhausted`, which a run reports as `done` |
| `wall_clock_seconds` | 60–86 400 | the agent's own (30 min) | same |
| `approvals` | `wait` or `deny` — there is **no** `auto` | `wait` | `wait` leaves the approval in the log and the review queue; `deny` answers no as a readable result. A trigger that needs no approvals runs a profile whose bundle sets those tools to `auto` (`ARCHITECTURE.md:858-861`) |

Terms are validated before the row exists, kept on the row and sent on every activation (`ARCHITECTURE.md:466-472`). `Triggers.put/3` checks the key set at write time so a bad term is refused when written rather than at three in the morning (`triggers.ex:60-68`).

### Review flags

A session with `origin.kind` of `trigger` or `a2a` that nobody has marked reviewed is in the review queue: `admin.sessions.list` / `sessions.list` with `needs_review: true` (`sessions.ex:472-476,486-490`; `admin/api.ex:93-97`). `session.review {session_id}` sets `reviewed_by`/`reviewed_at` on the session and its run and is audited as `session.review` (`triggers.ex:430-439`; `PROTOCOL.md:768`). A person's own sessions are never in the queue.

---

## 5. The A2A facade as an admin concern

`apps/troupe_a2a` makes every profile an A2A agent at `/a2a/<profile>`; it is a client of `/rpc` and of worker sockets with no database and no credential of its own. The protocol mapping and routes are in [../a2a.md](../a2a.md); what an operator has to do:

- **Enable it in the chart**: `a2a.enabled: true`, `a2a.host`, and a TLS secret or terminate elsewhere (`values.yaml:179-211`). The Deployment, Service, Ingress and NetworkPolicy are all in `templates/a2a-deployment.yaml`; the plane's NetworkPolicy admits facade pods on the HTTP port when enabled (`network-policy.yaml:29-34`). Discrepancy: the comment at `values.yaml:192-195` says you must admit the facade yourself; the template already does ([AUDIT.md §2](../history/AUDIT.md)).
- **`TROUPE_A2A_PUBLIC_URL`** (`a2a.publicUrl`, default `https://<a2a.host>`) is required and is the origin in every card and artifact URI (`runtime.exs:415-427`).
- **What a caller needs**: a service principal of a team granted the profile — `Bearer svc:<team>/<name>:<secret>` or `Basic` — or a person's `id_token`; the facade exchanges it at `/auth/exchange` and caches the plane token by a digest of the credential until a minute before expiry (`docs/a2a.md:25-45`). LiteLLM's A2A gateway is one caller with one principal (`docs/a2a.md:44-45`).
- **Visibility** of task sessions: `a2a.visibility` → `TROUPE_A2A_VISIBILITY`, `private` (the principal only) or `team` (`values.yaml:201-204`).
- **Limits**: `a2a.maxStreams` open SSE streams per replica, 429 beyond; a finished task's history or artifact opens a reader on a pod, so a polling caller pays for it (`docs/a2a.md:117-126`).
- The LiteLLM A2A conformance run lives outside this repository and has not been run ([AUDIT.md §4.18](../history/AUDIT.md)).

---

## 6. Team defaults and the budget model

### Team defaults (`admin.ex:293-305`)

When a group is enabled as a team, four settings seed the row: `default_budget_micros` (0), `default_budget_period` (`monthly`), `default_idle_timeout_seconds` (1800), `default_erase_after_days` (365) ([configuration.md Part C](configuration.md#part-c--platform-settings)). Afterwards each team's values are edited with `admin.team.update` (`identity.ex:301`).

- **Period caveat**: `Identity.Team` accepts `budget_period` of `monthly` or `never` only (`identity/team.ex:69`), while the setting, the API description and the Teams page offer `daily` (`settings.ex:97`; `admin/api.ex:107`; `web/live/teams.ex:207-208`), and `Ledger.spent_micros/1` never windows spend by period (`ledger.ex:62-78`). Today the period is a label; the ceiling is against all-time recorded spend. [AUDIT.md §2, §4.9](../history/AUDIT.md).
- `idle_timeout_seconds` must be > 0 (`identity/team.ex:70`). On a pod a session goes dormant after 10 minutes idle regardless (`apps/troupe_worker/lib/troupe/worker/session/manager.ex:51`); unconfirmed whether the team value reaches the pod.
- `erase_after_days`: no retention code was found in the worker or the plane that acts on it ([AUDIT.md §3.5](../history/AUDIT.md)); treat it as recorded intent.

### Budget model (`team_budget.ex`, `ledger.ex`)

- **Reservation vs spend.** A session reserves a slice up front (`terms.budget_micros` or the 5 000 000-micro default) and the ledger records what model calls actually cost as `usage_records`, one row per gateway request id (`team_budget.ex:9-11`; `ledger.ex:34`). A reservation is granted when `spent + reserved + amount <= budget` (`team_budget.ex:94-116`) and written to `budget_reservations` before it is granted, so a replica dying does not release it silently (`:102-103`).
- **Zero or nil budget is unlimited** (`team_budget.ex:203`; `settings.ex:89-91`).
- **Released on dormancy**: `release/2` marks the reservation `released_at` and frees the slice (`team_budget.ex:118-128`; `ledger.ex:150-158`); `ARCHITECTURE.md:868-869`.
- One `TeamBudget` actor per team, registered with `:global`, which is why plane replicas must be clustered (`plane-deployment.yaml:131-138`; `_helpers.tpl:22-35`). Spend sums are cached for a minute per node (`apps/troupe_plane/lib/troupe/plane/application.ex:44-46`).
- What the console's Overview shows per team is `budget_micros`, `budget_period`, `spent_micros` and the sum of open reservations (`admin.ex:1136-1147`). Caveat: `team_spend/1` maps `&1.amount_micros` over what `Ledger.open_reservations/1` returns; from reading only, the shapes may not agree ([AUDIT.md §3.8](../history/AUDIT.md)).
- Costs come from the gateway's `x-litellm-response-cost` header; where none is sent, tokens are recorded at zero cost with a synthetic request id `seq:<session>:<n>`, which the nightly reconcile counts as *unmetered* ([integrations.md](integrations.md); `ARCHITECTURE.md:915-930`).
