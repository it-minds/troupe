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

**A server that accepts only a signed-in person** is not a bundle server. Some MCP
servers publish OAuth protected-resource metadata, answer a call without a token with
`401`, and act on what is behind them as the person who signed in, refusing a service
account's token outright; a bundle server's one shared token from a Secret is exactly
what they refuse, and a person-mode server's `credential_ref` slot holds a value the
person pasted, not a sign-in that expires every hour and has to be refreshed. For such a
server, each person adds it to their own `mcp.json` with an `oauth.client_id` and signs
in from the TUI or the desktop app ([configuration](../user/configuration.md#a-server-that-wants-you-to-sign-in));
the daemon on their machine keeps and refreshes the tokens, and nothing of them reaches a
pod or the plane (Decision 741). What you provide is the client: register one public
client (no secret, PKCE, a loopback redirect such as `http://localhost`, with any port
where the provider allows it) with the server's authorization server, grant it the
server's scope, and give people its id. Today that serves their local sessions; offering
those tools to a session on a pod, through `tools.register` from the person's client, is
the next step.

## 2. Triggers

A trigger is a row the plane stores and something fires; firing creates a session **as
the trigger's principal** through the same `session.create` a person uses, so grants,
budgets, agents and terms all apply. Triggers, principals and runs live only in PostgreSQL:
unlike the session index they cannot be rebuilt from object storage. In `gitops` mode a
repository holds the triggers' definitions as well ([below](#triggers-from-a-repository)).

| Field | Meaning | Default |
|---|---|---|
| `team`, `name` | owner, and `^[a-z0-9][a-z0-9-]{0,62}$` unique per team | required |
| `principal` | a principal of the same team, which the session runs as | required |
| `profile`, `agent` | where it starts (a profile the plane has, one of the principal's) and which primary agent | profile required |
| `enabled` | a disabled trigger refuses to fire | `true` |
| `source` | `{"kind": "schedule", "cron": "…", "tz": "UTC"}`, `{"kind": "webhook", "provider": "…"}` or `{"kind": "manual"}`; a `tz` other than UTC is refused | required |
| `prompt_template` | ≤ 64 KiB, with `{{event.issue.key}}`, `{{trigger.name}}`, `{{run.fired_at}}` placeholders; a missing path renders empty, nothing is escaped | `""` |
| `terms` | §3 | `{}` |
| `visibility` | `private` or `team` | `team` |
| `review` | `required` or `none` | `required` |
| `notify` | subjects granted `collaborator` on every run's session | `[]` |
| `notify_url` | an absolute `http` or `https` URL posted the run's outcome when it ends, never its content; not loopback or link-local, and a host the policy's egress allows, checked when saved and again at send | none |
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
`admin.trigger.run` fires one by hand.

**A trigger's own URL.** A trigger with a key is fired by `POST /trigger/<id>` with
`Authorization: Bearer <key>` and a JSON object as the body, which becomes the run's
`event`. `admin.trigger.key.rotate` mints the key, shows it once with the URL and keeps a
salted hash; rotating again replaces it at once. The key fires that one trigger and does
nothing else, which makes it the credential to give a CI job or a provider's webhook, and
a wrong key and an unknown id get the same `401`. An `Idempotency-Key` header names the
run; without one, a retry in the same minute against the same revision gets the run it
already made. The answer is `202` with the run and where its session is, as from
`trigger.fire`; a disabled trigger is `403`, an event over 16 KiB `413` and a team with no
budget left `402`. `source.kind: webhook` says a trigger is meant to be fired from
outside, this way or by an executor that calls `trigger.fire`; any trigger with a key can
be.

**Runs** store only what the plane decided — `created`, `skipped`, `failed` — and read the
rest from the session: `running`, `waiting` (on an approval), `done`, `failed`.
`admin.runs.list` and `admin.run.review` are the inbox.

### Triggers from a repository

In `gitops` mode ([profiles-and-policy.md §6](profiles-and-policy.md#6-provisioning-direct-or-from-a-repository))
a repository holds the triggers as well as the profiles (Decision 737): `Trigger`
resources in the plane's namespace, applied by Flux or anything like it. Every fifteen
seconds, in the pass that reads the profiles and after them, the plane lists them and
makes its triggers follow. A new resource becomes a trigger, a change changes it and makes
a revision as an edit did, and a resource that goes takes its trigger with it, runs and key
included, so that it stops firing. Each is audited as `trigger.put` or `trigger.delete` by
`system:gitops`, with the revision it made.

One resource per trigger, named **`<team>.<trigger>`**: a trigger's name is unique within
its team and a resource's within its namespace, a dot is in neither, and a team said once
has no second field to disagree with. The principal is named by subject.

```yaml
# triggers/platform/nightly-digest.yaml
apiVersion: troupe.dev/v1alpha1
kind: Trigger
metadata:
  name: platform.nightly-digest
  namespace: troupe-system
spec:
  principal: svc:platform/nightly
  profile: standard
  agent: reviewer
  enabled: true
  source:
    kind: schedule
    cron: "0 3 * * 1-5"
    tz: UTC
  promptTemplate: |
    Summarise yesterday's merged pull requests for the platform team.
  terms:
    budgetMicros: 2000000
    maxTurns: 30
    approvals: deny
  visibility: team
  review: required
  notify: [lead@example.com]
  notifyUrl: https://hooks.example.com/troupe
  concurrency: 1
```

| Trigger | Resource |
|---|---|
| `team`, `name` | `metadata.name`, split at its dot |
| `principal` | `spec.principal`: `svc:<team>/<name>`, a service principal of that team |
| `profile`, `agent`, `enabled`, `source`, `visibility`, `review`, `notify`, `concurrency` | the same names, with the defaults in the table above |
| `prompt_template` | `spec.promptTemplate` |
| `notify_url` | `spec.notifyUrl` |
| `terms` (§3) | `spec.terms`, spelt `budgetMicros`, `maxTurns`, `wallClockSeconds`, `approvals` |

A field the manifest leaves out is its default, not what the trigger said before.

**What is used.** A resource is used only if `admin.trigger.put` would have saved it — its
name, its source and cron, the keys of its terms, its visibility, review, cap and
notification target — and what it names is here: a team the plane has, a service principal
of that team, and a profile the plane has. Profiles are read first in the same pass, so a
trigger and the profile it starts on can arrive in one commit. A field of the spec that a
`Trigger` has not got is refused as well: the CRD keeps what it does not know so that a
misspelt `promptTemplate` reaches the plane, rather than being dropped on the way and
making a trigger that asks for nothing. One that fails is **refused**: a new one gets no
trigger, and a changed one leaves the trigger as the last version that passed, still
firing. The reasons are in the log once, in `admin.triggers.list` (each trigger carries
`gitops`: the resource, the generation it was read at, and a `problem` of `refused` or
`missing` with `reasons`; a refused resource of the team with no trigger is listed by name,
and one naming no team the plane has is listed to a platform admin with `team` null), and
on the console's Triggers page.

**Locked.** The Triggers page is marked **Locked to gitops**, with no form, no switch and
no delete, and `admin.trigger.put` (switching one on or off included) and
`admin.trigger.delete` are refused as `managed_by_gitops` and audited with
`outcome: refused`. Switching a trigger off is a commit that sets `enabled: false`. In a
hurry, suspend the applier and patch the resource, which the plane follows within fifteen
seconds, or disable the trigger's principal, which stays the console's. A trigger the
cluster has no resource for (`missing`, below) may still be deleted.

**What stays the plane's.** Running one now (`admin.trigger.run`), its revisions and runs,
and its **key**. The key is never in a resource: the plane mints it, shows it once and
keeps a salted hash, so there is nothing to put in one. A key in a manifest would be a
credential in a repository, and a reference to a Kubernetes Secret would give the plane,
which faces the internet, a grant on Secrets that its Role deliberately does not have,
only to hash a value it could have minted itself. A rotation also answers a leak, which
cannot wait for a review and an applier's interval. So `admin.trigger.key.rotate` works in
`gitops` mode as it does in `direct`. A trigger's row is changed in place when its resource
changes, so its URL (`/trigger/<id>`) and its key survive every commit; a trigger removed
from the repository and added again is a new trigger, with a new URL and no key.

**Teams, principals and grants** stay in the plane's database, and a trigger names them.
Enable the team and make the principal before the manifest merges, or the resource is
reported until they exist. Disabling a team deletes its triggers as it always has; their
resources are then reported as naming a team the plane does not have, until they leave the
repository.

**From a running plane.** `admin.profiles.export` gives every trigger as
`triggers/<team>/<trigger>.yaml`, beside the profiles and the policy, with its document and
nothing the plane keeps. A trigger with a key says so in a note: the key keeps working
after the switch, because the resource of the same name is read into the row that holds
it. A trigger the cluster has no resource for after the switch is reported `missing`, kept,
and goes on firing until its manifest is committed or it is deleted.

Applied by Flux in a Kustomization of its own, after the profiles':

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: troupe-triggers
  namespace: flux-system
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: fleet
  path: ./triggers
  prune: true
  dependsOn:
    - name: troupe-profiles
```

Of its own because Flux applies a Kustomization as a whole, and a trigger the API server
refuses should not hold back a profile. With `prune: true`, a manifest removed from the
repository deletes its resource and the plane then removes the trigger. A directory per
team is also what a `CODEOWNERS` file can give each team to review.

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
  counts everything. A person's cap and the platform's (and the deployment's) are always
  monthly in the same way, whatever their teams' periods: a person's counts what they
  spent this month in every team, the platform's what everybody did.
- One budget actor per team, registered cluster-wide, which is why plane replicas must be
  clustered.
- Costs come from the gateway's `x-litellm-response-cost` header; without one, tokens are
  recorded at zero cost with a synthetic id `seq:<session>:<n>`, which the reconcile counts
  as unmetered ([integrations.md §5](integrations.md#5-llm-gateway)).
