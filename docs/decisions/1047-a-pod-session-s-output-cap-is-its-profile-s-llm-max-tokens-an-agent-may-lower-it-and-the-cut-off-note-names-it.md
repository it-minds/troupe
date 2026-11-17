---
number: 1047
title: "A pod session's output cap is its profile's llm.maxTokens, carried as TROUPE_MAX_TOKENS and narrow-only along extends; the model's own limit still bounds it and the organisation's machine ceiling does not reach a pod; an agent's own max_tokens only lowers it; 8192 stays the default; the cut-off note names the cap in tokens"
date: 2026-11-17
status: accepted
issue: 1080
paths:
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/config/layers.ex
  - apps/troupe_protocol/lib/troupe/protocol/agent_definition.ex
  - apps/troupe_operator/lib/troupe/operator/resources.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/extends.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/profile.ex
  - charts/troupe/crds/workerprofile.yaml
  - clients/gui/apps/console/src/views/Profiles.tsx
gist: "llm.maxTokens -> TROUPE_MAX_TOKENS -> max_tokens; child only lowers it; catalog limit bounds it, no org ceiling on pods; agent max_tokens only lowers; default 8192; note names cap"
---

A pod's sessions asked every model call for 8192 output tokens, whatever the model allowed:
nothing on a `WorkerProfile` reached the session's `max_tokens`.

**Where it is set.** `spec.llm.maxTokens`, an optional integer of at least 1. The operator
gives the pods `TROUPE_MAX_TOKENS`, which the config's environment layer reads as
`max_tokens` (a value that is not a whole number refuses the configuration, naming the
variable). It is an `llm` field, so it needs `llm.endpoint` like the others, and a change
replaces the pods as a model change does. `admin.profile.put` refuses anything but a whole
number above 0. Along `extends` it narrows, as `max_sessions` does: the lower of the two
holds, and a child's higher number is kept as written, does nothing, and is said in the
preview and the effective view ("a profile cannot raise a limit of the profile it extends");
the same sentence now covers the `github` caps, which already narrowed silently.

**How it is bounded.** As before, a call asks for the lowest of the session's `max_tokens`,
the model's `max_output` from the catalog, and an organisation's enforced ceiling. The
ceiling never reaches a pod: it is a machine's (`client_enforced`), a pod reads no
organisation layer (Decision 869), and the profile is already the administrator's own word
for that pool; a second knob for the same people would only disagree with it.

**An agent's own.** An agent definition may say `max_tokens:`, which lowers the session's
for that agent's calls and never raises it, so a profile or a person sets how much any call
may write and a quick agent can ask for less. A report-writing agent gets more by its
profile allowing more. The summariser keeps its own 2,000.

**The default stays 8192.** Following the catalog where it says more would raise every
laptop's spend per call, unasked, and a reply cut at 8192 is already recovered; a profile
that writes long documents raises its own.

**The cut-off notes name the cap**: "...reached the output cap of 8,192 tokens...", the cap
the cut call asked for, so the second attempt can be sized to fit.

Not chosen: an agent's cap above the session's (it would let a bundle's file outspend what
the administrator set); a plane setting for every profile at once (the profile is the unit
an administrator sizes).

Undone, a pod is back at 8192 whatever its profile says, or a child profile outruns its
parent's limit unnoticed.
