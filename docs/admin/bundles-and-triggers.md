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
 "about":       {"summary": "Reviews pull requests against the house checklist."},
 "agents":      [{"name": "pr-reviewer", "definition": "---\nmode: primary\n---\nYou review…"}],
 "skills":      [{"name": "review-checklist", "description": "How we review…",
                  "agents": ["build", "pr-reviewer"], "files": {"SKILL.md": "…"}}],
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

`about` is what the apps' page on the profile says, never a session: at the top `{summary}`,
the sentence under its name (≤ 200 characters, else the primary agent's description); on a
server `{summary, tools}`, a subtitle and a line per tool it carries, any where `tools` is
`all` (each ≤ 120). A worker from before `about` refuses a top-level one: upgrade it first.

On a pod the bundle's agents and skills, and Troupe's built-in agents, beat a working
copy's of the same name unless the profile says otherwise
([profile-options.md](profile-options.md#a-repositorys-agents-and-skills-on-a-pod)).
An agent loads the skills its own `skills:` opens (`all` or a list; none by default), and
a skill opens itself with `agents`: `"all"`, or a list of names, Troupe's built-ins among
them, so `build` loads a bundle's skill without a copy of `build` in the bundle. A team's
grant narrows after both; `admin.profile.agents` says what each agent `loads` (Decision 980).

**Validation.** At most 4 MiB; only those six keys; names `^[a-z0-9][a-z0-9-]{0,63}$`,
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
512 KiB; its `agents` may name only the bundle's agents and Troupe's. An MCP `url` is `https://`, or `http://` to a `.svc` host, and its host must pass
the policy's egress check. Publishing to a channel a pod profile follows also refuses a
`url` at a loopback, link-local, unspecified or cloud metadata address, in any spelling
([profiles-and-policy.md §4](profiles-and-policy.md#4-troupepolicy));
`admin.bundle.validate` is given no channel and does not make this check.

**A profile that extends another.** Any entry, of any kind, may say `"override": true`
(`true` or `false`, nothing else). It matters where a profile on this channel extends one on
another and the plane composes the two channels' bundles: an entry named like one in the
parent's bundle replaces it only with the flag
([profile-options.md](profile-options.md#a-profile-that-extends-another), Decision 910).

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
| `stores` | `files`: where the organisation keeps files, which an agent asked for a file uses first ([profile options](profile-options.md#where-the-organisation-keeps-files)) | unset |
| `files` | with `stores: files`, the tools that save a file | all of them |
| `about` | `{summary, tools}`: a subtitle and a line per tool for the profile's page (above) | unset |

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
[profiles and policy](profile-options.md#calling-an-mcp-server-as-the-profile) (Decision 747).

**Publish, adopt, retire.** `admin.bundle.publish {channel, content}` validates, assigns the
channel's next version, stores the document under `sha256:<canonical JSON>`, pushes
`config.updated` to every pod on the channel and rewrites `mcpServers` on those profiles:
the channel's servers composed again with the ones each profile wrote itself, which a
publish keeps (Decision 910). A profile created on a channel, or moved onto one, gets the
channel's current servers with that write, not at its next publish. History is append-only;
a rollback is a new version with the old content. Pods fetch the version over the control
channel, verify the hash and materialise `bundles/<hash>/{agents, skills, bundle.json}`; one
that missed the push catches up at its next heartbeat. `admin.bundle.get` shows per profile
which pods are `current`, `ahead` or `stale`. `admin.bundle.validate`,
`admin.bundle.preview` and `admin.mcp.check` run the checks without publishing.

A publish moves **no running or sleeping session**: each keeps its pinned version until its
owner raises it to the channel's current one (`session.bundle.raise`: *Update* in the session
panel, `/bundle update`) or `admin.bundle.retire` retires it, at its next start, with a durable
`config_upgraded`. A channel with nothing published offers the built-in agents, unless the
profile's `spec.agents` rule leaves some out ([profile options](profile-options.md#which-agents-a-profile-has)).

**A server that accepts only a signed-in person** is not a bundle server. Some MCP servers
publish OAuth protected-resource metadata, answer a call without a token with `401`, and
act as the person who signed in, refusing a service account's token: a bundle server's
shared token is what they refuse, and a person-mode `credential_ref` slot holds a pasted
value, not a sign-in refreshed every hour. Each person adds such a server to their own
`mcp.json` with an `oauth.client_id` and signs in from the TUI or the desktop app
([a server that wants you to sign in](../user/mcp.md#a-server-that-wants-you-to-sign-in)); the daemon
on their machine keeps and refreshes the tokens, and nothing of them reaches a pod or the
plane (Decision 741). What you provide is the client: register one public client (no
secret, PKCE, a loopback redirect such as `http://localhost`, any port where the provider
allows it) with the server's authorization server, grant it the server's scope, and give
people its id. Those tools serve their local sessions, and with their consent a session on
a pod through `tools.register` (Decision 748), never configured into the pod
([profiles](profile-options.md#a-persons-own-tools-on-a-pod)).

### Bundles from a repository

In `gitops` mode ([gitops.md](gitops.md)) a repository may hold a channel's bundle as a
`ConfigBundle` resource in the plane's namespace, named for the channel, its `spec` the
document exactly as `admin.bundle.publish` takes it. Every fifteen seconds, before the
profiles, the plane lists them, so a profile and the prompt its bundle gives it can land in
one commit and one pass.

```yaml
# bundles/stable.yaml
apiVersion: troupe.dev/v1alpha1
kind: ConfigBundle
metadata:
  name: stable
  namespace: troupe-system
  annotations:
    troupe.dev/revision: 4f2a9c1   # optional, shown and never trusted
spec:
  schema: 1
  agents:
    - name: pr-reviewer
      definition: |
        ---
        mode: primary
        ---
        You review pull requests against the house checklist.
```

- **Published on change.** A resource is checked as a publish is and, when its content's hash
  differs from what this resource last published, becomes the channel's next version by
  `system:gitops`, audited as `bundle.publish` with the resource's generation and revision.
  The hash is `sha256:` over the spec's canonical JSON, which `admin.bundle.validate`
  answers for the file, so a version can be matched to a commit. A first resource whose
  content is already the channel's current version holds it with no new version
  (`bundle.hold`). A revert commit is a new version carrying the old content: the number
  never goes back.
- **At most 1 MiB** of JSON (a bundle published by hand may be 4 MiB). Apply it
  server-side, as Flux does: a client-side `kubectl apply` stops near 256 KiB. One the API
  server refuses never reaches the plane; `flux get kustomizations` says why.
- **Refused**, with the reasons in the log once, in `admin.bundle.channels` and on the
  console's Configuration bundles page: the channel keeps its current version.
- **Held.** `admin.bundle.publish` on the channel is refused as `managed_by_gitops`;
  `admin.bundle.retire` stays a person's. The pass does not publish a retired version again
  (it reports `retired`); a commit that changes the content does. Every other channel is
  published by hand as before, so a plane moves one channel at a time.
- **Removed.** A resource that goes releases its channel (`bundle.release`): no version is
  retired, the current one stays, and pinned sessions notice nothing.

Prompts, skill files, MCP server URLs and tool lists become as public as the repository; a
credential never is, since a bundle names only the variable it is in. A channel whose name
is not a Kubernetes name cannot be held. `admin.bundle.channels` lists each channel with its
current version, its profiles and what the last pass made of it.

## 2. Triggers

A trigger is a row the plane stores and something fires; firing creates a session **as
the trigger's principal** through the same `session.create` a person uses, so grants,
budgets, agents and terms all apply. Triggers, principals and runs live only in PostgreSQL:
unlike the session index they cannot be rebuilt from object storage. In `gitops` mode a
repository holds the triggers' definitions as well ([triggers-from-a-repository.md](triggers-from-a-repository.md)).

| Field | Meaning | Default |
|---|---|---|
| `team`, `name` | owner, and `^[a-z0-9][a-z0-9-]{0,62}$` unique per team | required |
| `principal` | a principal of the same team, which the session runs as | required |
| `profile`, `agent` | where it starts and which primary agent; one the plane does not have is saved, and fails at each firing (the gitops reader refuses it up front) | profile required |
| `enabled` | a disabled trigger refuses to fire | `true` |
| `source` | `{"kind": "schedule", "cron": "…", "tz": "UTC"}`, `{"kind": "webhook", "provider": "…"}`, `{"kind": "webhook", "provider": "github", "repository": "owner/name", "label": "…", "command": "…"}` ([Runs on GitHub](github-runs.md#github-as-the-trigger)) or `{"kind": "manual"}`; a `tz` other than UTC is refused | required |
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
`/rpc`, by the trigger's principal or an admin of its team, writes the run row first, so two
callers racing on one key get the same run: skipped stays skipped, failed is retried under
the caps as a new firing is, a run with a session is handed it and a fresh token, and one
still making its session is waited for, up to five seconds, after which the answer is `409`
naming the run. `event` is capped at 16 KiB. `admin.trigger.run` fires one by hand, as the
console's **Run** on a trigger's page does (its confirmation, **Run** *the trigger's name*
**now**); a second click or a retry by the same person less than a minute after the first is
the run the first one made, whatever minute the clock has turned to between them.

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

### A person's own triggers

A member makes no trigger with the admin API. In a pod session they started, the harness
may propose one when the turn published an artifact after the session read live data, and
the owner's **Turn on** (`session.proposal.accept`, Decision 1111;
[reruns](../user/reruns.md)) makes it:

- **The person's own principal**, `svc:<team>/own-<handle>`, made once per team and reused,
  sponsored by them, with the session's profile among its profiles. Its spend lands on the
  sponsor's person budget, then the profile's, the team's and the platform's (§4); it is
  disabled when they leave the team's group, as any sponsored principal is. Its secret is
  never shown: nothing signs in as it but the plane's triggers. It is listed with the team's
  principals, and audited `principal.create` with `via: proposal`.
- **The trigger**, the team's row under that principal: the session's profile and agent, its
  visibility, `review: required`, `notify` the owner, `concurrency` 1, the schedule and
  prompt the harness drafted as the owner left them, and `terms` with `approvals: deny`,
  `budget_micros` 1 000 000 unless the owner changed it, and `allow` (§3). Audited
  `trigger.put` with `via: proposal`, the session and the principal. A team admin changes
  or deletes it like any other.
- **An `edit` grant** for the principal on the artifact, where the owner holds it alone, so
  each run publishes its next version; a team's artifact is the principal's team's already.

A team admin turns this off for their team with **Members may schedule a report** on the
team's *Limits* tab (`members_may_schedule`, on by default, under the platform setting of
the same name, which may only narrow it); off, no session of the team proposes one, and the
triggers already made keep running. A person holds at most five such triggers per team. On a
gitops plane Turn on makes nothing: the owner is handed the `Trigger` resource, with no
principal, to commit. A "never for this report" is kept per person and artifact.

## 3. Unattended session terms

`session.create`, and so every trigger and A2A task, accepts `terms`, validated before the
session exists and re-sent on every activation:

| Term | Range | Default | Effect |
|---|---|---|---|
| `budget_micros` | ≥ 1, capped to the least any ceiling above it has left (team, person or platform); none left refuses the session with `budget_exhausted` | 5 000 000 | reserved at each activation |
| `max_turns` | 1–500 | the agent's own | ends the session `done` with `budget_exhausted`; with this or `wall_clock_seconds` set, every limit of the session stops it rather than asking |
| `wall_clock_seconds` | 60–86 400 | the agent's own | same, counted in working time: a turn's time, not the time the session is awake |
| `approvals` | `wait` or `deny` — there is **no** `auto` | `wait` | `wait` leaves the approval for a person; `deny` answers no. A trigger that needs no approvals runs a profile whose bundle sets those tools to `auto`. With neither limit above set, a spent budget asks the person attached, as on a laptop, and `deny` answers that no too |
| `allow` | at most 16 per-tool rules, written as in a configuration file (`publish_artifact`, `shell(curl)`, `mcp(crm.list_deals)`) | none | what a run may do unasked under `approvals: deny`, read as the trigger's own layer beside the profile's rules: a profile's `ask` or `deny` of the same tool still holds, so a run that needs it stops there. The `Trigger` resource spells it `allow` too |

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
- A call's cost is the gateway's (LiteLLM's in a streamed call's usage, or its cost
  header), else the catalog's price or `models.prices`, on a pod the profile's
  `llm.prices`; a model priced nowhere counts as free. A call with no gateway request id
  is recorded as `seq:<session>:<n>`, which the reconcile counts as unmetered
  ([integrations.md §5](integrations.md#5-llm-gateway)).
