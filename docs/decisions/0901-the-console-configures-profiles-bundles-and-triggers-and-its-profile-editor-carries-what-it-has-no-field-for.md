---
number: 901
title: "The console's Configure area draws worker profiles, configuration bundles and triggers; its profile editor writes only the paths it has fields for and carries the rest of the spec, each role is shown what the plane answers it, and every LiveView page stays until the last slice"
date: 2026-10-14
status: accepted
issue: 56
paths:
  - clients/gui/apps/console/src/views/Profiles.tsx
  - clients/gui/apps/console/src/views/Bundles.tsx
  - clients/gui/apps/console/src/views/Triggers.tsx
  - clients/gui/apps/console/src/views/bits.tsx
  - clients/gui/apps/console/src/nav.ts
  - clients/gui/apps/console/src/route.ts
  - clients/gui/apps/console/src/owed.ts
  - clients/gui/apps/console/test/profiles.test.tsx
  - clients/gui/apps/console/test/bundles.test.tsx
  - clients/gui/apps/console/test/triggers.test.tsx
  - clients/gui/packages/client/src/admin.ts
  - clients/gui/packages/client/test/support/admin.ts
  - clients/gui/scripts/fake-console.ts
  - docs/admin/console.md
gist: "Console profile editor sends only its paths over the loaded spec, never plane-written ones; team admins see what the plane answers; trigger put sends what moved"
---

#56 slice 3, on Decisions 886 and 892: the console's **Configure** area. Worker profiles,
configuration bundles and triggers are drawn, and the map no longer marks them as being in
the previous console. Integrations (the GitHub App), Identity, Policy and settings, and
Provisioners are slice 4's and later.

## Worker profiles

A list (each profile's state from its pods, its pods against what it asked for, its image,
size, channel and the teams granted it), a profile's page and an editor.

**The page reads every field.** The sections read the paths they know (the model, egress,
storage class, MCP servers with every setting a row has, the identities at MCP servers, the
GitHub permissions, the channel and the switches). Everything else in the spec is listed as
its dotted path and value under "Everything else in its spec", and what the plane writes into
the resource (`replicas`, `sessionsPerPod`, `resources`, `teams`, `image`, `storage.size`)
under "Written by the plane". A field the resource gains is therefore on the page the day it
exists, rather than when somebody adds a section for it.

**The editor follows Decision 900.** It writes the paths the LiveView editor writes
(`llm.endpoint`, `.provider`, `.model`, `.smallModel`, `.secretRef`, `egress.fqdns`,
`egress.gitHosts`, `storage`, `mcpServers`, `configBundleChannel`, `orgMount`,
`repositoryOverridesBundle`, `personalTools`) and nothing else. On load it keeps the spec
without those paths and without the plane-written ones; a save sends that with the form
merged over it key by key, and each MCP row the form shows merged over the row as loaded, so
`secretRef`, `credentialMode` and any other row field survive an edit to its URL. What it
carries is listed under the form. Two choices beyond Decision 900:

- **A blank "most sessions at once" is sent as `null`.** The LiveView editor drops a blank
  field, so it can set a ceiling and never take one away; a ceiling removed is a change.
- **The preview shows the plane's diff as far as the write sends it.** `admin.profile.preview`
  compares the profile as stored with the write as sent, so the name, which every write
  carries, and the stored row's `replicas` and `sessions_per_pod`, which no write sends,
  would read as changing when they do not. The console drops the lines whose top-level field
  the write does not send. A spec path the plane writes that a stored spec held (a profile
  read back from the cluster) still shows as going, with a line saying the plane writes it
  again.

**The `llm` rule (Decision 894) is said at the endpoint field before anything is sent**: any
of `provider`, `model`, `smallModel`, `secretRef` or `prices` without `llm.endpoint` marks
the field invalid with the plane's meaning and disables Preview. Prices count although the
form has no field for them: they are carried from the loaded spec.

Creating is the same editor with a name that is not a profile's already. Deleting is typed by
the profile's name, after the warning that every team granted it loses it and its sessions turn
read-only. Each write shows the audit's diff (`profile.put` answers it; `profile.delete` is
read back, as Decision 892 does).

The provider is a text field and the size class offers standard and heavy: the admin API has
no method that lists the plane's provider types or size classes, which the LiveView editor
reads from `Admin` directly. A method for each is a follow-up, so the console can offer the
protocol's one list as Decision 894 asks.

## Configuration bundles

The channels are the profiles' channels and stable, each with its current version, what it
carries and who follows it; another channel opens by name. A channel lists its versions
newest first; a version reads its agents, skills (with their files), MCP servers (with the
Secret each credential needs), which profiles use it with the pods that report it and those
behind, and the plane's diff from the version before (`admin.bundle.preview` with `from`).

Publishing takes the document as the plane does, as JSON, prefilled with the current
version: validated (`admin.bundle.validate`, whose sentences are shown), then previewed with
the plane's diff and the teams that lose an entry they were allowed. A publish that takes
something from a team is typed by the channel's name; otherwise a plain confirm, since
history is append-only. A rollback is publishing an older version's content again, offered
on that version's page. Retiring is a plain confirm that says what the channel's current
version becomes. The structured editor the brief asks for (one per agent, skill and server,
with an edit-source escape hatch) is #594's console half and not this slice.

## Triggers

A list per team (a platform admin picks the team, a team admin sees theirs), a trigger's page
with every field the plane keeps and every revision with the document it froze, and a form
for making and changing one. **A change sends only the fields that moved**: the plane keeps
what a put on an existing trigger does not send, so the terms and the collaborators, which
the form does not show, are untouched. Pausing and resuming are plain confirms; deleting is
typed by its name. The form offers the team's working service principals from
`admin.principals.list`, which moves out of Identity's owed methods. Running a trigger by hand
and minting its key stay owed, for slice 4, and a trigger's page links to the previous
console for both.

## Gitops

On a plane in `gitops` mode, profiles and triggers are shown under a "Held in a repository"
banner with the repository, the generation read and what the last pass said (refused with
its reasons, missing), and nothing offers a write, as the plane refuses one. Deleting is
offered only for a row the cluster has no resource for, which the plane still deletes.
Bundles are not repository-held and are unchanged.

## What each role is shown

The area shows each role what the plane answers it and offers nothing it would refuse. A
team admin sees Worker profiles as the profiles their teams are granted (`admin.profiles.list`),
with no page or editor (`admin.profile.get` is a platform admin's); Configuration bundles to
read, without publish or retire; and Triggers for their own teams, with every write the plane
allows them.

## `/admin` stays whole

#56 left open whether a slice may remove a LiveView page once the console covers it. It may
not: every page stays until the last slice and the break-glass decision, so the way in on the
day the console cannot be used still reaches everything.

## Proof

On the chunk's tip the map marked all three areas as in the previous console and the shell
test held Worker profiles to the "Not in this console yet" page. `apps/console/test`:
`profiles.test.tsx` (the editor keeps `mcpIdentities`, `github`, `llm.prices`, a server's
`secretRef` and `credentialMode` and a field the console does not know, and drops
`sessionsPerPod`; the `llm` rule at the field with no call made; create and typed delete;
gitops locked and the missing row's delete), `bundles.test.tsx` and `triggers.test.tsx`
against the fake plane, whose administrative half now follows `Troupe.Plane.Admin` for
these methods, their refusals, the gitops lock and the audit. `coverage.test.ts` holds the
shorter `owed.ts`. In a browser against `pnpm console:fake` (`GITOPS=1` for the lock), as a
platform admin and a team admin, light and dark, and at 320 px with no sideways scroll.
