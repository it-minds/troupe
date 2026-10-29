---
number: 970
title: "An agent of mode function is one the harness starts by name for its own job; no picker, delegation or session's agent offers it, the plane's built-in primaries are the shipped files' primaries, and a profile's agents rule still removes one"
date: 2026-10-29
status: accepted
paths:
  - apps/troupe_protocol/lib/troupe/protocol/agent_definition.ex
  - apps/troupe_protocol/lib/troupe/protocol/agent_check.ex
  - apps/troupe_protocol/lib/troupe/protocol/bundle.ex
  - apps/troupe_core/lib/troupe/agent/definition.ex
  - apps/troupe_core/lib/troupe/agent/definitions.ex
  - apps/troupe_core/lib/troupe/session.ex
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_core/priv/agents/answer.md
  - apps/troupe_core/priv/agents/quick.md
  - apps/troupe_core/priv/agents/ask.md
  - apps/troupe_core/priv/agents/librarian.md
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_plane/lib/troupe/plane/bundles.ex
  - apps/troupe_plane/lib/troupe/plane/profile_view.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/ui/profile_view.ex
  - clients/gui/packages/client/src/profile.ts
symbols:
  - Troupe.Agent.Definitions.functions/1
  - Troupe.Agent.Definitions.ruled_out?/2
  - Troupe.Protocol.AgentDefinition.function_refusal/2
  - Troupe.Plane.Bundles.builtin_primaries/0
  - Troupe.Plane.Bundles.builtin_functions/0
gist: "mode: function = the harness's own job (answer, quick, ask, librarian); out of every picker and delegate list, refused as a session's agent, started by name as a branch; built-in primaries read from the files; spec.agents still removes one"
---

Troupe ships agents it starts itself for one job: `answer` for an `AI?` comment and `quick`
for an `AI!` (the watcher, `Troupe.Watch.Branch`), `ask` for `/ask` across a session's
branches, and `librarian` for the project brief (the terminal client's `/memory refresh`
and its start, and the desktop app's `startLibrarian`, each a `session.create` with a
`parent`). Every one was `mode: primary`, so it was in every agent picker (the terminal's
Ctrl-N and Tab, the desktop app's switch and Agents page) and a person could start or
switch a session to the librarian, while the plane's `@builtin_primaries ~w(build plan)`
and so the pod left them all out of a session's set, which nothing wrote down. Defect D142
recorded that as unexplained. It was not a defect: it was this concept, unnamed.

This extends Decision 968, whose rule applies to every mode and so to this one, and
Decision 969, whose view gets a third list.

## Decision

**A third mode.** `mode: function` is parsed by `Troupe.Protocol.AgentDefinition` (so a
bundle's agent may declare it and the plane's publish check accepts it) and checked by
`AgentCheck`. `answer`, `quick`, `ask` and `librarian` ship as `mode: function`.
`orchestrate` stays `primary`: people pick it, `/orchestrate <prompt>` is documented on
[agents](../user/agents.md#workflows), and the live bench runs sessions on it.

**Out of every list a person or a model picks from.** `Definitions.primaries/1` and
`subagents/1` filter by mode, so a function agent is in neither: not in `agents.list`
without `subagents: true`, not in a picker, not in the delegate tool's list (`delegate` to
one is refused with a sentence of its own). `Definitions.functions/1` lists them;
`fetch/2` filters by no mode, so every start by name keeps working.

**Refused as a session's own agent, started as a branch.** `profile.switch` refuses one,
and so does the daemon's `session.create` without a `parent` and the plane's
`session.create` and `session.spawn`, all with one sentence,
`AgentDefinition.function_refusal/2`: "librarian is a function agent the harness runs for
the project brief's survey; it does not carry a session". A `session.create` with a
`parent` starts it, which is how `/ask`, `/quick` and the librarian have always started.
On a laptop `commands.list` lists the function agents beside the primaries, so `/ask` and
`/quick` remain commands; a pod starts no branches, so there they are none. The terminal's
branch commands read `agents.list` with `subagents: true` to find them.

**The plane's built-in primaries are the files'.** `Bundles.builtin_primaries/0` and
`builtin_functions/0` are read from the shipped files' modes at compile time with the
parser the pod uses, so the offering and a pod's `primaries/1` cannot disagree. This adds
`orchestrate` to every profile's offering, as a primary it always was; a profile that does
not want it denies it.

**The profile's rule still applies.** A function agent is narrowed by no grant (the set
names primaries) and removed by `spec.agents` like any agent. `Troupe.start_session/1`
now refuses an agent the definitions lack, `{:not_on_profile, name}` where the rule took it
(`Definitions.ruled_out?/2`), `{:unknown_agent, name}` otherwise, instead of the root
failing to start; a branch so refused writes one `config_note` (`key: agents`) in its
parent's log, not repeated while the log already says it. `profile.get` answers
`functions` (`[{name, description, from}]`), and a function agent appears in
`agents_not_here` only with `why: profile`; `admin.profile.agents` lists the built-in ones
with `mode: function`. The desktop app's and the console's Profiles pages and the
terminal's profile page show them under Agents as "What the harness may run here".

## Not chosen

- **Hiding them by a list of names**, as `@builtin_primaries` did. A list in the plane is
  a second statement of what the files say, and a bundle's or a person's own one-job agent
  had no way in.
- **A `hidden: true` flag beside `mode: primary`.** It would leave such an agent a primary
  that every check of `mode == :primary` treats as one (switching, the entitled set, the
  shell refusal), each needing to learn the flag; a mode is the one field all of them
  already read.
- **Refusing every `session.create` naming one.** The librarian and `/ask` are started
  that way, as a branch of the session they serve; the refusal is of a session of its own.
