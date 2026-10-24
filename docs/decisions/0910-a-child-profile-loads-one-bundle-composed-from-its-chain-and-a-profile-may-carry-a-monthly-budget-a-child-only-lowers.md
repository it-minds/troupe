---
number: 910
title: "A profile that extends one on another channel loads one bundle the plane composes from the channels of its chain, added by name with override: true in the document to replace, published as a version of the plane's own profile:<name> channel only when it changes; and a profile may carry a monthly budget, a rung after the person's and before the team's, which a child can only lower and is refused raising"
date: 2026-10-16
status: accepted
issue: 655
paths:
  - apps/troupe_plane/lib/troupe/plane/bundles/effective.ex
  - apps/troupe_plane/lib/troupe/plane/bundles.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/extends.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/profile.ex
  - apps/troupe_plane/lib/troupe/plane/reach.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/admin/api.ex
  - apps/troupe_plane/lib/troupe/plane/budget.ex
  - apps/troupe_plane/lib/troupe/plane/profile_budget.ex
  - apps/troupe_plane/lib/troupe/plane/ledger.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/drain.ex
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - apps/troupe_plane/priv/repo/migrations/20261016000910_profile_budget.exs
  - apps/troupe_plane/test/troupe/plane/effective_bundle_test.exs
  - apps/troupe_plane/test/troupe/plane/profile_budget_test.exs
  - apps/troupe_plane/test/troupe/plane/channel_servers_test.exs
  - apps/troupe_protocol/lib/troupe/protocol/bundle.ex
  - apps/troupe_worker/test/troupe/worker/bundles_test.exs
  - clients/gui/apps/console/src/views/Profiles.tsx
  - clients/gui/apps/console/test/profiles.test.tsx
  - clients/gui/packages/client/src/admin.ts
  - clients/gui/packages/client/src/index.ts
  - clients/gui/packages/client/test/support/admin.ts
  - clients/gui/packages/client/test/support/extends.ts
  - docs/admin/profiles-and-policy.md
  - docs/admin/bundles-and-triggers.md
  - docs/admin/profile-options.md
symbols:
  - Troupe.Plane.Bundles.Effective
  - Troupe.Plane.Bundles.publish_effective/2
  - Troupe.Plane.Bundles.project_mcp_servers/3
  - Troupe.Plane.Fleet.Extends.refresh/2
  - Troupe.Plane.Fleet.Extends.own_servers/1
  - Troupe.Plane.ProfileBudget
  - Troupe.Plane.Budget.reserve/5
gist: "child's bundle = chain's channels composed, override in the document; one hash on profile:<name>; profile budget monthly, child only lowers"
---

#655 slices 2 and 3, on top of Decision 908 (slice 1). Extends in a repository's manifest
(slice 4) is not here.

## Slice 2: one bundle in effect

### What composes

A profile follows a channel; one that extends another and names none follows its parent's
(Decision 908). Each profile in a chain therefore has a channel in effect, and the chain's
**layers** are those channels once each, from the profile that extends nothing down, each
under the first profile that follows it. A chain on one channel (a child on its parent's
channel, or naming it) has that channel's bundle as it is, and nothing changes for it. A
chain on more than one has the bundle `Troupe.Plane.Bundles.Effective` composes:

| Kind | Rule |
| --- | --- |
| agents, skills, MCP servers, ACP agents | **added** by name, layer by layer. An entry with a name a layer above already has replaces it only where it says `"override": true`; an agent may say it in its frontmatter, as it says it to replace a built-in. Otherwise the one above is kept and the clash is reported in `effective.bundle.problems` |
| an identical entry | kept once, silently |
| `override` | a boolean on any entry in any document (`Troupe.Protocol.Bundle` refuses anything else), and stripped from the composed document, which replaces nothing |

The decision the issue asks for, "the worker still loads one document": the composed
document is published **as a version of a channel**, `profile:<name>`, and the profile's row
follows that channel (`config_bundle_channel`). Everything that already follows a profile's
channel then works unchanged: `config.updated` names the channel, version and hash; a
session pins `bundle_version`; `bundle.fetch` by hash finds it; adoption compares hashes;
the offering and `agent_for/2` read it. No worker change, no protocol change beyond the
flag, and no new table.

Choices made here:

- **The flag lives in the child's channel's document**, not in the profile. Decision 908
  had `override: true` on a server in the child's `spec.mcpServers`, which the projection
  rewrote from the channel at the next publish, losing it (E36's note). In the document
  it is published with the entry and is there at every publish after.
- **A version is published only when the composition's hash differs** from the profile
  channel's current version. A publish to a channel in the chain that changes nothing in
  effect makes no version and pushes nothing; republishing the same document is not
  churn on every child.
- **Composition is triggered** by a publish or retire on any channel in a chain (each
  composed profile with that channel among its layers is written again, parents first,
  and its bundle published), and by `admin.profile.put` of the profile or of anything
  above it (Decision 908's rewrite of every profile below). The push follows the
  triggering publish's `announce` option.
- **The resource's `mcpServers` for a composed profile are the composed bundle's**, each
  attributed to the profile whose channel gave it, so `spec.mcpServers`, the reach check
  and the identity check read what the pods load. Where nothing in the chain is published
  yet they are what the profiles wrote (Decision 908's merge), as a root profile's are
  before its channel's first publish.
- **`profile:` is the plane's prefix.** `admin.bundle.publish` and `admin.bundle.retire` to
  such a channel are refused with a sentence, and so is a profile naming one as its
  `configBundleChannel`: a version written there by hand would be undone by the next
  publish anywhere in the chain. `Reach.bundle/2` and a publish preview's losers count a
  composed profile among a channel's followers (`Bundles.followers/1`), since its pods load
  what that channel publishes.
- **The summary's `channel`** stays the channel the profile names or inherits, which is
  what an admin thinks of; `bundle_channel` is the one its pods load.
- A profile that stops extending follows its own channel again (the column is set from its
  spec), keeping its servers in effect until that channel's next publish.

Considered and not done: a per-profile table of composed documents (a second index for
the worker to fetch from, and a second notion of version beside the channel's), and
composing on the worker (two fetches and two hashes per pod, and the worker would need the
chain, which Decision 908 keeps on the plane).

### A profile's own servers are a layer, and a publish keeps them

C37's review of #722 found that a publish replaced a profile's whole `spec.mcpServers` with
its channel's, so the servers an administrator wrote in the editor went at the next
publish. The servers a profile wrote itself are therefore a layer of their own, after its
channel's, composed by the same rule (added by name, replacing a bundle server only with
`override: true` on the profile's entry, the clash otherwise reported, as Decision 908 said
it for a child's servers):

- They are kept apart: in `own.spec.mcpServers` for a profile that extends another, as
  before, and in a new column, `own_servers`, for one that extends nothing. A row from
  before the column has as its own the spec's servers its channel's bundle does not name,
  and its first refresh keeps them in the column.
- **A publish composes again rather than overwriting.** `Bundles.project_mcp_servers/3`
  refreshes each profile (`Extends.refresh/2`): a root's servers and channel only, the rest
  of its row as it is; a child's whole resolution.
- A profile with servers of its own has a composed bundle and a `profile:<name>` channel
  even with one channel in its chain, so its pods load its own servers with the bundle's and
  the resource and the bundle still agree. One that wrote none stays on its channel as it is.
- `admin.profile.get` answers a root's own servers in `spec`, as it answers a child's
  written ones, so an editor loads and sends back only those. A caller that sends the
  resource's whole list back sends the bundle's too: a put drops sent entries that equal a
  server the profile has from a bundle, which keeps Decision 912's tests (a profile moved
  onto a channel has that channel's servers, not the old one's) true by composition.
- This replaces Decision 912's `with_channel_servers/1`, which wrote the channel's servers
  into a put that created a profile or moved it: every put of a spec now resolves the
  profile's servers in effect, so a profile has its channel's servers from the write that
  puts it there, as 912 promised, and keeps its own.

A known edge, not new: a session pins a version number, not a channel, so a profile that
moves from its parent's channel to one of its own resolves its sessions' pins against the
new channel at their next activation, as a change of `configBundleChannel` already does.

## Slice 3: a profile's monthly budget

`budget_micros` on a profile (column, `admin.profile.put` field, console field), as the
maintainer decided on 2026-10-16: a **monthly** ceiling, the calendar month in UTC, on what
the sessions on the profile spend, whoever starts them and in whichever team.

- **A rung of the ladder** (`Troupe.Plane.Budget`), `Troupe.Plane.ProfileBudget`, shaped
  like `PersonBudget`: one actor per profile through `Singleton`, deciding and holding,
  the one reservation row written by the ladder once every rung agrees, a rung that
  refuses unwinding the ones before it (Decisions 465 to 469). A profile with no ceiling
  has no rung and is not listed, so it costs a session create one indexed lookup.
- **Order**: after the person's, before the team's. A profile is neither above nor below a
  team (a profile serves several teams, a team uses several profiles), and the person
  refused by the profile they chose can choose another, which is the nearer thing to act on.
- **What it counts**: charges through the session each names (`usage_records` joined to
  `sessions.profile`) since midnight UTC on the 1st, and open reservations the same way. No
  column on the ledger: the session carries its profile once for every charge, both tables
  index the join, and a charge without the profile cannot drift from it. A session erased
  takes its charges out of the sum, as out of every per-session view.
- **A child can only lower it**: `budget_micros` takes the narrow rule of Decision 908's
  table, the lower of the child's and the parent's in effect; and a child's own set above
  what it has from above is **refused** at `admin.profile.put` and preview with a sentence
  naming the parent and the most it may be. A parent lowered below a child's is not refused:
  the lower is in effect, and `set_by` and the effective view say whose it is. Each
  profile's sessions count against its own ceiling, not a pool shared with its parent: a
  standard's budget is what the standard's sessions may spend, and an extension gets at
  most the same number for its own.
- **Zero and absent are none** (Decision 49), stored as `nil`, so a zero is never the lower
  of two ceilings to a child.
- **Saying so**: `admin.budget.explain` takes `profile` and lists `scope: profile` with
  `profile`, `set_by`, spent, held and remaining; a refused session is `budget_exhausted`
  with `scope: profile`, `profile` and a reason naming the profile, at create, at a
  reactivation, and when a slice is trimmed to nothing at create. `admin.profile.get`
  answers `budget`.
- Not in a repository's manifest yet: the resource has no field for it, and this slot
  changes no CRD (#655 slice 4).

## Proof

On the chunk tip the new `effective_bundle_test.exs` failed five of six (a child on its own
channel had its own channel's bundle only, no clash was reported, nothing reached a child's
pods from its parent's channel, an `"override": "yes"` was published) and every one of
`profile_budget_test.exs`'s six failed (no field, no rung, no refusal). Now: a child's
composed document validates, hashes to its row's hash, carries both channels' agents,
skills and servers and is what the resource's `mcpServers` names; a clash keeps the parent's
until the child's channel says override, which survives that channel's next publish; a
publish to the parent's channel pushes the parent's bundle to its pods and the composed one
to the child's, and one to the child's channel pushes only to the child's; a republish that
changes nothing makes no version. A root profile's own server stays beside its channel's
through two publishes, its pods' bundle names both, a resent resource list does not make the
channel's servers its own, and its own `jira` replaces the channel's only with
`override: true`; Decision 912's `channel_servers_test.exs` passes as it was. The profile's rung refuses naming the profile with the
team under its ceiling, unwinds the team's slice, is released, counts the month's charges
through sessions, is absent at zero, refuses `session.create` with `scope: profile`, and is
named by `admin.budget.explain`; a child's budget is the parent's or its own lower one, a
parent lowered below it wins, and a higher one is refused. The worker loads a composed
document as any other; the protocol refuses a non-boolean `override`. The console's
`profiles.test.tsx` reads the composed bundle with each entry's profile and the clash, sets
dev's budget through preview and audit and sees it reach data-team, and shows data-team's
higher budget refused.
