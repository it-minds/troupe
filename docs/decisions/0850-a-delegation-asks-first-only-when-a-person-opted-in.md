---
number: 850
title: A delegation asks the person first only for an agent they opted into, through delegation.ask in a config file or delegation ask in the agent's definition, at the session's approval gate with five answers, and orchestrate is a primary nobody gets unless they choose it
date: 2026-10-11
status: accepted
issue: 554
paths:
  - apps/troupe_core/lib/troupe/tools/delegate.ex
  - apps/troupe_core/lib/troupe/session/approvals.ex
  - apps/troupe_core/lib/troupe/agent/definition.ex
  - apps/troupe_core/lib/troupe/agent/validate.ex
  - apps/troupe_protocol/lib/troupe/protocol/agent_definition.ex
symbols:
  - Troupe.Tools.Delegate.asks?/2
  - Troupe.Tools.Delegate.gate/4
  - Troupe.Tools.Delegate.edit/2
  - Troupe.Session.Approvals.decide/5
gist: "Delegation asks only for agents in delegation.ask or with delegation: ask; approval gate with 5 answers; auto_approve never answers it"
---

- **The opt-in is both a config key and a definition key, and either is enough.**
  `delegation.ask: [general, implementer]` in a `config.yaml` is the person's: it names
  built-ins without copying their definitions, it is on the ladder every other setting is
  (user file, a trusted project's files, `config.local.yaml`, the command line), and it is
  in `mix troupe.config.schema`, so `troupe config --explain delegation.ask` says which
  file set it. `delegation: ask` in an agent's frontmatter is the definition's: it is what
  a pod's session follows, because a pod has no config file of its own and its profile's
  configuration is its bundle, whose agents carry the key; it is also how a repository
  makes its own agents ask. Not one or the other: a config key alone would leave a pod no
  way to ask short of new plane terms, and a definition key alone would have a person copy
  `general.md` whole to see its briefs. The two are a union and neither can take back the
  other: asking is what someone opted into.
- **`delegation` is a trusted key.** A project's `.troupe/config.yaml` sets it only in a
  trusted workspace and a pod never reads it from a repository, as `approvals` and
  `auto_approve`: it changes approvals, and a repository's file replacing the list could
  quietly turn off the briefs a person asked to see. A repository that wants its agents to
  ask writes `delegation: ask` in its own definitions, which only ever narrows.
- **`auto_approve` does not answer the gate.** The person asked to see this agent's
  briefs, and a switch that says "do not ask me about tool calls" did not take that back,
  as it does not answer a call Decision 823 says must be asked. Turning `auto_approve` on
  mid-session leaves a delegation waiting. `allow_session` does answer it, scoped to the
  agent: "always for `general`" lets `general` run unasked for the session, not every
  agent; it is remembered in the log, so it holds after a restart, and under
  `managed_permission_rules_only` it is a plain allow, as for any tool.
- **It is the approval flow, not a new one.** The delegate call waits in a task under the
  agent, as an asking tool's call does, so the agent collects its other calls meanwhile
  and a cancel ends the wait with the task.
- **Headless.** With `approvals: deny` the gate is denied at once, as any request with
  nobody to ask; the TUI's headless run denies what asks, as it always has, and its line
  says this one asks because of `delegation.ask` and that `--auto-approve` does not answer
  it.
- **`orchestrate`.** A built-in primary beside `build`, choosable wherever primaries are
  listed (command mode's chooser and both agents managers list `agents.list`'s primaries),
  never `default_agent` and offered by nothing. Two profiles rather than `workflow` with a
  free plan, as #554's comment weighed: `workflow` runs a repository's declared step list
  and its instruction is built around it, `orchestrate` is the same contract with no list,
  and the two share the brief, the finish and this gate.
