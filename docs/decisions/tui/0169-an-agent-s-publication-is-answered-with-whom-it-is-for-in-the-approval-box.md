---
number: 169
title: "An agent's publication is answered in the window's approval box with whom it is for, picked by digit from the audiences this terminal learns from artifact.list when the request arrives, the agent's proposal picked first and nothing where it named nobody; a team's artifact is shown as the team's wherever a row says whose it is, and troupe artifacts publishes for a team as the team's unless --owner me and hands one on with transfer"
date: 2026-10-28
status: accepted
issue: 62
paths:
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/lib/troupe/ui/tui/artifacts_page.ex
  - clients/tui/lib/troupe/ui/headless/printer.ex
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/lib/troupe/remote/worker.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/client/artifacts.ex
  - clients/tui/lib/troupe/cli/artifacts.ex
  - clients/tui/lib/troupe/cli.ex
  - clients/tui/test/troupe/publish_gate_test.exs
  - clients/tui/test/troupe/artifacts_cli_test.exs
  - clients/tui/test/troupe/artifacts_screen_test.exs
  - docs/user/terminal-screen.md
symbols:
  - Troupe.UI.TUI.Model.publish_choices/2
  - Troupe.UI.TUI.Model.publish_draft/3
  - Troupe.UI.TUI.Model.publish_answer/1
  - Troupe.Client.Artifacts.owner/1
  - Troupe.Client.Artifacts.transfer/2
gist: "publish_artifact gate: digit picks visibility+owner from artifact.list's teams/profiles, proposal preselected, none for nobody, no owner for a republish; rows say team <t>; publish --to team is the team's unless --owner me; transfer --to team:<t>|me"
---

Root #62's team artifacts: an artifact may be a team's, every member its owner, and when
an agent publishes the person says whom it is for at the approval. The plane's contract is
the root's (the `owner_team`, `may_transfer` and `role` of a row; `artifact.publish`'s
`owner`; `artifact.transfer`; `approval_requested`'s `publication` and
`approval.respond`'s `answer`); this is how the terminal shows and answers it.

- **In the approval box, not a screen of its own.** The window's approval box is where a
  TUI person answers approvals, and a delegation at the gate is drawn and answered there
  (TUI Decision 157), so a publication is too: the `PUBLISH “title” (a page, 3 files)`
  line with the keys, whom the agent proposed it for and whose, its note, then the
  audiences numbered with the one picked marked. A digit picks, `y` publishes for the
  one picked, `n` denies, `a` publishes and lets the agent go on unasked. Only the digit
  is new: `y`/`n`/`a` keep their meanings, and digits already pick a question's option
  in the window.
- **The audiences come from `artifact.list`.** The person's teams and profiles are what
  the plane says of them for artifacts, which `artifact.list` answers (`teams`,
  `profiles`, the organisation), through this computer's daemon as every `artifact.*`
  goes; there is no `me` through the daemon. The server reads it when a publication's
  request arrives (`audience_asked/2`), once per request since teams change, and keeps it
  for the view; where the daemon cannot say (signed out, Local only) the box offers only
  you, the organisation and what the agent proposed, which is always among the choices.
  Each team is offered twice, as the team's and as the person's own, since that is the
  one choice the plane will not change afterwards without `artifact.transfer`.
- **The proposal is picked first; nobody is nothing.** The agent's `visibility` and
  `owner` (a team's where it said nothing of a team's) is the choice marked, so `y` alone
  sends what the agent meant. Where it named nobody there is no choice, `y` and `a` are
  refused here with "say whom it is for", as the harness refuses an allow without a
  visibility, and `a` is not offered at all: there is nothing to repeat for the session.
- **A new version offers no ownership.** Whose an artifact is does not change with a
  version (the plane refuses a `publish` with `id` and `owner`), so for a `publication`
  with `id` the choices carry no owner, each team once, and the answer is the visibility
  alone.
- **The draft is the window's**, as the delegation gate's: `state.gate` holds the pick
  for the call on screen (`Model.publish_draft/3`), fresh for another call, dropped when
  another window is activated, sent only with the answer; `approval.respond` carries it
  as `visibility` and `owner` beside the decision (`Troupe.Remote.Worker` passes those
  keys through as it passes `agent`, `brief` and `reason`).
- **Headless** denies it, as every request with nobody to ask, with a line saying what
  the publication is and whom the agent proposed it for; one the agent named nobody for
  says `--auto-approve` would not have answered it either.
- **Whose a row is** is said by `Troupe.Client.Artifacts.owner/1` everywhere a row is
  drawn (`/artifacts`, `troupe artifacts list`, `--json`'s `by`): `team finance` for a
  team's, whoever first published it, since every member owns it; `you`; else who
  published it. The listing adds `transferable` where `may_transfer` says so. `troupe
  artifacts publish --to team:<name>` sends `owner: "team"` unless `--owner me`, and
  says `(team finance's)` on its line; `/publish` and the page's `p` take `me` or `team`
  as a third word. `troupe artifacts transfer ID --to team:<name>|me` is
  `artifact.transfer`, which the daemon forwards as it forwards the viewer's methods.
  `show` prints an artifact's text, as it always has, so the owner is on the listing's
  row and in `--json`, not in `show`.
- **Proof:** `Troupe.PublishGateTest` over a session on `FakeRemote` with the daemon
  linked to it (the box with the proposal picked, a digit and `y`, `y` alone, `a`, `n`,
  nobody named, a new version without ownership; headless; the choices and the draft),
  `Troupe.ArtifactsCLITest` and `Troupe.ArtifactsScreenTest` (whose each row is, `--owner`,
  `transfer` and its refusals in the plane's sentences, `p` with `me`).
