---
number: 191
title: "An agent's publication in the approval box is a new artifact's sharing menu, ticked by digit (the plane's named teams ticked, the person's other teams, the organisation switch, the one team's ownership) and sent by y or Enter; a new version says who reads it and asks nothing; /publish and troupe artifacts publish name teams with --team, and the terminal shares nothing after publishing"
date: 2026-11-28
status: accepted
issue: 1238
supersedes: [169]
paths:
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/client/artifacts.ex
  - clients/tui/lib/troupe/cli/artifacts.ex
  - clients/tui/lib/troupe/ui/headless/printer.ex
symbols:
  - Troupe.UI.TUI.Model.publish_choices/2
  - Troupe.UI.TUI.Model.publish_toggle/2
  - Troupe.UI.TUI.Model.publish_answer/1
  - Troupe.Client.Artifacts.publish_args/1
gist: "publish_artifact gate: new = digit toggles named teams (ticked) + own teams + organisation + one-team owner, y/Enter sends {visibility, teams, owner}; republish = shows access, sends nothing; /publish --team NAME...; no share command"
---

Root Decision 1121 made an artifact's readers a set kept across its versions, so TUI Decision
169's one audience picked by digit has nothing left to pick. The box follows the plane.

- **A new artifact: a menu of toggles.** The teams the publication names come first, ticked
  (the agent's, or the teams granted the session's profile, which the plane names); then
  the person's other teams from `artifact.list`, unticked; then the organisation switch and
  "the one team ticked owns it". A digit toggles one; `y` or Enter sends the menu as it
  stands (`visibility`, `teams` in the menu's order, `owner` the team's only with one team
  ticked); `n` denies. There is always an answer, the person alone at least, so nothing is
  refused for want of a pick. `a` is offered where the agent named a visibility: the harness
  allows a call that named none once, whatever teams were ticked.
- **A new version asks nothing.** The box says who reads it in the plane's words
  (`publication.access`) and that the version keeps them; digits do nothing, `y` sends no
  audience and no owner.
- **Readers are not ownership.** A publication is the person's unless they make it the one
  team's; 169's "a team's publication is the team's" is gone with 1121's.
- **The commands.** `/publish <path> [private | organisation] [--team <name>]... [--owner me
  | team]`, the gallery's `p` line the same, and `troupe artifacts publish FILE [--to private
  | organisation] [--team NAME]...`; `team:<name>` and `profile:<name>` are no words either
  takes, nor `--scope profile:NAME`. Each says who reads what it published.

Not chosen: a share or unshare command for teams and people after publishing. The terminal
had none, and one menu edited from three places invites three drafts of one set; the
desktop app's Access tab and the console's page are where who reads it changes.

Undoing it brings back an audience picked for every version and one team per artifact,
which the plane now refuses.
