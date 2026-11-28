---
number: 1122
title: "The idle timeout a client is told and the one a pod is given are one read, `Ladder.idle_timeout_seconds/1`: the team's as the ladder resolves it, the platform's own with no team"
date: 2026-11-28
status: accepted
issue: 1236
supersedes: [1062]
paths:
  - apps/troupe_plane/lib/troupe/plane/settings/ladder.ex
  - apps/troupe_plane/lib/troupe/plane/profile_view.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - clients/gui/apps/console/src/views/MemberView.tsx
gist: "profile.get limits.idle_seconds and activation's idle_timeout_seconds both read Ladder.idle_timeout_seconds/1: team's resolved value, the platform's with no team, nil only if neither is a positive integer"
---

Issue #1236. This narrows Decision 1062 on one point: it said `limits.idle_seconds` is
`null` without a team. It is the platform's value there.

**What is decided.** How long a session rests before its pod puts it to sleep is read in
one place, `Ladder.idle_timeout_seconds/1`: the team's own value as the ladder resolves it
under the platform's and the deployment's, and with no team the platform's own. The pod is
given it at activation (`idle_params/1`) and `profile.get` says it as `limits.idle_seconds`,
so the number a person is shown is the number the pod applies. `null` is left for a value
that is not a positive integer, which no plane now sends for no team; a console that meets
a plane from before this still says "not said" for it, and says "the platform" as whose
number a no-team answer is.

**Not chosen.** Keeping `null` for no team, as 1062 had it: the pod went on sleeping the
session on the platform's number while every client said none was known, so a person could
not be told when the session would sleep, which is what the value is for. Reading the
column for a client and the ladder for the pod, two reads that agree only by accident.

**If undone.** `profile.get` and the activation disagree again for a session with no team,
and a client shows nothing for a timeout that is in force.
