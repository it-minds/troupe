---
number: 964
title: "An artifact may be a team's, whose members and administrators own it together: one published to a team is the team's unless its publisher says owner: me, artifact.transfer gives a person's own to a team and lets the team's administrator take it back, and the person who published it stays on the row"
date: 2026-10-28
status: accepted
issue: 62
supersedes: [953]
paths:
  - apps/troupe_plane/lib/troupe/plane/artifacts.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts/artifact.ex
  - apps/troupe_plane/priv/repo/migrations/20261028000964_artifact_owner_team.exs
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/test/troupe/plane/artifact_ownership_test.exs
  - PROTOCOL.md
  - docs/user/artifacts.md
symbols:
  - Troupe.Plane.Artifacts.transfer/4
  - Troupe.Plane.Artifacts.role/2
gist: "owner_team makes every member and admin of the team an owner (role owner, whatever the visibility); publish to a team defaults to the team's; transfer: person gives, team admin takes back"
---

Issue #62's fourth slice. Decision 953 made `team:<name>` a visibility: the team's members
read the artifact, its administrators take it down, and the one person who published it
does everything else. That left a team's report the property of whoever happened to run
the session that made it: when they were away, nobody could publish the next version, pin
one, share it or delete it, and when they left the organisation it had no owner at all. An
artifact a team works on is the team's, so now it can be.

## What a team's artifact is

`artifacts.owner_team_id` names the team that owns it, or is null for a person's own.
Where a team owns it, every member of the team and every administrator of it (member or
not, as 953 has a team's administrator) is its owner: `role: owner`, `mine: true`, and
with them every owner's power, which is a new version, an edit, a rollback, a pin, moving
who may open it, making and revoking links, the public-links switch and deleting it,
audited as an owner's (`by: owner`), not a takedown. They see it whatever its visibility,
as a person sees their own: a `private` artifact a team owns is for that team and nobody
else, and is under **Mine** in each member's gallery (`scope: private`). Membership is read
at every request as it is for a visibility, so leaving the team is the end of it at the next
click and joining has it at once; nothing of the artifact changes either way.

`owner_id` stays: the person who published it first, named as `owner` in every row, and who
the artifact goes back to when the team is deleted (`on_delete: nilify_all`, the one place a
team's deletion touches an artifact). Each version records who published it, so a team's
artifact still says which member made which version.

## Publishing to a team makes it the team's

`artifact.publish` and the pod's `session.artifact.publish` take `owner`: `me`, `team` (the
team of a `team:<name>` visibility, and `invalid_params` with any other) or `team:<name>`, a
team the publisher is in, refused in the words a publish to that team is refused (a
platform administrator names any team there is). Unsaid, one published to a team is that
team's, and any other the publisher's own. The default is the team's because that is what
publishing *to* a team means to the people who do it, and because the other default would
leave every artifact an agent publishes for a team on the person who ran the session, which
is the state this decision ends. A publisher who wants a team to read something of theirs
says `owner: "me"`, as the surfaces offer. A new version does not move whose it is: a put
naming `owner` is `invalid_params`, so a change of ownership is never hidden among
publishes.

## `artifact.transfer`

`artifact.transfer {id, to}` moves whose it is, audited as `artifact.transfer` with `from`
(`person` or `team:<name>`), `to` and the title. Its person gives their own to a team they
are in; a platform administrator gives any artifact to any team, a private one they cannot
read too, as they may take one down; an administrator of the team that owns it, or a platform
administrator, takes it back with `to: "me"`, which makes the caller its person, since the
person who published it may be gone. A member who does not administer the team may not:
the team's artifacts are not theirs to hand out. A team's goes to another team only by a
platform administrator. `may_transfer` on every row is whether the caller may call it at
all, so a client shows the control to exactly those people.

## What 953 keeps

This widens one line of 953, "`team:<name>` (members read, its admins take down)": the
members of a team that *owns* an artifact do everything, not read alone. The rest of 953
stands: a `team:<name>` artifact somebody kept their own is read by the members and taken
down by the team's administrators, a private one is its owners' alone, the quota is the team
the artifact is for, `scope` names the gallery tab, and the administrators' table is where
a takedown starts; that table now names the team that owns each row, and a team
administrator's has their teams' own in it.

## Not chosen

- **Ownership by a group, or by several named people.** A team is already the plane's
  unit of people with administrators, a quota and a budget, read from the identity
  provider; a second kind of owning set would need its own administrators and its own
  answer to who takes one back.
- **Members as editors, without delete.** An edit link already gives that. A team that
  owns a page that needs taking down should not have to find the one person who published
  it, or wait for an administrator.
- **The quota moving with ownership.** The bytes stay with the team the artifact is for,
  as 953 has it; a team that owns a private artifact counts it against whatever team the
  publish counted it against.

## Proof

`apps/troupe_plane/test/troupe/plane/artifact_ownership_test.exs`: a publish to a team is
the team's by default and `owner: me` keeps it the person's, `owner: team` with no team to be
for refused, a team the publisher is not in refused in a publish's words; a member publishes
a version, retitles, rolls back, pins, moves, shares, unshares, switches public links and
deletes as an owner (`by: owner`), and the team's administrator too; a private one is seen by
the team alone, a leaver loses it and the artifact is unchanged; `mine: true` has the team's
and `shared: true` never does; `owner_team` and `may_transfer` on every row; a transfer by
the person, by a platform administrator (any to any, back), a take-back by the team's
administrator and refusals for a member, for a non-owner, for a team the person is not in
and for `me` on a person's own, each audited; a deleted team hands it back; and the artifacts
host serves a team's artifact to a member. `artifact_teams_test.exs`'s rules for a person's
own team artifact, now with `owner: me`.
