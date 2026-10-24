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
 "agents":      [{"name": "pr-reviewer", "definition": "---\nmode: primary\n---\nYou review…"}],
 "skills":      [{"name": "review-checklist", "description": "How we review…",
                  "files": {"SKILL.md": "…", "checklist.md": "…"}}],
 "mcp_servers": [{"name": "jira", "url": "https://mcp.jira.example/mcp",
                  "credential_ref": "JIRA_MCP_TOKEN", "header": "authorization",
                  "timeout_ms": 30000, "permission": "ask",
                  "tools": ["search_issues", "get_issue"]}],
 "acp_agents":  [{"name": "gemini", "command": "gemini-cli",
                  "args": ["--acp"], "hash": "sha256:…"}]}
```

An `acp_agents` entry is another vendor's coding agent the worker runs as a subprocess and
speaks ACP to, through the session's mounts; a team's grant narrows it as it does an agent.

A document with no `schema` key is schema 0, of which only `mcp_servers` is read; it is
accepted for planes upgraded under one and never written again.

On a pod the bundle's agents and skills, and Troupe's built-in agents, beat a working
copy's of the same name unless the profile says otherwise
([profiles-and-policy.md](profiles-and-policy.md#a-repositorys-agents-and-skills-on-a-pod)).

**Validation.** At most 4 MiB; only those five keys; names `^[a-z0-9][a-z0-9-]{0,63}$`,
unique per kind. An agent's definition must parse as frontmatter plus prompt, may list only
skills the bundle has, and replaces an agent Troupe ships (`build`, `plan`, `general`,
`explore`, `quick`, `answer`, `ask`, `reviewer`, `implementer`, `librarian`,
`orchestrate`: every file in `troupe_core`'s `priv/agents/`) only with `override: true`;
without it the bundle is refused, naming the agent. A draft's agent is also held to every
rule the daemon holds an agent file to (`agents.validate`: its keys, a `mode`, tools the
harness has, permissions that can apply, and the rest), refused in the same words,
`agent <name>: <what is wrong>`; what only a session can know, a model's provider or an MCP
server's tool, is not checked. A version already published is not checked again, so one an
older plane published still runs. The console's agent builder edits a bundle's agents as
fields and asks `admin.agent.check` for one at a time (#594). It starts from the profile:
a profile's page lists its agents as its bundle in effect has them (`admin.profile.agents`),
each with its mode, model, who it hands work to, its cap on turns, what it runs without
asking and which of the profile's teams may run it (a grant that allows other agents, or
denies this one, says no), and opens the builder on the channel the agent came from. The
builder edits the subagents beneath their primary and its delegations, per-tool
permissions, `max_turns`, skills and a model picked from the ones the plane knows the
provider serves (`admin.profile.choices` with the profile: its own model, the
organisation's models for people's machines, the models its sessions have run on, and the
ones its bundle names; the plane never asks a provider for its list). **Copy** starts a new
agent from one Troupe ships or one already published. A skill needs `SKILL.md`
(whose `name`, if present, must be its own), relative text files with no `..`, at most
512 KiB. An MCP `url` is `https://`, or `http://` to a `.svc` host, and its host must pass
the policy's egress check. Publishing to a channel a pod profile follows also refuses a
`url` at a loopback, link-local, unspecified or cloud metadata address, in any spelling
([profiles-and-policy.md §4](profiles-and-policy.md#4-troupepolicy));
`admin.bundle.validate` is given no channel and does not make this check.

**A profile that extends another.** Any entry, of any kind, may say `"override": true`
(`true` or `false`, nothing else). It matters where a profile on this channel extends one on
another and the plane composes the two channels' bundles: an entry named like one in the
parent's bundle replaces it only with the flag
([profiles-and-policy.md](profiles-and-policy.md#a-profile-that-extends-another),
Decision 910).

**MCP entries.**

| Field | Meaning | Default |
|---|---|---|
| `name` | server name; tools appear as `mcp.<server>.<tool>` | required |
| `url` | streamable-HTTP endpoint | required |
| `credential_ref` | the **environment variable** holding the token, `^[A-Z][A-Z0-9_]{1,63}$` — never a value | none |
| `credential_mode` | whose credential goes out: `profile` (the token in `credential_ref`), `person` (the session owner's, `credential_ref` naming the slot), or `client_credentials` (the profile's own identity, below; no `credential_ref`) | `profile` |
| `header` | where the token goes; `authorization` gets a `Bearer ` prefix | `authorization` |
| `timeout_ms` | per call | 30000 |
| `permission` | `ask` or `auto`; an agent definition may tighten it | `ask` |
| `tools` | allowlist applied at discovery: an unlisted tool is absent, not denied | `all` |

On publish the plane projects each server onto the profile's resource. A `profile`-mode
server with a `credential_ref` gets `secretRef: {name: "troupe-mcp-<server>", key: "token"}`,
and the operator injects it as the `credential_ref` variable from an optional
`secretKeyRef`. So for every such server, **create `troupe-mcp-<server>` with key `token`
in `troupe-system`, labelled `troupe.dev/worker-secret=true`**: the operator copies it into
every `troupe-w-<profile>` whose profile follows the channel. Put its host in
`allowedEgress`. A `person` server is projected with its slot and a `client_credentials`
one with its mode alone; neither needs a Secret.

**A server that takes machine callers by client credentials** — a token that lasts an
hour, got with a signed assertion rather than a shared secret, with tools granted per
client — is marked `"credential_mode": "client_credentials"` and given no `credential_ref`
(a server with one beside it is refused). The bundle says only that: a channel serves
several profiles, and each profile is its own client there, with its own certificate and
granted tools, so who it is goes on the profile, in `spec.mcpIdentities`. Its key is kept in
OpenBao transit and signs without leaving it; there is no Secret to create. Setting up the
client, the certificate and the key, and rotating them, is in
[profiles and policy](profiles-and-policy.md#calling-an-mcp-server-as-the-profile)
(Decision 747).

**Publish, adopt, retire.** `admin.bundle.publish {channel, content}` validates, assigns
the channel's next version, stores the document under `sha256:<canonical JSON>`, pushes
`config.updated` to every pod on the channel and rewrites `mcpServers` on those profiles:
the channel's servers composed again with the ones each profile wrote itself, which a
publish keeps (Decision 910). A profile created on a channel, or moved onto one, gets the
channel's current servers on its resource with that write, not at the channel's next
publish.
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

**A server that accepts only a signed-in person** is not a bundle server. Some MCP servers
publish OAuth protected-resource metadata, answer a call without a token with `401`, and
act as the person who signed in, refusing a service account's token: a bundle server's
shared token is what they refuse, and a person-mode `credential_ref` slot holds a pasted
value, not a sign-in refreshed every hour. Each person adds such a server to their own
`mcp.json` with an `oauth.client_id` and signs in from the TUI or the desktop app
([configuration](../user/configuration.md#a-server-that-wants-you-to-sign-in)); the daemon
on their machine keeps and refreshes the tokens, and nothing of them reaches a pod or the
plane (Decision 741). What you provide is the client: register one public client (no
secret, PKCE, a loopback redirect such as `http://localhost`, any port where the provider
allows it) with the server's authorization server, grant it the server's scope, and give
people its id. Those tools serve their local sessions, and with their consent a session on
a pod through `tools.register` (Decision 748), never configured into the pod
([profiles](profiles-and-policy.md#a-persons-own-tools-on-a-pod)).

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
| `profile`, `agent` | where it starts and which primary agent; one the plane does not have is saved, and fails at each firing (the gitops reader refuses it up front) | profile required |
| `enabled` | a disabled trigger refuses to fire | `true` |
| `source` | `{"kind": "schedule", "cron": "…", "tz": "UTC"}`, `{"kind": "webhook", "provider": "…"}`, `{"kind": "webhook", "provider": "github", "repository": "owner/name", "label": "…", "command": "…"}` ([github.md §8](github.md#8-github-as-the-trigger)) or `{"kind": "manual"}`; a `tz` other than UTC is refused | required |
| `prompt_template` | ≤ 64 KiB, with `{{event.issue.key}}`, `{{trigger.name}}`, `{{run.fired_at}}` placeholders; a missing path renders empty, nothing is escaped | `""` |
| `terms` | §3 | `{}` |
| `visibility` | `private` or `team` | `team` |
| `review` | `required` or `none` | `required` |
| `notify` | subjects granted `collaborator` on every run's session | `[]` |
| `notify_url` | an absolute `http` or `https` URL posted the run's outcome when it ends, never its content; not loopback (`localhost` included), unspecified, link-local, multicast, a cloud metadata address (`fd00:ec2::254`, `100.100.100.200`) or in `100.64.0.0/10`, by address, in any IPv6 spelling of one, or by a name that resolves there (Decision 866), and a host the policy's egress allows, checked when saved and again at send, and posted to the address the second check passed, following no redirect | none |
| `concurrency` | cap on live runs, 1–100; a firing over it records a `skipped` run | 1 |

**Cron** is five fields (`*`, `*/n`, `n`, `a,b`, `a-b`, `a-b/n`; day-of-week 0–7), **UTC
only**, no names or `@daily`. **The in-plane scheduler** is one cluster-wide singleton
ticking every 30 s. Each tick fires every enabled schedule once for the latest due minute
after its last firing, with idempotency key `cron:<id>:<minute>`, so a plane that was down
fires once, not once per missed minute; a trigger that has never fired fires only if its
minute is within the last 120 s.

**Firing by hand or from outside.** `trigger.fire {trigger, idempotency_key, event}` on
`/rpc`, by the trigger's principal or an admin of its team, writes the run row first, so
two callers racing on one key get the same run: skipped stays skipped, failed is retried
under the caps as a new firing is, a
run with a session is handed it and a fresh token, and one still making its session is waited
for, up to five seconds, after which the answer is `409` naming the run. `event` is capped at
16 KiB.
`admin.trigger.run` fires one by hand, as the console's **Run now** on a trigger's page does;
a second click or a retry by the same person less than a minute after the first is the run
the first one made, whatever minute the clock has turned to between them.

**A trigger's own URL.** A trigger with a key is fired by `POST /trigger/<id>` with
`Authorization: Bearer <key>` and a JSON object as the body, which becomes the run's
`event`. The key fires that one trigger and nothing else, which makes it the credential to
give a CI job or a provider's webhook; a wrong key and an unknown id get the same `401`. An
`Idempotency-Key` header names the run; without one, a retry within a minute of the firing it
repeats, against the same revision, gets the run that firing made, whatever minute the clock
has turned to between them. The answer is `202` with the run and where its
session is, as from `trigger.fire`; a disabled trigger is `403`, an event over 16 KiB `413`
and a team with no budget left `402`. `source.kind: webhook` says a trigger is meant to be
fired from outside, this way or by an executor that calls `trigger.fire`.

A webhook trigger is made with its key: the `admin.trigger.put` that creates it answers
`key` and `url` once, and the console shows them once with a button that copies the key.
`admin.trigger.key.rotate` (the console's **Rotate**, typed by the trigger's name) mints a
new one at once, shown once with the URL and kept as a salted hash; it is how a webhook made
another way (a resource in `gitops` mode, or a trigger changed to a webhook) gets one. Only
a webhook that names no repository has a key: a schedule is fired by the plane, a manual
trigger by a person or a principal, and a trigger on a GitHub repository by the App's
signed deliveries, so rotating one of those is refused, and a trigger whose source changes
to one of those loses its key (changed back, it has none until a rotation; a listing's
`has_key` says which have one).

**Runs** store only what the plane decided — `created`, `skipped`, `failed` — and read the
rest from the session: `running`, `waiting` (on an approval), `done`, `failed`. A turn the
harness stopped is `failed` with its `failed_reason`: `tool_failures`, a tool that kept
failing, or `agent_failed`, an agent that kept crashing. A run that has had no session for
ten minutes, because the request that fired it ended before it made one, is ended `failed`
by the scheduler with the reason on the run and a `trigger.run.end` audit entry, so it no
longer holds a place against the caps. Firings that race are counted one after another,
under the trigger's row and, for a trigger on a repository, under one lock for every
repository cap, so a concurrency of 1 starts one of them. `admin.runs.list` and
`admin.run.review` are the inbox, which the console's **Runs and review** screen draws for
a platform admin and a team admin alike ([console.md](console.md#what-it-does)). A
`notify_url` is posted `{trigger, run, source, session_id, fired_at, state,
done_reason, failed_reason, pull_request}` when the run is `done` or `failed`, with
`state` as the run listing gives it and `pull_request` the link to the draft pull request
the run opened, or `null`.

### Triggers from a repository

In `gitops` mode ([gitops.md](gitops.md)) a repository holds the triggers as well as the
profiles (Decision 737): `Trigger` resources in the plane's namespace, applied by Flux or
anything like it. Every fifteen seconds, after the profiles, the plane lists them and makes
its triggers follow. A new resource becomes a trigger, a change changes it and makes a
revision as an edit does, and a resource that goes takes its trigger with it, runs and key
included. Each is audited as `trigger.put` or `trigger.delete` by `system:gitops`, with the
revision it made.

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

**What is used.** A resource is used only if `admin.trigger.put` would have saved it (its
name, source and cron, the keys of its terms, its visibility, review, cap and notification
target) and what it names is here: a team the plane has, a service principal of that team,
and a profile the plane has. Profiles are read first in the same pass, so a trigger and its
profile can arrive in one commit. A spec field a `Trigger` has not got is refused too: the
CRD keeps unknown fields so that a misspelt `promptTemplate` reaches the plane rather than
making a trigger that asks for nothing. One that fails is **refused**: a new one gets no
trigger, and a changed one leaves the trigger as the last version that passed, still
firing. The reasons are in the log once, in `admin.triggers.list` (each trigger carries
`gitops`: the resource, the generation it was read at, and a `problem` of `refused` or
`missing` with `reasons`; a refused resource with no trigger is listed by name, to a
platform admin with `team` null where it names no team the plane has), and on the
console's Triggers page.

**Locked.** The Triggers page is marked **Locked to gitops**, with no form, no switch and
no delete, and `admin.trigger.put` (switching one on or off included) and
`admin.trigger.delete` are refused as `managed_by_gitops` and audited with
`outcome: refused`. Switching a trigger off is a commit that sets `enabled: false`. In a
hurry, suspend the applier and patch the resource, which the plane follows within fifteen
seconds, or disable the trigger's principal, which stays the console's. A trigger the
cluster has no resource for (`missing`, below) may still be deleted.

**What stays the plane's.** Running one now (`admin.trigger.run`), its revisions and runs,
and its **key**, which is never in a resource: a key in a manifest would be a credential in
a repository, and a reference to a Kubernetes Secret would give the internet-facing plane a
grant on Secrets its Role deliberately lacks, only to hash a value it can mint itself. A
rotation also answers a leak, which cannot wait for a review and an applier's interval, so
`admin.trigger.key.rotate` works in `gitops` mode as in `direct`. A trigger's row is changed
in place when its resource changes, so its URL (`/trigger/<id>`) and its key survive every
commit; a trigger removed from the repository and added again is a new trigger, with a new
URL and no key.

**Teams, principals and grants** stay in the plane's database, and a trigger names them.
Enable the team and make the principal before the manifest merges, or the resource is
reported until they exist. Disabling a team deletes its triggers as it always has; their
resources are then reported as naming a team the plane does not have, until they leave the
repository.

**From a running plane.** `admin.profiles.export` gives every trigger as
`triggers/<team>/<trigger>.yaml`, beside the profiles and the policy, with its document and
nothing the plane keeps; a trigger with a key says so in a note, and the key keeps working
after the switch ([gitops.md](gitops.md#switching-a-running-plane)).

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
| `budget_micros` | ≥ 1, capped to the least any ceiling above it has left (team, person or platform); none left refuses the session with `budget_exhausted` | 5 000 000 | reserved at each activation |
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
- **A profile's budget** (Decision 910). A worker profile may carry `budget_micros`, a
  ceiling on what the sessions on it spend in a calendar month (UTC), whoever starts them
  and in whichever team. It is asked after the person's and before the team's, as their
  rung is, with the same reservations; a session it refuses is `budget_exhausted` with
  `scope: profile`, the profile's name and a sentence saying it is that profile's. A
  profile that extends another has the lower of its own and its parent's, and one set
  higher than its parent's is refused; each profile's sessions count against its own
  ceiling, not its parent's. `admin.budget.explain` with `profile` lists it, with
  `set_by`, the profile whose budget is in effect; `admin.profile.get` answers `budget`,
  what is spent and held this month. The console sets it on the profile's editor, in
  dollars, through the usual preview and audit.
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
- A call's cost is the gateway's `x-litellm-response-cost` header where it sends one (a
  streamed call never carries it), else the model catalog's price or `models.prices`,
  which on a pod is the profile's `llm.prices`; a model priced nowhere counts as free. A
  call with no gateway request id is recorded as `seq:<session>:<n>`, which the reconcile
  counts as unmetered ([integrations.md §5](integrations.md#5-llm-gateway)).
