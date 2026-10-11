---
number: 850
title: A delegation asks the person first only for an agent they opted into, through delegation.ask in a config file or delegation ask in the agent's definition, at the session's approval gate with five answers, and orchestrate is a primary nobody gets unless they choose it
date: 2026-10-11
status: accepted
issue: 554
paths:
  - apps/troupe_core/lib/troupe/tools/delegate.ex
  - apps/troupe_core/lib/troupe/session/approvals.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/agent/definition.ex
  - apps/troupe_core/lib/troupe/agent/validate.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/config/schema.ex
  - apps/troupe_core/lib/troupe/workflow.ex
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_core/priv/agents/orchestrate.md
  - apps/troupe_protocol/lib/troupe/protocol/agent_definition.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/lib/troupe/gateway/agents.ex
  - apps/troupe_core/test/troupe/tools/delegation_gate_test.exs
  - clients/gui/packages/client/src/transcript.ts
  - clients/gui/packages/client/src/session.ts
  - clients/gui/apps/desktop/src/views/Approval.tsx
  - clients/gui/apps/desktop/test/delegation-gate.test.tsx
symbols:
  - Troupe.Tools.Delegate.asks?/2
  - Troupe.Tools.Delegate.gate/4
  - Troupe.Tools.Delegate.edit/2
  - Troupe.Session.Approvals.decide/5
gist: "Delegation asks only for agents in delegation.ask or with delegation: ask; approval gate with 5 answers; auto_approve never answers it"
---

Issue #554, slices 2 and 3. The maintainer settled the rules (2026-10-11): delegation stays
automatic by default and asking is opt-in, per agent, on the configuration ladder; with it
on, a `delegate` to that agent pauses through the existing approval flow, showing the
agent, a link to its definition, the full brief, the tools and permissions the child will
hold, its budget share and its depth; the person runs it, edits the brief, switches the
agent, denies it with a word back, or says always for that agent this session; headless
follows `approvals: wait|deny`; the gate never edits a definition; the depth cap stays 3;
and `orchestrate` is a new primary profile, choosable, never the default and never
suggested until the bench has numbers. Decision 847's shapes are what the gate shows and
what it holds an edit to.

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
  quietly turn off the briefs a person asked to see. A repository that wants its agents
  to ask writes `delegation: ask` in its own definitions, which only ever narrows.
- **`auto_approve` does not answer the gate.** The person asked to see this agent's
  briefs, and a switch that says "do not ask me about tool calls" did not take that back,
  as it does not answer a call Decision 823 says must be asked. Turning `auto_approve` on
  mid-session leaves a delegation waiting. `allow_session` does answer it, scoped to the
  agent: "always for `general`" lets `general` run unasked for the session, not every
  agent; it is remembered in the log, so it holds after a restart, and under
  `managed_permission_rules_only` it is a plain allow, as for any tool.
- **It is the approval flow, not a new one.** The delegate call waits in a task under the
  agent, as an asking tool's call does, so the agent collects its other calls meanwhile
  and a cancel ends the wait with the task. The request is `approval_requested` with
  `tool: delegate` and what the gate shows under `delegation`: the agent; `definition`
  (`name`, `layer`, `path`, `description`), which `agents.get` opens; the brief's parts;
  `tools`, each with the permission the child's definition gives it; `budget_share`;
  `depth` (the child's) and `max_depth`; and `agents`, the subagents it could go to
  instead. There is no timer on the wait, as a child has none. A session that sleeps with
  one open asks it again when it wakes, and an answer given meanwhile is handed over. A
  client that knows none of this sees an approval for `delegate` with its arguments and
  answers allow, deny or allow_session, which run it, deny it and let that agent through.
- **The answer carries more than a word.** `approval.respond` takes `agent` (one of the
  subagents the request offered: the same brief goes there), `brief` (the parts the person
  changed, laid over the brief and held to its shape by `Troupe.Tools.Delegate.edit/2`: a
  part sent blank, or a key that is no part, is refused naming it) and `reason` (a word
  back, only with `deny`). A wrong one is `invalid_params` with a sentence, and the request
  waits on: the gate is checked synchronously, where a plain word is still the cast it
  was. `approval_decided` names the `agent` it went to, the `brief` and which parts were
  `edited`, and the `reason`. The root is told what changed before the child's report
  (`[The person sent it to explore rather than general and edited its constraints before it
  ran.]`), and a denial is the call's answer: `The person denied this delegation to general
  and said: ...`.
- **Headless.** With `approvals: deny` the gate is denied at once, as any request with
  nobody to ask; the TUI's headless run denies what asks, as it always has, and its line
  says this one asks because of `delegation.ask` and that `--auto-approve` does not answer
  it.
- **The clients.** The TUI's approval box and the desktop app's approval panel show the
  whole thing and take all five answers (TUI Decision 157 for the keys). The desktop app's
  panel links the definition to the agents manager (#503) where there is one, on a laptop,
  and shows where the file is otherwise; neither edits it. `agents.get` says `delegation`,
  and `agents.validate` knows the key.
- **`orchestrate`.** A built-in primary beside `build`, choosable wherever primaries are
  listed (command mode's chooser and both agents managers list `agents.list`'s primaries),
  never `default_agent` and offered by nothing. It reads to brief, delegates to execute
  (independent parts at once, changes through `implementer` or `general`, investigation
  through `explore`), and verifies from the finish or through a `reviewer` briefed with the
  implementer's finish; it cannot write, edit or run a command. Two profiles rather than
  `workflow` with a free plan, as #554's comment weighed: `workflow` runs a repository's
  declared step list and its instruction is built around it, `orchestrate` is the same
  contract with no list, and the two share the brief, the finish and this gate.
  `Troupe.Workflow`'s rules now say a step's prompt is a brief in its parts and its result
  a finish in parts, instead of "every delegate prompt must stand alone" and "a finish
  summary is all you get back". No model is set for it: which model it wants is what the
  bench (#554 slice 4) is for.
- **The bench.** Nothing `build` is sent changed: the gate is in the harness and the
  definitions, `orchestrate` is a primary and so not in `delegate`'s list of subagents,
  and the workflow's rules are the `workflow` agent's prompt. The tool definitions stay at
  13,336 of 13,500 bytes and the budgets are unchanged.
- **Proof:** `Troupe.Tools.DelegationGateTest` (its first test failed on the chunk's tip,
  `f74b3c6`: a `delegate` to `general` with `delegation_ask: ["general"]` started its child
  at once): the gate's contents; nothing asked with the opt-in off; run, an edited brief
  given to the child, an edit refused naming the part and the gate waiting on, a switch,
  a denial's word as the call's answer, `allow_session` holding for a second and third
  delegation and after a restart, `approvals: deny`, a bundle's `delegation: ask` on a pod,
  a cancel, and a delegation still asking across a stop. `Troupe.Gateway.DaemonTest` over
  the socket, `Troupe.Agent.DefinitionTest` for the key and `orchestrate`,
  `Troupe.WorkflowTest` for the rules; the desktop app's `delegation-gate.test.tsx` and the
  client's fold.
