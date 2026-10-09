---
number: 153
title: "`troupe setup` is one full screen over the daemon's first-run questions, opened by plain `troupe` when no provider is set up: a question at a time, nothing written before the summary, Shift-Tab back, Esc out, ending in the session it started"
date: 2026-10-09
status: accepted
issue: 76
paths:
  - clients/tui/lib/troupe/ui/setup.ex
  - clients/tui/lib/troupe/cli/config_setup.ex
  - clients/tui/lib/troupe/cli/runner.ex
  - clients/tui/lib/troupe/cli.ex
  - clients/tui/test/troupe/setup_screen_test.exs
  - clients/tui/test/troupe/setup_screen_daemon_test.exs
  - clients/tui/test/troupe/config_setup_test.exs
  - clients/tui/test/test_helper.exs
symbols:
  - Troupe.UI.Setup
  - Troupe.CLI.ConfigSetup.setup/2
  - Troupe.CLI.ConfigSetup.before_session/2
gist: "troupe setup = Troupe.UI.Setup over setup.get/answer, its own app before any session; writes held to the summary; Esc writes nothing; no TTY says which"
---

Issue #76, root Decision 817 (what it writes) after root Decisions 705 and 762, and TUI
Decision 123 (plain `troupe` asks the daemon first). The terminal client asked a first run's
questions line by line; the full-screen flow was the slice those decisions left.

- **Its own screen, before any session.** `Troupe.UI.Setup` is an `ExRatatui.App` of its
  own, run under `Troupe.UI.Windows` as the terminal UI is, and the runner waits for how
  it ended, then for it to give the terminal back, before the session's window takes
  it. It is not a page of `Troupe.UI.TUI.Server`, which needs a session to mount: a
  scratch session made only to draw the setup would be a write on a machine where Esc
  must write nothing, and the session worth opening is the one the setup starts. It asks
  the daemon through a `call` it is given (`Link.call/2`), so the UI still calls nothing
  past `Troupe.Client` (`mix troupe.xref`) and a test plays the daemon.
- **The desktop app's questions, order and words.** Where, provider (a vendor's key in
  the environment, opencode, a working `config.yaml` first), key, models (the main one,
  then the small one, which the desktop app asks on one screen), project with the approval
  model, at login, summary. The fake provider is offered last only where
  `TROUPE_FAKE_SCRIPT` names a script, so a packaged build can be walked to a session with
  no model behind it and a person with a key never sees it.
- **Keys.** ↑↓ choose, typing goes to the step's one field, Enter answers, Shift-Tab goes
  back a step (the daemon's `{"back": true}` for a step it holds, which forgets the key
  with it, as the desktop app's Back does), Esc and Ctrl-C leave; a key being asked
  about holds the keys until the daemon answers. A typed key is drawn as one dot a
  character, is cleared from the screen's state as it is sent, and is never in a line
  the screen says.
- **The key, by the line-by-line rule.** From `ANTHROPIC_API_KEY` (or `OPENAI_API_KEY`)
  when the daemon has it, typed, or typed as `{env:VAR}`; the daemon checks it before
  anything is kept, so a variable not set where the daemon runs is refused with the
  daemon's reason, where `troupe config` saves the reference and says to set it.
- **At login.** Asked as the desktop app asks it, unless the entry is there already: then
  it is said where it is and that `troupe daemon login off` takes it back, and kept, as
  the installers do (root Decision 818).
- **Where it is opened.** `troupe setup` at any time, whatever is set up; plain `troupe`
  when the daemon says a first run is needed, opening the setup's session instead of a
  new one, and going on to a new one as before when the person leaves. A daemon from
  before `setup.get`, and a terminal the screen could not be drawn on, get `troupe
  config`'s questions line by line (said); with standard input or output not a terminal
  `troupe setup` says which, prints the ways on, and exits 1. `troupe config` keeps its
  own questions (TUI Decision 123).
- **Proof:** `cli_test.exs` ("troupe setup is a command line", refused on the chunk's tip
  with `unknown arguments: setup`); `setup_screen_test.exs` (the whole path with the
  sends in order and none that writes before the summary, back on both sides, Esc,
  a refused key, a refusal after the summary, a plane, a half-done flow, what is on the
  machine first, an entry already at login); `setup_screen_daemon_test.exs` against the
  embedded daemon; `config_setup_test.exs` for the entries and the fallbacks; `mix check`;
  and the installed TUI driven headlessly against the installed daemon with scratch
  homes.
