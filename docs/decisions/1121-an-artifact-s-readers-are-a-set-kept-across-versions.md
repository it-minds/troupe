---
number: 1121
title: "An artifact's readers are a set (its owner, teams, people, the organisation switch, links) kept across its versions: a republish keeps them and asks nothing, sharing per profile is gone, migrated to the profile's granted teams, and the owner may give it to a team granted its session's profile without being in it"
date: 2026-11-28
status: accepted
issue: 1238
supersedes: [948, 953, 955, 964, 965]
paths:
  - apps/troupe_plane/lib/troupe/plane/artifacts.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts/teams.ex
  - apps/troupe_plane/priv/repo/migrations/20261128001121_artifact_teams.exs
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - apps/troupe_core/lib/troupe/tools/publish_artifact.ex
  - apps/troupe_core/lib/troupe/session/approvals.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
symbols:
  - Troupe.Plane.Artifacts.access/3
  - Troupe.Plane.Artifacts.set_access/4
  - Troupe.Plane.Artifacts.Teams
  - Troupe.Tools.PublishArtifact.must_ask?/1
  - Troupe.Tools.PublishArtifact.publication/2
gist: "Readers = owner + artifact_teams + people + organisation switch + links, per artifact not version; visibility private|organisation; republish keeps them, not must-ask; access.get/set diff-audited; profile-granted teams givable"
---

An artifact had one audience in `visibility` (one team or one profile), and the gate asked
it again, with nothing chosen, at every version. Now who reads it is a set, as a shared
document's is, and a new version never touches it.

- **The set.** Its owner (the person, or the owning team, Decision 964); the teams in
  `artifact_teams`, whose members read it at `view`; the people in `artifact_people`
  (Decision 1007); every signed-in person while `visibility` is `organisation`; and its links.
  `visibility` is `private` or `organisation` only. All are keyed by artifact, so every
  version is read by the same set; changing it (`artifact.access.set`, each part the whole
  of that part, applied as a difference) makes no version and writes one audit row per team
  or person (`artifact.share`/`artifact.unshare`, detail `team` or `person`) and one
  `artifact.visibility` for the switch. This supersedes 948's and 953's single audience and
  955's "a visibility move is a version" for the set; `artifact.put` with only `visibility`
  still moves private/organisation as a version, for the clients that do it so.
- **Who may be added.** A team the owner is in, or any team granted the profile the
  artifact's session ran on (`artifacts.profile`): those people could run that profile
  already. 953's "a team you are in" gives way to that, for publish and access alike. People
  as 1007, the picker widened to that profile's covering teams (`people.search` with
  `artifact`); nobody else, no organisation directory. A person added is told on their watch.
- **Readers are not ownership.** A new artifact is its publisher's unless they say `team` or
  `team:<name>`; 964's "published to a team is the team's" is gone, since the gate now ticks
  the profile's teams by default and would otherwise hand every pod artifact to a team. Its
  quota is the owning team's, else the session's team, else the publisher's first.
- **The gate.** 965 holds for a new artifact only: no `visibility` and no `teams` must ask,
  and the plane names the default teams (`publication.teams`). A republish is not must-ask,
  carries `publication.access` (who reads it, in the plane's words), drops an audience
  answered for it, and a call naming one is refused: the model does not re-aim an artifact.
- **Migration.** `team:<name>` becomes that team in the set, `profile:<name>` every team
  granted the profile then, both `private`; unaudited, counted in the log. Old forms are
  refused naming `artifact.access.set`; `artifact.list` keeps `profiles: []` until the
  clients drop it.

Not chosen: roles per team (teams give view only), and a team set on each version, which
would make a republish re-share. Undoing it brings back the re-asked audience and one team
per artifact, and a rollback reads converted rows as private.
