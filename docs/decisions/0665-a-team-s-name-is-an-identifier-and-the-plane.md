---
number: 665
title: A team's name is an identifier, and the plane refuses one that is not
date: 2026-09-21
status: accepted
paths:
  - apps/troupe_plane/test/troupe/plane/team_name_test.exs
  - apps/troupe_protocol/lib/troupe/worker_profile.ex
gist: A team's name is an identifier, and the plane refuses one that is not
---

A team's
name goes into the OpenBao path `troupe/teams/<name>/sessions/<id>` and into the
Kubernetes claim `team-<name>`, which admits lowercase letters, digits and dashes in
at most 63 characters and nothing else: a name with a space in it failed every
session create at the pod, and encoding the path would only have moved the failure
to the volume. The only place to stop it is where a team is made. `Team.changeset`
requires `^[a-z0-9]([a-z0-9-]{0,56}[a-z0-9])?$` — 58 characters leaves room for
the `team-` — and the refusal says so in words: `team.enable` answers with a
sentence per field instead of an inspected keyword list, and the Teams screen shows
the rule under the name field before anybody breaks it. The default a pushed group
is given was already a slug and is now truncated to fit, so a long display name
becomes a long name rather than a refused one. Existing teams are not touched: the
format is only checked when the name changes, so a team named before this rule can
still have its budget edited and can still be removed with `team.disable`, which is
the way out for it. Proof: `Troupe.Plane.TeamNameTest`.
