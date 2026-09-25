# Bundles, triggers and budgets

What a profile carries beyond a model (bundles), what starts work without a person
(triggers, run as [service principals](roles-and-permissions.md#3-service-principals)), the
terms an unattended session runs under, and how money is counted. The A2A facade is in
[../a2a.md](../a2a.md).

## 1. Config bundles

A bundle is one versioned, hashed, immutable JSON document, assigned to profiles by
**channel**. `Troupe.Protocol.Bundle` owns its shape, so the plane, the worker and the
console check the same thing.

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

A document with no `schema` key is schema 0, of which only `mcp_servers` is read; it is
accepted for planes upgraded under one and never written again.

**Validation.** At most 4 MiB; only those four keys; names `^[a-z0-9][a-z0-9-]{0,63}$`,
unique per kind. An agent's definition must parse as frontmatter plus prompt, may list only
skills the bundle has, and replaces a built-in agent only with `override: true`. A skill
needs `SKILL.md` (whose `name`, if present, must be its own), relative text files with no
`..`, at most 512 KiB. An MCP `url` is `https://`, or `http://` to a `.svc` host, and its
host must pass the policy's egress check.

**MCP entries.**

| Field | Meaning | Default |
|---|---|---|
| `name` | server name; tools appear as `mcp.<server>.<tool>` | required |
| `url` | streamable-HTTP endpoint | required |
| `credential_ref` | the **environment variable** holding the token, `^[A-Z][A-Z0-9_]{1,63}$` — never a value | none |
| `header` | where the token goes; `authorization` gets a `Bearer ` prefix | `authorization` |
| `timeout_ms` | per call | 30000 |
| `permission` | `ask` or `auto`; an agent definition may tighten it | `ask` |
| `tools` | allowlist applied at discovery: an unlisted tool is absent, not denied | `all` |

On publish the plane projects each server onto the profile's resource with
`secretRef: {name: "troupe-mcp-<server>", key: "token"}`, and the operator injects it as the
`credential_ref` variable from an optional `secretKeyRef`. So for every server with a
credential, **create `troupe-mcp-<server>` with key `token` in every `troupe-w-<profile>`
whose profile follows the channel**, and put its host in `allowedEgress`.

**Publish, adopt, retire.** `admin.bundle.publish {channel, content}` validates, assigns
the channel's next version, stores the document under `sha256:<canonical JSON>`, pushes
`config.updated` to every pod on the channel and rewrites `mcpServers` on those profiles.
History is append-only; a rollback is a new version with the old content. Pods fetch the
version over the control channel, verify the hash and materialise
`bundles/<hash>/{agents, skills, bundle.json}`; one that missed the push catches up at its
next heartbeat. `admin.bundle.get` shows per profile which pods are `current`, `ahead` or
`stale`. `admin.bundle.validate`, `admin.bundle.preview` and `admin.mcp.check` run the
checks without publishing.

A new version applies to **new sessions only**; a running session keeps the version
recorded when it was created until `admin.bundle.retire` retires that version, after which
it moves to the channel's current version at its next activation, with a durable
`config_upgraded` event. A channel with nothing published offers the built-in agents.

A client assembling a bundle from a directory expects `agents/<name>.md`,
`skills/<name>/SKILL.md` with its files beside it, and `mcp.yaml` or `mcp.json`.

Personal MCP servers a person offers from their own client are separate: they arrive with
consent through `tools.register` and are never configured into a pod.

## 2. Triggers

A trigger is a row the plane stores and something fires; firing creates a session **as
the trigger's principal** through the same `session.create` a person uses, so grants,
budgets, agents and terms all apply. Triggers, principals and runs live only in PostgreSQL:
unlike the session index they cannot be rebuilt from object storage.

| Field | Meaning | Default |
|---|---|---|
| `team`, `name` | owner, and `^[a-z0-9][a-z0-9-]{0,62}$` unique per team | required |
| `principal` | a principal of the same team, which the session runs as | required |
| `profile`, `agent` | where it starts (one of the principal's profiles) and which primary agent | profile required |
| `enabled` | a disabled trigger refuses to fire | `true` |
| `source` | `{"kind": "schedule", "cron": "…", "tz": "UTC"}` or `{"kind": "webhook"}` | required |
| `prompt_template` | ≤ 64 KiB, with `{{event.issue.key}}`, `{{trigger.name}}`, `{{run.fired_at}}` placeholders; a missing path renders empty, nothing is escaped | `""` |
| `terms` | §3 | `{}` |
| `visibility` | `private` or `team` | `team` |
| `review` | `required` or `none` | `required` |
| `notify` | subjects granted `collaborator` on every run's session | `[]` |
| `concurrency` | cap on live runs, 1–100; a firing over it records a `skipped` run | 1 |

**Cron** is five fields (`*`, `*/n`, `n`, `a,b`, `a-b`, `a-b/n`; day-of-week 0–7), **UTC
only**, no names or `@daily`. **The in-plane scheduler** is one cluster-wide singleton
ticking every 30 s. Each tick fires every enabled schedule once for the latest due minute
after its last firing, with idempotency key `cron:<id>:<minute>`, so a plane that was down
fires once, not once per missed minute; a trigger that has never fired fires only if its
minute is within the last 120 s.

**Firing by hand or from outside.** `trigger.fire {trigger, idempotency_key, event}` on
`/rpc`, by the trigger's principal or an admin of its team, writes the run row first, so
two callers racing on one key get the same run: skipped stays skipped, failed is retried, a
run with a session is handed it and a fresh token. `event` is capped at 16 KiB.
`admin.trigger.run` fires one by hand. **There is no webhook endpoint here**:
`source.kind: webhook` expects an external executor to receive the webhook and call
`trigger.fire`.

**Runs** store only what the plane decided — `created`, `skipped`, `failed` — and read the
rest from the session: `running`, `waiting` (on an approval), `done`, `failed`.
`admin.runs.list` and `admin.run.review` are the inbox.

## 3. Unattended session terms

`session.create`, and so every trigger and A2A task, accepts `terms`, validated before the
session exists and re-sent on every activation:

| Term | Range | Default | Effect |
|---|---|---|---|
| `budget_micros` | ≥ 1, capped to what the team has left | 5 000 000 | reserved at each activation |
| `max_turns` | 1–500 | the agent's own | ends the session `done` with `budget_exhausted` |
| `wall_clock_seconds` | 60–86 400 | the agent's own | same |
| `approvals` | `wait` or `deny` — there is **no** `auto` | `wait` | `wait` leaves the approval for a person; `deny` answers no. A trigger that needs no approvals runs a profile whose bundle sets those tools to `auto` |

A session whose origin is a trigger or A2A and that nobody has marked reviewed is in the
review queue (`needs_review` on `sessions.list` and `admin.sessions.list`);
`session.review` clears it, audited. A person's own sessions are never in it.

## 4. Budgets

- A team's defaults come from the settings in force when it is enabled
  ([configuration.md Part C](configuration.md#part-c--platform-settings)); after that,
  `admin.team.update`. There is also a platform budget and a per-person budget;
  `admin.budget.explain` says which ceiling binds and why, `admin.person.budget` one
  person's.
- **Reservation, then spend.** A session reserves a slice at activation (`terms.budget_micros`
  or the default); the ledger records what model calls actually cost, one row per gateway
  request id. A reservation is granted when spend plus reservations stays within the
  budget, written before it is granted, and released when the session goes dormant. Zero
  is unlimited.
- **The period.** A `monthly` team counts what it spent since midnight UTC on the 1st of
  the month, and a team refused at its ceiling can start sessions again from then; `never`
  counts everything. A person's cap and the platform's have no period: they count
  everything, in every team.
- One budget actor per team, registered cluster-wide, which is why plane replicas must be
  clustered.
- Costs come from the gateway's `x-litellm-response-cost` header; without one, tokens are
  recorded at zero cost with a synthetic id `seq:<session>:<n>`, which the reconcile counts
  as unmetered ([integrations.md §5](integrations.md#5-llm-gateway)).
