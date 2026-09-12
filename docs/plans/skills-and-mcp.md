# Skills and MCP servers, preconfigured

An admin decides once which skills and which MCP servers a worker profile carries, and
every session created on that profile has them from its first turn. Nobody configures
anything at session time; nobody's personal credentials are involved.

This is the first of four plans. It comes first because the other three lean on it: a
triggered session and an A2A task both need a profile whose capabilities are declared,
and a synced private session needs to know which of its tools were the machine's and
which were the profile's.

---

## Brings, takes, already in place

**Brings.** A profile becomes a described capability rather than a bare model with file
tools: "the `reviewer` profile knows our review checklist and can read Jira". A new
session gets that without anybody pasting a prompt, and a change to it reaches every
future session, is versioned, and shows up in the log of any session that moved.

**Takes.** A schema for what a bundle carries; a worker that materialises a bundle on
disk and loads agents and skills from it; a skill tool; the operator injecting MCP
credentials and punching egress for MCP hosts; and structured editors in the panel
instead of a JSON textarea.

**Already in place.**

* Bundles are versioned, immutable per version, hashed over canonical JSON, published
  and retired over `admin.bundle.*` in the API, the CLI and the panel, announced to
  pods over the control channel, and pinned per session at creation with a durable
  `config_upgraded` event when a session moves versions at activation
  (`apps/troupe_plane/lib/troupe/plane/bundles.ex`, `fleet/bundle.ex`, DECISIONS 125–127).
* The MCP client exists: HTTP transport, discovery per pod, tools named
  `mcp.<server>.<tool>`, `ask` by default, a profile may lower to `auto`, the server sees
  its own credential and nothing about the user (`apps/troupe_protocol/lib/troupe/mcp/`,
  `apps/troupe_core/lib/troupe/mcp/`, DECISIONS 120–124).
* Agent definitions are markdown with frontmatter, loaded once per session from three
  directories in a fixed order (`apps/troupe_core/lib/troupe/agent/definitions.ex:29-37`).
* Egress is a policy of hostnames the plane cannot widen
  (`apps/troupe_protocol/lib/troupe/policy.ex`, `charts/troupe/crds/troupepolicy.yaml`).
* Personal MCP servers already have their own door — `tools.register` with a consent
  challenge, `client.*` names, a `session_tainted` event — and must never be configured
  into a pod (`apps/troupe_tui/lib/troupe/ui/tui/connectors.ex:5-8`).

## What is missing today, precisely

Found while mapping the code; each is a line of this plan.

| Gap | Where |
| --- | --- |
| Bundle `content` is a free-form map with no validation; the only key any code reads is `mcp_servers`. `agents` and `skills` are in the docs and the panel's placeholder and nowhere else. | `bundles.ex:133`, `web/live/bundles.ex:102` |
| No bundle source in the agent definition search order. A published agent definition reaches no session. | `definitions.ex:29-37` |
| Skills do not exist in code. | four prose mentions, no module |
| The worker applies what the push carries and verifies no hash; there is no `bundle.fetch`. | `apps/troupe_worker/lib/troupe/worker/plane/commands.ex:176-187` |
| Workers never report `bundle_hash` in enrolment or heartbeat, so adoption reads every pod as stale. | `apps/troupe_worker/lib/troupe/worker/plane/link.ex:125,357` |
| `WorkerProfile.spec.mcpServers[].secretRef` is validated and counted for egress, but the operator never turns it into pod env. | `apps/troupe_operator/lib/troupe/operator/resources.ex:476-580` |
| A bundle's MCP hosts never reach `egress_destinations/1`, so on a Cilium cluster a bundle-supplied server cannot be resolved. | `apps/troupe_protocol/lib/troupe/worker_profile.ex:141-148` |
| Cilium rules use `matchName` only; a wildcard in `allowedEgress` passes validation and produces a dead rule. | `resources.ex:346` |
| `config.yaml` has no MCP key; the third configuration path (`:troupe_worker, :mcp_servers` app env) is set by nothing. | `apps/troupe_core/lib/troupe/config.ex`, `worker/mcp.ex:80` |

---

## Design

### 1. The bundle gets a schema

`content` becomes a versioned, validated document. `schema: 1` is required; a bundle
without it is refused at publish, and the existing free-form bundles in any database
are read as `schema: 0` and treated as `mcp_servers`-only, which is what they were.

```json
{
  "schema": 1,
  "agents": [
    {"name": "reviewer", "definition": "---\ndescription: …\nmode: primary\nskills: [review-checklist]\n---\nYou review code…"}
  ],
  "skills": [
    {"name": "review-checklist",
     "description": "How we review a pull request at IT Minds",
     "files": {"SKILL.md": "---\nname: review-checklist\n…", "checklist.md": "…"}}
  ],
  "mcp_servers": [
    {"name": "jira", "url": "https://mcp.jira.example/mcp",
     "credential_ref": "JIRA_MCP_TOKEN", "header": "authorization",
     "timeout_ms": 30000, "permission": "ask",
     "tools": ["search_issues", "get_issue"]}
  ]
}
```

Validation, in the plane at publish and again in the worker before applying:

* `agents[].definition` must parse with `Troupe.Agent.Definition` (same parser the worker
  uses, in `troupe_core`; the plane does not depend on core, so the parser's
  frontmatter half moves to `troupe_protocol` as `Troupe.Protocol.AgentDefinition` and
  core calls it). Names are `[a-z0-9-]+`, unique within the bundle, and may not shadow
  a built-in unless the bundle says `override: true` — an admin replacing `build` should
  have meant to.
* `skills[].files` must contain `SKILL.md` whose frontmatter `name` equals the entry's
  name. Total bundle size ≤ 4 MiB (the router already allows that body); a single skill
  ≤ 512 KiB; file names are relative, no `..`, no absolute paths.
* `mcp_servers[].url` must be `https://` (or `http://` only to a `*.svc` host), and its
  host must match the cluster policy's `allowedEgress` — the plane reads `TroupePolicy`
  already (`plane-rbac.yaml`) and refuses a publish naming a host the policy would not
  let a pod reach, with the host in the error. `credential_ref` is a name; a value that
  looks like a token (contains no `[A-Z_]` shape, longer than 64 chars) is refused,
  because a secret value in the plane database is on the forbidden list.
* `permission` is `ask` (default) or `auto`; `tools` is an optional allowlist of server
  tool names, applied at discovery so unlisted tools are never offered to a model.

### 2. Agents and skills reach a session

**Materialisation.** A worker keeps every bundle version it has been told about under
`$TROUPE_STATE_HOME/bundles/<hash>/` with `agents/*.md` and `skills/<name>/…` written
from the document, plus the document itself. The directory is named by hash, so two
versions with identical content share nothing but agree, and a session pinned to
version 3 reads `bundles/<hash of 3>/` however many versions have been published since.
Writing is atomic (scratch directory, rename), and a directory that exists is never
rewritten.

**Fetch, verify, report.** `config.updated` keeps announcing `{channel, version,
bundle_hash}` but no longer carries content. The worker answers a new control RPC
`bundle.fetch {hash}` → the document, verifies `Bundle.hash/1` over canonical JSON
equals the announced hash, and only then materialises it. On enrolment and in every
heartbeat the worker reports the hash of the newest bundle it has materialised, which
makes `Bundles.adoption/2` true instead of always stale. A pod that cannot fetch keeps
serving the version it has; the plane logs the pod as behind. This is what DECISIONS 126
described and the code skipped.

**Loading.** `Troupe.Agent.Definitions.load/2` gains a `bundle_dir` option, inserted in
the order between built-ins and the config directory: built-in < bundle < global <
project. On a worker, `global` and `project` are empty by design, so the bundle is the
effective source; on a laptop the option is absent and nothing changes. The session's
pinned version chooses the directory. The `source` field grows `:bundle`, and the
`agent_started` event's data grows `bundle_version`, so a transcript says which
definition it ran under.

**Skills** are directories in the Agent Skills convention: `SKILL.md` with frontmatter
`name` and `description` and a body of instructions, beside any files the instructions
refer to. They are used progressively:

* The system prompt of any agent whose definition lists them (`skills: [names]`, or
  `skills: all`) gets one line per skill: name and description. Nothing else is loaded
  until asked for. A definition that names a skill the bundle lacks fails validation at
  publish, not at session time.
* A `skill` tool — a `Troupe.Tool` value, not a module, per DECISIONS 120 — takes
  `{name}` and returns the body of `SKILL.md` and the list of files. It is `auto`, it
  reads only from the pinned bundle directory, and its call and result land in the log
  as any tool's do, so a transcript shows which skill was consulted and when.
* The skill's files are readable through the existing `read_file` tool under a
  read-only `skills:/<name>/…` mount. `Troupe.Mounts` already models `session:/`,
  team and org volumes with modes; a `skills:` entry of kind `:bundle`, mode `ro`,
  path `bundles/<hash>/skills` is one more line in `mounts_resolved`. `write_file` and
  `shell` cannot reach it; the sandbox mounts it read-only.

The same directory convention works on a laptop (`.troupe/skills/`, `$XDG_CONFIG_HOME/troupe/skills/`), with the same precedence as agents, so a skill can be developed locally and published unchanged. That is out of this plan's first slice but costs nothing to keep open.

### 3. MCP servers, one source of truth

The bundle is where an admin declares MCP servers; the CRD field stays, but the plane
writes it. On publish, for every profile on the channel, the plane rewrites
`WorkerProfile.spec.mcpServers` from the bundle: name, url, and `secretRef` derived from
`credential_ref` by a fixed convention — Secret `troupe-mcp-<server>`, key `token`, in
the worker namespace. That gives the operator what it lacks today in one place:

* `egress_destinations/1` sees the MCP hosts, so Cilium FQDN rules and the admission
  check cover them (fixes the invisible-to-egress gap).
* A new `mcp_env/1` in `resources.ex` injects each `secretRef` as the env var the
  `credential_ref` names, `secretKeyRef` and `optional: true`, so a missing secret is the
  `SecretMissing` condition the profile already reports rather than a pod that will not
  start (fixes the never-injected gap). Troupe still creates no secrets; the panel shows
  the Secret name and namespace an admin must create, and the profile's condition tells
  them when it is not there.
* Cilium rules gain `matchPattern` for wildcard entries and keep `matchName` for exact
  ones, so `allowedEgress` wildcards mean what they say.

A change of MCP servers therefore takes effect twice: pods re-discover tools on
`config.updated` (existing), and the operator rolls the StatefulSet when the env
changes (existing behaviour of a spec change). Discovery stays per pod (DECISIONS 124).
The `tools` allowlist from the bundle is applied in `Troupe.Worker.MCP` after
`list_tools`, and `permission` becomes the tool's `default_permission`, which an agent
definition's `permissions:` map may still tighten but not loosen below the bundle's.

In `gitops` provisioning mode the plane writes the same `mcpServers` into the commit it
already writes; nothing new.

**Personal servers stay personal.** Nothing here touches `tools.register`. A team
credential for an MCP server is a Kubernetes Secret in the profile's namespace; a
per-user credential is a `client.*` tool the harness serves under consent. There is no
third kind, and the panel says so where an admin might look for one.

### 4. Auto-setup at session create

Already true once 1–3 exist: `session.create` pins the channel's current version, the
worker activates with that version, the agent definition comes from the bundle, its
skills are listed in its prompt, and the pod's MCP tools are the bundle's. Two small
additions make it visible:

* `session.create` on the plane accepts `agent` (a primary defined in the bundle or
  built in), validated against the pinned version; `profiles.list` returns each
  profile's channel, current version, and the primaries, skills and MCP servers it
  carries, so a GUI can show what a session will have before creating it.
* `session_created.data` gains `bundle_version`, and the summary a `fleet` subscriber
  sees carries it, so HQ shows which sessions run on an old version.

### 5. The admin surface

The `/bundles` textarea is replaced by three structured pages that compose one draft
and publish it as one version:

* **Agents** — list, edit (frontmatter fields as inputs, prompt as text), diff against
  the current version, validation errors inline.
* **Skills** — list, upload a directory as a zip or paste files, preview `SKILL.md`,
  see which agents list the skill.
* **MCP servers** — name, URL, credential reference, permission, tool allowlist; a live
  policy check ("host not in `allowedEgress`") and the Secret the admin must create,
  with the current `SecretMissing` state per profile.

A **Publish** action shows the composed document, its hash, the profiles on the
channel, and after publishing, adoption per pod from the heartbeat. The pages call
public methods only: `admin.bundle.draft.get/put`, `admin.bundle.publish`,
`admin.bundle.diff`, `admin.mcp.check` — each added to `Admin`, `Admin.API` and
`Ctl.Admin` together, or the parity test fails. `troupe admin bundle publish <channel>
<dir>` learns to build the document from a directory laid out as `agents/`, `skills/`,
`mcp.yaml`, which is how a bundle lives in a git repository.

### 6. Security, spelled out

* No secret values in the plane, ever: `credential_ref` is validated as a name, the
  Secret lives in the worker namespace, the panel never reads it (forbidden list).
* A skill's files are read-only to every tool and the sandbox; a skill cannot carry an
  executable that `shell` could run from its own directory, because the mount is `ro`
  and `noexec`.
* Bundle content is authored by platform admins only (existing `bundle.publish` gate)
  and audited (existing `Audit.record`). A prompt injected through a skill is an
  admin's act, in the audit log, with a version and a hash.
* MCP servers get a session's identity in `_meta` only, and no user token, unchanged.
* The `tools` allowlist is enforced at discovery, so an unlisted tool is not merely
  denied but absent from what the model can see.

---

## Data model

No new tables. `config_bundles.content` carries the document; `schema` is inside it.
One column: `config_bundles.summary :map` — counts and names of agents, skills and
servers, written at publish, so lists do not decode 4 MiB documents.

Plane → worker control RPCs: `bundle.fetch {hash}` → document. Worker → plane: the
`bundle_hash` claim in enrolment and heartbeat, populated.

Events: `agent_started.data.bundle_version`, `session_created.data.bundle_version`,
`mounts_resolved` entries of kind `bundle`. All additive within protocol v1.

---

## Order of work

1. Schema and validation in the plane; `schema: 0` compatibility; `summary` column.
   Parser split into `troupe_protocol`.
2. Worker: `bundle.fetch`, hash verification, materialisation, heartbeat claim.
   Adoption becomes true.
3. `Definitions.load/2` with the bundle source; `agent_started.bundle_version`.
4. Skills: the mount, the `skill` tool, the prompt lines, the `skills:` frontmatter key.
5. Operator: `mcp_env/1`, plane writes `mcpServers` from the bundle, Cilium
   `matchPattern`.
6. `session.create agent:`, `profiles.list` detail, `session_created.bundle_version`.
7. Panel pages and CLI directory publish.

Steps 1–3 ship together as a release that changes nothing for a bundle that only has
`mcp_servers`. Steps 4 and 5 are independent of each other.

## Done items, proven by command output

* Publish a bundle with one agent, one skill and one MCP server; create a session on
  the profile; its `agent_started` names the bundle version, its first `llm_request`
  lists the `skill` tool and `mcp.<server>.*` tools, and its system prompt (visible in
  the fake provider's recorded request) lists the skill's name and description.
* The model calls `skill`; the log shows the call and the `SKILL.md` body as the
  result; `read_file skills:/<name>/checklist.md` succeeds; `write_file` to the same
  path is denied.
* Publish version 2 with the skill changed; a dormant session activated afterwards logs
  `config_upgraded from: 1, to: 2` and reads the new file; a session activated before
  the publish and still active keeps reading version 1.
* Publish a bundle naming an MCP host outside `allowedEgress`; the publish is refused
  with the host named. Publish one inside it on the kind cluster with Cilium absent; the
  worker's discovery lists its tools; delete the Secret; the profile shows
  `SecretMissing` and the pod stays up.
* `bundles.adoption` reports every pod current within one heartbeat of a publish.
* `troupe admin bundle publish stable ./bundle/` from a directory produces the same
  hash as the panel publishing the same content.

## Open questions

* **Skill authoring in the panel versus in git.** The directory form and the CLI make
  git the natural home; the panel upload is for the first skill and the quick fix. If
  the team prefers git-only, the Skills page becomes read-only with a "how to publish"
  panel, and step 7 shrinks.
* **Per-team MCP credentials.** Not in this plan, on purpose (DECISIONS 124 and the
  pod-per-profile model). If a real need appears, the shape that fits is a per-team
  Secret the operator mounts under a team-scoped env name and a session-time choice of
  which to send, which is a bigger change than it sounds and should be its own decision.
* **stdio MCP servers in the pod.** The client is HTTP-only. A stdio server would be a
  process under `reaper` inside the sandbox, and "what can it see" becomes the sandbox's
  answer. Reasonable later; not needed for the servers the studio uses today, which are
  all HTTP.
