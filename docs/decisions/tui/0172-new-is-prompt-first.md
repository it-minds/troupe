---
number: 172
title: "/new is the prompt-first screen: a message box first, the settings as one sentence of chips that Tab and the arrow keys move between and Enter opens, the same inline tokens as the desktop app (in this box @profile is a token and /local is not a command), the profile auto-picked with the reason said, a full profile queued with the plane's wait on the curtain line, Enter to start, and HQ's n opens the same screen in place of its wizard"
date: 2026-11-12
status: accepted
paths:
  - clients/tui/lib/troupe/ui/tui/new_session_page.ex
  - clients/tui/lib/troupe/ui/new_session.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/lib/troupe/ui/hq.ex
  - clients/tui/lib/troupe/ui/tui/agent_chooser.ex
  - clients/tui/test/troupe/agent_picker_test.exs
  - clients/tui/lib/troupe/client/remote.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/cli/run_target.ex
  - clients/tui/lib/troupe/cli/runner.ex
  - clients/tui/lib/troupe/cli.ex
  - clients/tui/test/troupe/new_session_screen_test.exs
  - clients/tui/test/troupe/run_profile_test.exs
  - clients/tui/test/troupe/new_session_test.exs
  - clients/tui/test/troupe/remote_hq_test.exs
  - clients/tui/test/support/fake_remote.ex
  - docs/user/cli-reference.md
  - docs/user/terminal-screen.md
  - docs/user/agents.md
symbols:
  - Troupe.UI.TUI.NewSessionPage
  - Troupe.CLI.RunTarget
gist: "/new opens a message box first and a sentence of chips; tokens as the desktop; Enter starts, modified Enter is a newline; queue shows the wait; HQ n opens it; --remote/--private pre-set chips"
---

Root Decision 975 makes a session start from a message in both clients. This is the
terminal's half.

## Decision

`/new` takes the screen (as Decision 151 has it) with the message box first and, under it,
"Runs [on the platform] with [code] as [build] · everyone on core can open it". Tab moves
from the box to the chips and on to CALLED, ←→ move between the chips, Enter opens the
picker under the sentence: where it runs, the recent folders, the profiles with their room
(`FULL` in the stale amber the screen already uses for what may no longer hold), the agent.
The agent on this computer is chosen in the one agent picker (Decisions 164, 166), which
comes back to the screen and there only picks (`s`, `b`, `e` and `n` do nothing before a
session exists; making and editing an agent are `/agents`'); this narrows those two: `/new` no longer opens that picker
first, its agent chip does. A plane profile's agents are listed from the listing.

The box reads the same tokens as the desktop app, through `Troupe.UI.NewSession`. In this
box `@name` naming a profile is a token, not a path to complete (the command line's `@path`
completion is not offered here), and a line starting `/local` or `/platform` is a token,
not a command (Decision 101), since the box is not the command line.

**Enter starts**, as Enter sends on the command line, and Shift, Alt or Ctrl on Enter is a
newline, as it is there. Ctrl+Enter is not told from Enter by most terminals without a
keyboard protocol, so the screen does not rely on it. On an empty box, or with the chips
focused, a digit is "start like last time": the recent session's where, folder, profile
and agent set the chips, and the box is left alone.

A full profile's start is the plane's wait made visible: the curtain line says "waiting
for a free place in <profile>" at every answer, `token.mint` is asked again as
`retry_after_ms` says (in a task, so the screen draws), and the session screen opens once
it is placed; Esc goes back to the form and the session waits on at the plane. The three
casting steps are the design's words on the page while the start runs. "On this computer"
is greyed with why until the daemon link is up.

`/new --remote PROFILE` and `/new --private` pre-set the chips and Enter starts;
`/new --branch` forks at once, as before. HQ's `n` opens this screen on the platform with
HQ's selected team and profile, and HQ's wizard is gone: less code than keeping both. What
the wizard had that the screen does not is a git source and a private/team choice; a
platform session from the screen is the team's, as its sentence says.

`troupe run --profile NAME [--title …]` starts the task on the platform as this screen
would, a full profile waited on with one line printed per wait; its task text reads the
same tokens, a token winning over a flag.
