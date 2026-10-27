---
number: 953
title: "An artifact may be a team's, which its members read and its admins may take down, or private, its owner's alone and the default, which only a platform admin may still take down; every row of artifact.list says the gallery tab it is under, and the administrators' table is admin.artifacts.list in the console's Operate area"
date: 2026-10-26
status: accepted
issue: 62
paths:
  - apps/troupe_plane/lib/troupe/plane/artifacts.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/admin/api.ex
  - apps/troupe_plane/lib/troupe/plane/admin/console.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/settings.ex
  - apps/troupe_plane/test/troupe/plane/artifact_teams_test.exs
  - apps/troupe_core/lib/troupe/tools/publish_artifact.ex
  - apps/troupe_core/lib/troupe/commands.ex
  - apps/troupe_gateway/lib/troupe/gateway/artifacts.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/gui/apps/desktop/src/views/Publish.tsx
  - clients/gui/apps/console/src/views/Artifacts.tsx
  - clients/gui/apps/console/src/views/PublishedArtifacts.tsx
  - clients/gui/apps/console/src/nav.ts
  - clients/gui/packages/client/src/artifacts.ts
  - clients/gui/packages/client/src/admin.ts
  - PROTOCOL.md
  - docs/user/artifacts.md
  - docs/admin/console.md
symbols:
  - Troupe.Plane.Artifacts.visible/3
  - Troupe.Plane.Artifacts.admin_list/1
  - Troupe.Plane.Admin.artifacts_list/1
  - Troupe.Plane.Admin.artifact_takedown/2
gist: "private (default: owner + links; a platform admin may take down) or team:<name> (members read, its admins take down, its quota); rows carry scope"
---

Issue #62's third slice, as the maintainer decided it on #765 on 2026-10-26: "Team visibility
for artifacts: `visibility: team:<name>`", and, from the gallery's design the same day, a
`private` visibility, "Only you: nobody else can find or open it, not even your team admin.
Share it when you are ready", which #62 asked for as the default. It builds on Decisions 948 and
950 and changes one rule of 948, said below.

## A team's

`team:<name>` is for the members of that team, read from the identity provider's groups at every
request as a profile's people are, so leaving the team takes it away at the next click.

- **Who publishes one.** A member of the team. A platform administrator publishes to any team
  there is (`not_found` for one that is not). Anybody else is `forbidden`, with a sentence that
  names the teams they are in (`you are not in team research, so you cannot publish to its
  people; you are in team:engineering`), which is how the tool, `/publish` and the desktop
  dialog list a person's teams at the moment one is refused. A team that does not exist is
  refused to a non-administrator as one they are not in: whether it exists is not theirs to
  learn, as for `Admin`'s teams.
- **Its quota** is that team's, whatever team the publisher is in first and whatever team a pod
  session runs under: the bytes are the team's because the artifact is. An owner who moves an
  artifact to a team moves every stored byte of it to that team's quota, checked as a publish
  is, and its `team` becomes that team.
- **Who takes it down.** Its owner deletes it; a team administrator of that team, member or not,
  and a platform administrator take it down (`artifact.delete` with `by: takedown`). A team
  administrator sees their teams' artifacts as a platform administrator sees every one, and
  takes down no other kind: an organisation's or a profile's artifact stays the platform
  administrators' to take down, as Decision 948 has it.

## Private, the default

`private` is its owner's and nobody else's: no team member, no team administrator, no profile's
people. A link (`artifact.share`) works on it as on any other, and is how it is shared; whoever
a link reached sees it as `shared`. A publish that names no visibility makes a new one private
(`artifact.publish`, the daemon's `artifact.publish`, `publish_artifact`, `/publish` with a path
alone, the desktop's **Publish…**), and a new version that names none keeps what it was for.

**The one exception, and the rule of 948 it changes.** Decision 948 let a platform administrator
see every artifact. They no longer see another person's private one: not in `artifact.list`,
`artifact.get`, `artifact.open` or on the artifacts host. A platform administrator may still take
one down, by `artifact.delete` or `admin.artifact.takedown` naming its id, audited as any
takedown, and `admin.artifacts.list` names it (its title, owner and size, never its content) so
that a takedown has something to name. That is the only thing anybody but its owner and its
links' holders may do to one. Not chosen: no takedown at all, which would leave an operator no
way to remove a page that breaks the organisation's rules or fills its storage; and a platform
administrator who reads it, which is what "not even your team admin" rules out for anybody who
is not its owner.

## Which tab a row is under

Every row of `artifact.list` (and `artifact.get`) carries `scope`: `mine` for the caller's own,
`private` for their own private ones, the visibility for one that is for somebody the caller is
(`organisation`, `team:<name>`, `profile:<name>`), `shared` where only a link reached it, and the
visibility again for one an administrator sees by their role. A gallery tabs by it and works out
no membership itself. The answer also carries `teams`, the caller's, beside `profiles`, for the
publish surfaces to offer; `teams: true` narrows the list to the teams' own (of the teams the
caller is in or administers, every team's for a platform administrator), which is the console's
**Teams** tab: one list, each card naming its team.

## The administrators' table

The console is the administrators' panel (the maintainer, on #765), so a person's own gallery is
not where an administrator works through what people published. `admin.artifacts.list` is every
artifact for a platform administrator, private ones included, and for a team administrator their
teams' own; `admin.artifact.takedown` is the takedown from it, destructive and confirmed by its
id over MCP. Both are placed on a new Operate area, **Published artifacts**, a plain table with
**Take down** typed by the id. Reading the table is not audited; the takedown is. Nothing there
opens an artifact.

## Where a visibility is chosen

The `publish_artifact` tool's description and schema name `private` (the default), `organisation`,
`team:<name>` and `profile:<name>`, and `visibility` is no longer required; the line grew by about
a hundred bytes, inside the offline bench's budgets. `/publish <path> [private | organisation |
team:<name> | profile:<name>]` takes a path alone. The desktop dialog offers **Only you** first,
then the organisation, each of the person's teams and each profile. The console's
`artifacts_publish_organisation` setting points a refused person at a team or a profile.

## Proof

- `apps/troupe_plane/test/troupe/plane/artifact_teams_test.exs`: a member publishes to their
  team and a platform administrator to any; another team refused with the person's teams named,
  one that is not there refused as not theirs, a malformed name invalid; the named team's quota
  and a move taking every byte there; members list, get, open and fetch it on the host and
  nobody else does, a leaver at once; `scope` on every row (mine, a team, the organisation, a
  profile, shared) and `teams: true`; a team administrator who is not a member takes one down,
  another team's administrator does not see it, and neither takes down an organisation's or a
  profile's; a private one is what a publish naming nobody makes, `scope: private`, seen by
  nobody else (a teammate, the team's administrator, a platform administrator) on either host,
  shared by a link, kept private by a republish naming nobody; a platform administrator's
  takedown of one, audited; `admin.artifacts.list` for each role and `admin.artifact.takedown`.
- `artifacts_test.exs`'s refused visibilities; `admin_parity_test.exs` and
  `console_coverage_test.exs` (both new methods have an MCP tool and a console area).
- `apps/troupe_core/test/troupe/tools/publish_artifact_test.exs` (private when nothing is said,
  nothing sent for a new version, a team's words, the schema); `clients/tui/test/troupe/
  publish_command_test.exs` (a path alone, the usage naming `team:<name>`).
- The console's `artifact-teams.test.tsx` (the Teams tab, a private one under its owner's Mine,
  Published artifacts for a platform and a team administrator, a takedown typed by its id),
  `artifacts.test.tsx`'s tabs and `coverage.test.ts`; the desktop app's `publish.test.tsx`
  (**Only you** first and sent as `private`, the person's teams offered).

All of the plane's failed on the chunk's tip (`e544a82f`): there was no team or private
visibility, no `scope`, and no administrators' table.
