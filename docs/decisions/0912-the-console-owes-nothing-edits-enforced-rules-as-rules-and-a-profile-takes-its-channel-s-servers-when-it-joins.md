---
number: 912
title: "The console runs a trigger now and rotates a webhook trigger's key, so it owes the plane no method; it edits the organisation's enforced permission rules as rules, checked as typed by a reading of PermissionRule held to the module by shared cases; and a profile created on a channel, or moved onto one, carries that channel's MCP servers from that write"
date: 2026-10-16
status: accepted
issue: 722
paths:
  - clients/gui/apps/console/src/owed.ts
  - clients/gui/apps/console/src/views/Triggers.tsx
  - clients/gui/apps/console/src/views/Organisation.tsx
  - clients/gui/apps/console/src/views/PermissionRules.tsx
  - clients/gui/apps/console/test/coverage.test.ts
  - clients/gui/apps/console/test/triggers.test.tsx
  - clients/gui/apps/console/test/organisation.test.tsx
  - clients/gui/packages/client/src/rules.ts
  - clients/gui/packages/client/src/admin.ts
  - clients/gui/packages/client/test/rules.test.ts
  - clients/gui/packages/client/test/support/admin.ts
  - apps/troupe_protocol/test/support/permission_rules.json
  - apps/troupe_protocol/test/troupe/protocol/permission_rule_test.exs
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/test/troupe/plane/channel_servers_test.exs
  - docs/admin/console.md
symbols:
  - Troupe.Plane.Admin.profile_put/2
  - Troupe.Protocol.PermissionRule.parse/1
gist: "owed.ts is empty; rules edited as tool+pattern, checked by rules.ts held to PermissionRule's shared cases; a new or moved profile takes its channel's servers"
---

Chunk 37's slot C37: the console's last two owed methods, an editor for the organisation's
enforced permission rules, and #722. Three things a later change must not undo.

## The console owes the plane nothing

Decision 904 left `owed.ts` holding `admin.trigger.run` and `admin.trigger.key.rotate`, done
over the admin API until a trigger's page offered them. It offers both now, and `owed.ts` is
empty; `coverage.test.ts` says so (`OWED` is `[]` and every method the plane serves is called
from a screen). The file stays, as the place a method the plane adds before its screen is
drawn is listed.

- **Run now** is a plain confirm, as pausing one is (Decision 901), since it destroys and
  stops nothing: firing makes a run and spends the team's budget, which the preview says (the
  profile, the principal, the revision, that a run over the trigger's concurrency is
  skipped), but it changes nothing about the trigger. The answer's run is linked on Runs and
  review. It is offered only on a trigger that is on, since the plane refuses a paused one,
  and the page says so instead.
- **Rotate** is typed by the trigger's name, as Decision 904 types what destroys or stops
  something: what it destroys is the key every sender holds. The preview says first that the old key stops
  working the moment it is done, with no overlap (`Admin.trigger_key_rotate/3`'s reason), and
  that the new one is shown once. It is offered only on a webhook that names no repository:
  a schedule is fired by the plane and a GitHub repository by the App's signed deliveries, so
  a key minted on either is a second door nobody asked for. `Mint` where it has none.
- Both are offered on a `gitops` plane and to a team admin on their own team's triggers, as
  the plane allows (Decision 737: firing and the key are things done with a trigger, not what
  it is).

## Enforced rules are edited as rules

Decision 907 had the enforced-set editor write `permissions`, an object, as JSON text in the
one input it has per key, and named a proper editor as a follow-up. That is this, and it
replaces 907's "writes an object-typed key as JSON text" for the console. The enforced layer
on the plane stays the source of truth: the editor reads `client_enforced` and writes it
whole through `admin.setting.put`, every other key as it was stored; the generic form for
the other keys keeps `permissions` as stored when it saves.

A rule is edited as its two parts, the tool and the pattern, in a list per action (`deny`,
`ask`, `allow`), added, changed and removed in place, saved through the usual preview (each
rule added or removed in words, the diff per action that moved), confirm and audit. A key of
type `rules` gets this editor from the plane's `enforceable` list, as every other key gets its
field, so nothing here names `permissions`.

**Checked as typed, by the plane's reading.** `@troupe/client`'s `rules.ts` reads a rule as
`Troupe.Protocol.PermissionRule.parse/1` does and refuses it with the same sentence, at the
field it is about (the tool's name, or the rule as a whole), and Preview stays disabled until
every row reads. Not chosen: a validate method on the plane, which would be a round trip per
keystroke for a check that is a pure function of the text, and a method no other screen
needs. A second reading drifts unless something holds it, so **one list of cases**,
`apps/troupe_protocol/test/support/permission_rules.json`, is asserted by both
`permission_rule_test.exs` (against the module) and `rules.test.ts` (against the port), rule
by rule and sentence by sentence, with `check_set/1`'s order. A change to either reading
fails one of the two. The plane's own check on `admin.setting.put` is still the one that
counts.

What the editor sends is each rule as the plane reads it (`shell( git  push )` is sent as
`shell(git push)`, and the row says so as it is typed), the same rule once per list, and no
list that is empty; taking every rule away removes `permissions` from the set.

## A profile takes its channel's servers when it joins it (#722)

A profile's `spec.mcpServers` is the plane's projection of its channel's current bundle
(Decision 736), rewritten on every publish and retire. A profile created on a channel after
the channel's last publish, or moved onto one, carried no servers (or its old channel's) on
its resource until the next publish, while the reach and identity checks, which read the
bundle directly, said otherwise.

`Admin.profile_put/2` now writes the channel's servers into the spec it saves when the put
creates the profile or changes its channel, exactly as a publish would, before the profile
is resolved, checked and applied. So the resource, the row and the checks agree from that
write. Judgement calls:

- **A put that stays on its channel keeps what it sends**: the editor loads the projected
  servers and sends them back, and a publish rewrites them anyway.
- **A new profile on a channel with nothing published keeps the servers it was written with**,
  as it always did before the channel's first publish (the profile's own servers, Decision
  908's tests). A profile **moved** onto such a channel loses its old channel's servers, which
  were never its own.
- **A profile that extends another and names no channel of its own** has its servers from its
  parent, as before. One that names its own channel takes that channel's servers into what it
  wrote, as a publish to that channel does, and has its parent's added.

## Proof

On the chunk's tip, `channel_servers_test.exs` failed four of six (a profile created after a
publish, moved onto a channel, written again on its channel, and a child on its own channel
each had no servers or the wrong ones on the resource `FakeWorkerProfiles` was sent). Now all
pass, beside `extends_test.exs`, `bundles_test.exs`, `reach_test.exs` and
`provision_test.exs`. `permission_rule_test.exs` holds the module to the shared cases, and
`rules.test.ts` the port. The console's `triggers.test.tsx` runs a trigger behind its confirm
and finds the run on Runs, rotates a key typed by name after the warning and shows the new
one once, and offers neither where the plane would refuse; `organisation.test.tsx` reads,
adds, edits and removes rules with the plane's sentences at the field, keeps the rules when
another key changes, and lets a team admin read them only; `coverage.test.ts` holds the empty
`owed.ts`. In a browser against `pnpm console:fake`, as both roles, at 320 px.
