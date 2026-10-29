---
number: 968
title: "A worker profile says which agents exist on it in spec.agents, built-ins included and in every mode; the plane applies it before any team's grant, a child profile can only narrow it, and the pod drops every definition it excludes, subagents too"
date: 2026-10-29
status: accepted
paths:
  - charts/troupe/crds/workerprofile.yaml
  - apps/troupe_protocol/lib/troupe/protocol/agent_rule.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_protocol/test/troupe/protocol/agent_rule_test.exs
  - apps/troupe_plane/lib/troupe/plane/gitops/profiles.ex
  - apps/troupe_plane/lib/troupe/plane/bundles.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/admin/api.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/profile.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/extends.ex
  - apps/troupe_plane/test/troupe/plane/profile_agents_rule_test.exs
  - apps/troupe_core/lib/troupe/agent/definitions.ex
  - apps/troupe_core/lib/troupe/session.ex
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_core/test/troupe/agent/agent_rule_test.exs
  - apps/troupe_worker/lib/troupe/worker/plane/commands.ex
  - apps/troupe_worker/test/troupe/worker/bundle_wins_test.exs
  - clients/gui/apps/console/src/views/Profiles.tsx
  - clients/gui/apps/console/src/views/ProfileAgents.tsx
  - clients/gui/packages/client/src/admin.ts
  - docs/admin/profile-options.md
symbols:
  - Troupe.Protocol.AgentRule
  - Troupe.Plane.Bundles.offering/3
  - Troupe.Agent.Definitions.load/2
gist: "spec.agents {allow, deny}: which agents exist on a profile, every mode; applied before grants, a child only narrows, the pod drops excluded subagents"
---

The person running a plane wanted a profile called, say, *base company info* to never offer
`build`, whatever any team's grant says, and the same for subagents it never needs. Until
now a profile offered its bundle's primaries plus every built-in primary the bundle did not
shadow (`Bundles.offering/2`), and the only narrowing was a team's grant: entitlement rows
resolved by `Entitlement.resolve/2`, carried to the pod as the entitlement set, and applied
there to primaries alone (`Definitions.load(entitled:)`), on purpose, so a bundle's own
delegation kept working for a team that had simply not listed a name it never names. That
left nothing a profile could say for itself, and nothing that reached a subagent.

This extends Decision 913 (a profile's rules are an enforced scope on its pods, read at
every activation; a child keeps its parent's and may only add) and Decision 826 (on a pod
the bundle's and the built-ins' names beat the disk's): the rule here is one more thing the
profile says about its pods, and it is about the agents that decision put in charge.

- **The field.** `spec.agents` on the `WorkerProfile`, beside `permissions`: `allow` and
  `deny`, each a list of agent names, built-ins and the bundle's alike, declared in the CRD
  as `permissions` is. `allow` present means only those names exist on the profile, in
  every mode; `deny` takes names away; deny over allow, as a grant's rows are read; absent
  is what every profile had before. `admin.profile.put` takes the same document and the
  row's changeset refuses a name in both lists, a name that is not one, or a field that is
  neither list, with a sentence; a manifest read in gitops mode goes through the same
  check. An unknown name is kept, since a bundle may gain it, and `admin.profile.agents`
  lists such names as `unmatched`.
- **One module reads it everywhere.** `Troupe.Protocol.AgentRule` is the reading: `parse/1`,
  `allows?/2`, `keep/2`, `compose/2`, `json/1`. The plane and the pod both use it, so the
  offering a person is shown and the definitions a session loads cannot disagree.
- **Before any grant.** `Bundles.offering/3` cuts the bundle's primaries and the built-in
  primaries by the profile's rule first, then the team's entitlement rows narrow what is
  left. So `session.create`'s `agent_for` refuses an excluded primary with its existing
  sentence and the list it could have had, `profiles.list` never shows it, and the
  entitlement set carried to the pod is already the primaries the rule leaves. A grant can
  only narrow what the profile offers; it cannot reach past it.
- **The pod needs the rule itself.** The set names primaries. For subagents the activation
  carries `agent_rule` beside the set (`{"allow": [...]?, "deny": [...]}`, `allow` left out
  where there is none, since the CRD types it as a list), read again at every activation
  like the per-tool rules, and left out where the profile says nothing. It rides on the
  session's bundle map, as the set does, so the one reader of the bundle applies it.
  `Definitions.load(agent_rule:)` applies it last, after the whole search order is merged
  and after `entitled`, to every mode: a subagent the rule excludes is not in the map, so
  the delegate tool's list, `fetch/2` and `primaries/1` never see it and no agent of another
  name reaches it by delegating. The moduledoc says why this one is applied to subagents
  where the set is not: the set is a team's narrowing of what the profile offers; the rule
  is the profile saying the agent does not exist on these pods, for anybody.
  `session_created` records `agent_rule` beside `entitlements`, an addition within schema
  version 1. A laptop session has no rule.
- **extends.** A child has its parent's rule as well as its own and can only narrow
  (`Extends`' `:agent_rule` field rule, `AgentRule.compose/2`): its `allow` is cut to the
  parent's where the parent has one (an empty cut stands, and a grandchild cannot widen it),
  its `deny` adds to the parent's, and a denied name leaves the `allow`, so the composed
  rule reads as a profile could have written it and passes the row's own check. The row
  holds the profile in effect, so `status.effective`, the harness and the export carry the
  composed rule without further work.
- **Where people see it.** `admin.profile.agents` marks each row `offered` by the rule in
  effect, leaves an excluded subagent out of every `delegate`, and answers `rule` and
  `unmatched`. The console's profile page shows one line ("Agents: all but build,
  implementer", or "only answer, ask"); its editor has no field for it and carries
  `spec.agents` through a save as loaded, under Decision 900's rule. No editing UI: the
  field is a list of names an admin writes once through the API or a manifest, and a form
  for it would be a third place to spell the rule's reading. `admin.profiles.export`
  writes it as any spec field. The TUI and the desktop app need nothing: they read the
  offering.

**Not chosen.** A per-team rule only, which exists already and cannot say what a profile
is for whoever uses it. A deny-only field, which would have made "only these three" a list
of everything else the bundle and Troupe ship, kept up to date by hand as agents are added.
Narrowing primaries alone, as the grant does, which would have left a subagent nobody
should have on these pods reachable by any primary that delegates.

**Proof.** `Troupe.Plane.ProfileAgentsRuleTest`: `allow` keeps only the named primaries of
the bundle and the built-ins, `deny` takes a built-in away and beats `allow`, a grant
narrows further and never widens, `session.create` refuses an excluded primary naming the
rest, the activation carries `agent_rule` beside the resolved set and no rule where the
profile has none, a child's rule is its parent's cut and added, a put refuses a name in
both lists, a gitops manifest's field reaches the row and the child's `status.effective`,
the export round-trips it, and `admin.profile.agents` marks what is offered and names the
unmatched. `Troupe.Protocol.AgentRuleTest` holds the reading. `Troupe.Agent.AgentRuleTest`
(core): `Definitions.load` with the rule drops a built-in primary and a subagent, the
delegate tool's list no longer names it, and the rule is applied after the entitled set.
`Troupe.Worker.BundleWinsTest`: an activation carrying the rule loads neither `plan` nor
`explore`, and `session_created` records it. The console's `profiles.test.tsx` shows the
line and keeps the field through `keptOf`.
