---
number: 1017
title: "A new session on a profile more than one of the person's teams may use asks which team it is for: both clients ask before sending where the profile listing names several teams, and on the plane's `choose a team` refusal where it did not, from the names the refusal carries; the answer is remembered per profile in the client's own settings, shown as a chip at the end of the sentence and changeable there, and dropped when that team may no longer use the profile; `troupe run --team` says it for a script, which is never given the remembered one; the plane keeps the refusal and logs it"
date: 2026-11-16
status: accepted
issue: 992
supersedes: []
paths:
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - clients/gui/packages/client/src/newSession.ts
  - clients/gui/packages/client/src/index.ts
  - clients/gui/scripts/fake-deployment.ts
  - clients/gui/apps/desktop/src/views/StartSession.tsx
  - clients/tui/lib/troupe/ui/new_session.ex
  - clients/tui/lib/troupe/ui/tui/new_session_page.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/client/team_choice.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/client/remote.ex
  - clients/tui/lib/troupe/cli.ex
  - clients/tui/lib/troupe/cli/run_target.ex
  - clients/tui/lib/troupe/cli/runner.ex
symbols:
  - teamsToChoose
  - chosenTeam
  - teamQuestion
  - Troupe.Client.TeamChoice
gist: "Two of your teams on a profile: the new-session screen asks which team once (before sending from profiles.list's teams, or on the plane's choose-a-team refusal), remembers it per profile in the client, shows it as a chip; troupe run --team; plane logs the refusal"
---

A second `team.grant` of a profile is an ordinary admin action, and it stopped every new
session on that profile for anybody in both teams: the plane answered `invalid_params`,
`reason: "choose a team"`, `teams: [...]`, and both clients printed "Could not start:
Choose a team" with no list and no way to pick (troupe #992). The plane's refusal is right
and stays: the team decides whose budget pays and whose volume the session mounts, and
guessing would pick one of those for somebody.

## Decision

**The client asks, and before sending where it can.** `profiles.list` already answers each
profile's `teams`, the person's teams that may use it, by the same rule `session.create`
picks a team with (`ProfileView.team_names`). Where that names more than one, the
new-session screen asks before it sends: one round trip fewer than sending and being
refused, and the person sees the question with the profile, before anything is started.
The refusal is still handled, because grants can change between the screen loading and
the send: a create refused with `choose a team` and two or more `teams` goes back to the
form with the question open on the refusal's names, which are newer than the listing's for
that profile, and the pick sends the create again with `team` set and nothing else
changed. Neither client shows "Could not start" for it.

**The question is the team chip's picker.** Where it is a choice, and only then, the
sentence ends "· everyone on [team] can open it", the
team a chip like the others, in place of "everyone on core and design can open it", which
was not true of any one session. With no team chosen yet the chip reads "which team?" in
the queued amber, and the line under the sentence asks: "core and design can both use
dev. Choose the team it is for: its budget pays, and everyone on it can open it." Start
(Enter in the terminal) opens the chip's picker first, "WHICH TEAM IT IS FOR", each option
saying whose budget pays and who can open it, and the pick starts. Esc closes it and leaves
the form as it was, nothing started. With one candidate team nothing new appears and the
create names no team, as before: the plane takes the only one. In the terminal the team is
a fourth chip, after the agent, reached with Tab and →; this is the TUI's sentence of
Decision 975 and TUI Decision 172 with one chip more, so it takes no TUI decision of its
own.

**Remembered per profile, in the client.** The pick, from the question or from the chip,
is remembered for the profile on that plane in the client's own settings: the desktop
app's local preferences (`newSession.team.<plane>|<profile>`), the terminal's state file
(`new-session-teams.json`, `Troupe.Client.TeamChoice`). Never the plane: the plane is told
the team on each create and keeps no preference, so two of a person's machines may answer
differently and neither is wrong. A remembered team is shown on the chip, so the person
sees whose budget it is before starting, and changed there. One that may no longer use the
profile is dropped without a word and the question is asked again. A refusal whose names
include the remembered team is answered with it and the create sent again, unasked.
Remembering was chosen
over asking every time because the answer rarely changes for one profile, and the chip
keeps it in sight; HQ's selected team in the terminal counts as the pick where it is one of
the candidates.

**Headless.** `troupe run --team NAME` names the team (`--team` beside `--profile`, in the
help and the command reference). A run without one on such a profile stops, non-zero, with
one line: "troupe: could not start: core and design can both use dev; say which team it is
for with --team, as in --team core". A script is never given the team the screen
remembers: what a script runs as is written in the script. The desktop app has no
scripted start or deep link that creates a session, so it has no such line.

**The plane logs it.** The refusal is one `info` line, who, on which profile, and how many
of their teams may use it, so an operator asked why a person could not start a session
finds it. The refusal's shape is unchanged; `PROTOCOL.md` says it under `profiles.list`'s
`teams`, where the plane's `session.create` parameters are described.

The daemon does not stand between a client and the plane's `session.create`: both clients
call the plane for a platform session, the terminal through its own plane connection, the
desktop app through its sign-in, so there is no forwarding that could drop the refusal's
`data`. The terminal's plane client now passes the names through whole
(`{:choose_team, teams}`) instead of flattening the refusal into text.
