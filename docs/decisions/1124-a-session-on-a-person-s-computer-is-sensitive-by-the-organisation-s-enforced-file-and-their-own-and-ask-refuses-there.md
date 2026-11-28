---
number: 1124
title: "A session on a person's own computer becomes sensitive by the rules of the organisation's enforced file and the person's own config.yaml, the person's only adding; the daemon refuses on its own side what it does for the session outside the gate; and sharing: ask refuses there as deny does"
date: 2026-11-28
status: accepted
issue: 1239
paths:
  - apps/troupe_core/lib/troupe/config/layers.ex
  - apps/troupe_core/lib/troupe/config/schema.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_gateway/lib/troupe/gateway/sensitive.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/lib/troupe/gateway/local_sources.ex
  - apps/troupe_gateway/lib/troupe/gateway/artifacts.ex
gist: "laptop sensitive = managed file's enforced.sensitive {marked_by, deny, sharing} + user config.yaml's, user adds only, sharing tightens only; never a project's, never defaults:, never a pod; daemon mirrors refusals (publish, proposals, offer/invite, mcp.call marks/refuses); ask refuses on a laptop"
---
Issue #1239, slice 3. Decision 1120 made a pod session sensitive by its worker profile's
`spec.sensitive`; a session on a person's computer has no profile, and until now nothing
there could mark one.
**The rules are two files'.** The organisation's managed file (Decision 869) may hold
`enforced.sensitive` with `marked_by`, `deny` and `sharing`, in the config file's spelling;
the person's own `config.yaml` may hold a `sensitive:` block that adds rules to both lists
and may tighten `sharing`, never loosen it (a looser word is ignored and warned about), as
a child profile along `extends` may. A project's file, an organisation's `defaults:` and a
pod read none of it; a pod's stays its profile's, given by the worker. `marked_by` with no
`deny` in either file refuses the configuration. This widens Decision 869's enforced list by
one key the managed file carries; the plane's organisation set does not carry it yet, since
its console would need a field for it, and `Organisation.keys()` is unchanged.
**The same gate, the same mark.** `Config.resolve` builds the configuration's `sensitive`
from them, each rule of the `:sensitive` layer with its `origin` (`enforced`, `user`) and
file, so a refusal says whose rule it is. The tree's holder keeps that configuration beside
the mark, and the daemon reads both through `Troupe.Tools.mark_sensitive/5` and
`sensitive_refusal/5`, never a copy of the rule.
**The daemon refuses on its own side** what it does for a sensitive session outside its
agents' gate: a publication where `deny` names `publish_artifact`, every proposal for a
team's or the organisation's memory, an offer for steering and an invitation into a private
session under `sharing: ask` or `deny`, and its own `mcp.call` for a session here, which
marks the session where `marked_by` names the call and is refused where `deny` does.
## Not chosen
- `ask` held for a team administrator, as on the plane: a laptop's session has no plane row
  for a request to wait on, and no administrator answers one; waiting forever says nothing.
- The plane's organisation set carrying it now: a console field and a check for a block.
- A project's file adding rules: whoever commits to a repository would set what marks a
  person's session, and a rule a person did not write is not theirs to have added.
## If undone
A session on a laptop that read what must not leave it publishes, proposes or is offered
from the same turn, with nothing between the read and the way out but static rules.
