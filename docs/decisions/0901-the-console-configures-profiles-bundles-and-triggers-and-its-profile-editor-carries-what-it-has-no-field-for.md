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
  - clients/gui/packages/client/src/admin.ts
  - clients/gui/scripts/fake-console.ts
gist: "Console profile editor sends only its paths over the loaded spec, never plane-written ones; team admins see what the plane answers; trigger put sends what moved"
---

#56 slice 3, on Decisions 886 and 892: the console's **Configure** area. Worker profiles,
configuration bundles and triggers are drawn, and the map no longer marks them as being in
the previous console.

## Worker profiles

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

## Configuration bundles

Publishing takes the document as the plane does, as JSON, prefilled with the current
version: validated (`admin.bundle.validate`, whose sentences are shown), then previewed with
the plane's diff and the teams that lose an entry they were allowed. A publish that takes
something from a team is typed by the channel's name; otherwise a plain confirm, since
history is append-only. A rollback is publishing an older version's content again, offered
on that version's page. Retiring is a plain confirm that says what the channel's current
version becomes. The structured editor the brief asks for (one per agent, skill and server,

## Triggers

 **A change sends only the fields that moved**: the plane keeps what a put on an existing
 trigger does not send, so the terms and the collaborators, which the form does not show,
 are untouched. The form offers the team's working service principals from

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
