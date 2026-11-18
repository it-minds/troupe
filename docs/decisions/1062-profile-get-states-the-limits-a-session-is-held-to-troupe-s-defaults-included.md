---
number: 1062
title: "profile.get states the limits a session there is held to, Troupe's defaults included, from one protocol module the harness reads too; the desktop page says them in sentences and lists the harness's tools"
date: 2026-11-19
status: accepted
issue: 1121
paths:
  - apps/troupe_protocol/lib/troupe/protocol/allowance.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/budget.ex
  - apps/troupe_plane/lib/troupe/plane/profile_view.ex
  - apps/troupe_plane/lib/troupe/plane/github/policy.ex
  - clients/gui/packages/client/src/profile.ts
  - clients/gui/apps/desktop/src/views/Profiles.tsx
symbols:
  - Troupe.Protocol.Allowance
  - Troupe.Plane.GitHub.Policy.caps/2
gist: "profile.get adds limits.max_tokens/session/idle_seconds/budgets.team_period, agents' own max_turns/max_tokens (lowered), github caps, harness_tools [{name, refused}], personal_tools, memory_proposals; defaults live in Troupe.Protocol.Allowance"
---

Issue #1121. `profile.get` said a profile's room and budgets, not what a session there is
held to. This extends Decision 969 (the answer is the plane's statement of what it
enforces) to the limits, and narrows Decision 1060 on two points. Decision 1047 stands: an
agent's `max_tokens` only lowers the profile's.

**Where the numbers live.** The harness's defaults (8192 output tokens a call, 40 model
calls, 2,000,000 input and 400,000 output tokens, 30 minutes of working time, delegation 3
deep) are `Troupe.Protocol.Allowance`. `Troupe.Config`, its schema and `Troupe.Budget` take
their defaults from it, and core's test holds them equal, so the plane's statement and the
harness's behaviour are one number. No value changed.

**What the answer adds.** `limits.max_tokens` (the profile's `llm.maxTokens` in effect, or
8192); `limits.session`, Troupe's allowance, since a pod reads no organisation layer and a
profile sets none of it; each agent's own `max_turns` and `max_tokens` where its definition
sets them, said as the pod holds it, the lower of its own and the session's;
`limits.idle_seconds` and `limits.budgets.team_period`, the team's as resolved, `null`
without a team; `github`, the permissions and the fix loop's caps where the profile has
`spec.github` (the lower of the profile's and the team's, `GitHub.Policy.caps/2`);
`harness_tools`, the agent check's list, a tool refused where a pattern-less `deny` takes
it; `personal_tools`; `memory_proposals`, the setting and the profile together. Nothing is
removed; the method's parameters are unchanged.

**The page.** The rail says the limits a sentence each, numbers through `words.ts`, under
"An agent may set fewer." Troupe's card lists the harness's tools with the refused ones
struck through, which replaces Decision 1060's "names only what the rules turn off". The
banner says the list is whole ("Nothing but the tools above...") only where
`personal_tools` is `forbid`, shell and web fetch are both refused and the profile gives no
GitHub tools; otherwise it keeps 1060's words. A plane before these fields gets 1060's page.

Not chosen: the plane depending on `troupe_core` for the defaults (a plane would load the
harness); a list of the harness's tools written in the client (a second source); an
agent's raw `max_turns` above the session's (a number the pod never honours).

Undone, the page goes back to saying nothing of what holds a session, or the plane states
a default the harness no longer keeps.
