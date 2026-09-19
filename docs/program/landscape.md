# The landscape, September 2026

The competitive read [`../RELEASE.md`](../RELEASE.md) folds in. Seventeen platforms that run
agents somewhere other than a terminal, on the six dimensions that matter to Troupe.

A rendered version with the full matrix is published at
<https://claude.ai/artifact/D18ho1CdkwTzwcW2KaGrW7>. This file is the durable copy of the
conclusions.

OpenWork is treated as known context — `../../troupe-remote/docs/plans/stage-6.md` is the
review of it and is not re-derived here.

---

## Where each platform puts its weight

| platform | class | strongest | absent |
| --- | --- | --- | --- |
| **Claude Cowork** | knowledge work | parallel task queue; cloud-run scheduled tasks; group spend limits with most-restrictive precedence; curated plugin marketplace | no session sharing at all; connectors enabled org-wide with **no per-group control** |
| **Cursor** | control surface | unified Agents Window across every surface; **per-environment egress and secrets**; environment audit log with admin-only rollback; Automations across six event sources | sharing is still a PR |
| **Zed** | control surface | **ACP** — sessions, streaming, permission-gated tools, client-provided fs/terminal; worktree picker; terminal threads | no remote, no governance (explicitly declined) |
| **Conductor** | control surface | **Multiplayer (Sept 2026)** — share link, presence, followers, joint prompting; Cloud microVMs with deps pre-installed | governance beyond org membership |
| **Warp (Oz)** | control surface | **one trigger abstraction, six sources**; org-wide autonomy levels; per-team billing + individual credit caps | session privacy model |
| **Nimbalyst** | control surface | automations as markdown files with frontmatter schedules; agents scheduling their own wake-up; iOS→desktop | single user; no governance |
| **Orca** | control surface | **forked sessions**; remote runtime with port forwarding; idle-agent dashboard | single user; no governance |
| **Emdash** | control surface | **remote tasks where your own script provisions** — VM, k8s pod, container, internal platform; local-first SQLite | governance is paid-tier only |
| **Superset** | control surface | **an MCP server exposing the orchestrator**; Relay to any machine you own; automations leaving a live workspace | thin governance |
| **LangGraph Platform** | framework | cron and webhooks as **server primitives**; durable execution; enterprise workspaces | no session client |
| **CrewAI AMP** | framework | webhook streaming of execution events; deploy to private VPC / on-prem | no session client |
| **MS Agent Framework** | framework + gov | **Entra Agent ID** — sponsor attribute, subject/actor delegated tokens; superstep checkpointing | no session client |
| **Bedrock AgentCore** | framework + gov | **microVM per session**, sanitized at end; Memory FGAC via Cedar at the gateway, not in agent code | no trigger product |
| **Devin** | governance | **session visibility as an RBAC permission**; 15-second machine snapshots; `/v3/enterprise/audit-logs` | proprietary throughout |
| **Augment Cosmos** | governance | shared virtual filesystem as agent memory; runs in your environment or theirs | killed its IDE extension June 2026 |
| **Copilot / Agent HQ** | governance | mission control with mid-run steering; sandboxed Actions behind a firewall; org-published custom agents | the PR *is* the sharing model |

### Three conclusions

1. **Nobody has all six.** Control surfaces own local UX and have no governance; enterprise
   platforms own governance and ship no session client; frameworks own triggers and
   durability and have no opinion about a human watching. Troupe holding all three is
   uncontested — and is why the build is large.
2. **Sharing is still a pull request.** Fifteen of seventeen hand over a PR or a Slack
   thread. Conductor shipped the exception in September 2026.
3. **The entitlement design is ahead, not behind.** Cowork's connectors have no per-group
   control and its own security writeups name it. `stage-6.md` §2's child table — absence
   means everything, deny wins — is a better answer than the market leader ships. The
   weakness is scope, not mechanism.

---

## The twelve taken, and where they land

| # | feature | source | lands in |
| --- | --- | --- | --- |
| 1 | ACP on the loopback socket | Zed, JetBrains, 25+ agents | `RELEASE.md` W5a |
| 2 | One trigger object, six sources, content-addressed | Warp Oz; CrewAI; LangGraph | W2a |
| 3 | Subject + actor, and a named sponsor | Entra Agent ID; Devin `create_as_user_id` | W2b |
| 4 | Fork a session at a sequence number | Orca; Zed threads | W3a |
| 5 | Share link with a grade, presence, followers | Conductor Multiplayer | W3b, W3c |
| 6 | Per-person caps inside a team budget | Cowork; Warp | W2c |
| 7 | "Scheduling implies a worker" as a stated rule | Cowork | `control-panel.md` |
| 8 | Managed-scope settings, deny wins, MCP allowlist | Claude Code; Warp; Devin | W2d |
| 9 | Warm workspace snapshot named by bundle hash | Cursor Builds; Devin; Conductor | W4b |
| 10 | Config audit + admin-only rollback | Cursor; Devin | `control-panel.md` |
| 11 | Worker provisioner interface (SSH host as worker) | Emdash; Superset; Orca | W4a |
| 12 | MCP server exposing the orchestrator | Superset; AgentCore | W2e |

### What they do to existing decisions

| | verdict |
| --- | --- |
| 2, 3, 8, 9, 10 | **validate** stage 6 parts 2–4 and the admin surface, and extend them |
| 6 | **answers** stage 6's deferral of per-person entitlements, for budgets only |
| 5 | **contradicts** stage 6's "no push channel to harness clients" — revised narrowly, presence only |
| 11 | **contradicts an assumption** never argued: that a worker is a pod |
| 1, 4, 7, 12 | **new** — outside the OpenWork review's scope entirely |

---

## Sources

Vendor documentation and coverage, read September 2026. Full list in the published artifact;
the load-bearing ones:

- Zed — [parallel agents](https://zed.dev/docs/ai/parallel-agents), [external agents and ACP](https://zed.dev/docs/ai/external-agents)
- Warp Oz — [triggers](https://docs.warp.dev/agent-platform/cloud-agents/triggers), [admin panel](https://docs.warp.dev/enterprise/team-management/admin-panel/)
- Cursor — [cloud agents](https://cursor.com/docs/cloud-agent), [builds](https://cursor.com/docs/cloud-agent/builds), [automations](https://cursor.com/docs/cloud-agent/automations)
- Conductor — [multiplayer](https://www.conductor.build/docs/cloud/collaboration)
- Emdash — [remote tasks](https://emdash.com/docs/remote-development/remote-tasks)
- Superset — [MCP server](https://docs.superset.sh/mcp-server), [remote workspaces](https://docs.superset.sh/remote-workspaces)
- Cowork — [scheduled tasks](https://support.claude.com/en/articles/13854387-schedule-recurring-tasks-in-claude-cowork), [enterprise admin guide](https://claude.com/resources/tutorials/claude-cowork-enterprise-administrator-guide)
- AgentCore — [isolated sessions](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-sessions.html), [Memory FGAC](https://aws.amazon.com/about-aws/whats-new/2026/08/agentcorememory-fine-grained-access-control/)
- Devin — [enterprise quickstart](https://docs.devin.ai/api-reference/getting-started/enterprise-quickstart)
- LangGraph — [webhook loopback advisory](https://github.com/langchain-ai/helm/security/advisories/GHSA-2c9q-c2q9-qgqv)
