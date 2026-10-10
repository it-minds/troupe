---
number: 155
title: A session's screen is command mode, a view over its branches and worktrees with nothing to chat to; a plain line starts the default agent in the checkout, and Ctrl-N chooses the agent, its instruction on screen, and a worktree
date: 2026-10-10
status: accepted
issue: 502
supersedes: [101]
paths:
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/client/remote.ex
  - clients/tui/test/troupe/command_mode_test.exs
  - clients/tui/README.md
  - clients/tui/CLAUDE.md
  - apps/troupe_core/lib/troupe/commands/local.ex
  - clients/tui/test/troupe/project_command_test.exs
symbols:
  - Troupe.Client.start_command/5
  - Troupe.Commands.defined/1
  - Troupe.UI.TUI.Model.windows/1
  - Troupe.UI.TUI.Model.session_window/1
  - Troupe.UI.TUI.Model.asking/1
  - Troupe.UI.TUI.Model.last_line/3
  - Troupe.Client.dispatch/3
  - Troupe.Client.agent_definition/2
  - Troupe.Client.worktree_status/1
  - Troupe.Client.Daemon.idle?/1
gist: "No window activated is command mode: root unlisted until it has work; plain line = default agent in checkout (pod: root); Ctrl-N picks agent+where"
---

Issue #502, parts A and 3, with the choices the coordinator booked for the chunk (the
maintainer had none). Supersedes 101's "a plain line is what you say to it"; its other
half stands: a session has one agent, the window `root`, and `troupe run` and a pod
session still put their work there. Amends 154 only in where the start's questions are
drawn. On the chunk's tip a line typed with no window activated went to the session's own
agent (`Client.send_input(sid, "root", …)`), a new session showed a `root` window that read
`running` before anything ran, with a token count of its own, and a slash command typed in
a window's box was sent to its agent as words (D107).

- **Root is a mode, not a window.** The session's own window is still folded (its goal,
  its loop, the start's questions, the notes the session writes, what `!` ran), but
  `Model.windows/1`, which the strip, the digits, Enter, the status line's counts, the
  observer and Tab completion read, lists it only once its agent has been given work of its
  own: a `troupe run` task, a loop, a watch trigger (D106 sends them there), input on a
  pod, or a session from before command mode. A fresh session lists none. A window with
  nothing asked of it is `:idle`, not `:running` (`started`, set by the first event that is
  the agent's own work, never by a note about it), with no turning mark, no activity line
  and no blinking tick: a branch opened with no prompt reads idle too.
- **The screen with no window activated** is one bordered view, built from what the model
  already folds, with no daemon call but one: the session's facts on a line (its model, its
  goal, watch, the tightest budget warning any window has had, what all of them spent);
  what waits on a person first, in the reserved colour (the start's question as its window
  would draw it, a line per window's approval or question with the digit that opens it);
  the session's own lines (the start's answers, `!` blocks) while its agent is not listed;
  a row per branch (digit and mark, window, agent, state, elapsed, the last line it
  produced, `↑`/`↓` tokens and what its turns cost, from the event that ends each turn,
  its own agent's only, since that carries its subagents'); and a row per worktree. The
  worktrees are the one call, `worktree.list`, which gains ahead/behind and `+n −m` in root
  Decision 840; it is asked away from the screen's process at mount and when something
  may have moved a tree (a branch opening, resting or going, a worktree made, merged or
  thrown away, a `!` command), never on a timer. With nothing listed and nothing asked, the
  mask and what to type stand under the facts (149). A click on a branch's row opens it.
  With a window activated the tray of tiles is as before.
- **Plain text starts `build` in the checkout**, the configuration's `default_agent`, as a
  branch (`Client.dispatch/3` with `worktree: "never"`), with one line on the notice line
  saying so first (`starting build in the checkout: a line without / starts it there;
  Ctrl-N chooses the agent and a worktree`); the branch is created once that line has been
  drawn. Never a chat with root. While a start's question is open (154), Enter on typed
  text keeps the text and says to answer it first, so onboarding and the brief still come
  before anything starts. On a pod, which runs one profile and starts no branches, the
  line is said to the session's agent, as before, and that agent is its row.
- **Choosing an agent belongs to command mode.** Ctrl-N opens the chooser over the
  primary agents `agents.list` serves, the default selected; beside the list the selected
  one's whole instruction, `agents.get`'s `prompt` (root Decision 841), read when it is
  first shown, PgUp/PgDn to read it; a daemon from before `agents.get` shows the
  description and says nothing more. Enter, then `w` for a worktree of its own (`always`)
  or `c` for the checkout (`never`). What was typed before Ctrl-N is the task and starts at
  once; with nothing typed the choice waits on the command line, which says so, for the
  task, and Esc forgets it. A workflow keeps its worktree whatever is chosen. Not a slash
  command: `/agents` is #503's manager. Ctrl-N is no binding of the box's editor (88), and
  Ctrl with a letter rather than Ctrl-Alt, which is AltGr on international layouts.
- **A command a file defines starts a branch too** (amends Decision 763 for command
  mode): typed on the command line or picked from the palette with no window activated,
  `/review the parser` is work like a plain line, so it opens a branch in the checkout on
  the agent the file's frontmatter names (`agent: plan`, which `commands.list` now carries
  in the row) or on the default agent, and runs the command there (`commands.run` on the
  branch's session, so the daemon expands the prompt and asks first where Decision 814
  says it does, in that window); never on the session's own agent. From a window, and on
  a pod, it goes to the session's agent as 763 has it.
- **The word beside the mark follows it**: `done ●` and `failed ●` lose the `●` once the
  window has been read, as ⏺ becomes ○, in command mode's row and in the observer.
- **A slash command in a window's box runs as a command**, on that window where it takes
  one, when its first word names a built-in, a file's command or an agent; `/todo` stays
  the window's own; anything else that starts with `/` (`/usr/bin is missing`) is still
  said to the window's agent.
- **A session with branches is not scratch.** `Client.Daemon.idle?/1` counts a branch
  opened from the session as work, so `/new` and a switch no longer stop a session whose
  work is all in branches.
- **Headless runs keep working as they did**: `troupe run --headless`, `troupe resume
  --headless`, `-p` and the runner's `target: "root"` talk to the session's own agent
  through `Client.send_input/3`, not through the screen; a non-headless `troupe run` opens
  command mode with its agent listed, one digit away.

Proof: `test/troupe/command_mode_test.exs`. A new session opens in command mode, with no
window, its own idle, and nothing running on screen; a plain line starts `build-1` in the
checkout with the line as its prompt, the notice first, and no input to root, and its row
shows its agent, last line and cost; the start's question (a `CLAUDE.md` in a repository)
is asked and a plain line waits for it; Ctrl-N with a line typed shows `quick`'s
instruction as `agents.get` serves it, `w` starts `quick-1` in a worktree, and its
worktree's row says `↑0 ↓0`, `+2 −0`, dirty and `quick-1 · alive`; Ctrl-N with nothing
typed leaves the choice waiting for the task; `/goal` typed in a branch's window sets the
goal and `/usr/bin is missing` reaches its agent; a pod session's agent is its row and a
plain line goes to it; `/review the parser`, its file naming `agent: plan`, opens `plan-1`
in the checkout whose input is the expanded prompt, and `/standup`, naming none, opens
`build-1`, with nothing said to the session's own agent (`project_command_test.exs` asks
814's question in each branch's window). `commands_test.exs` in core: a file's `agent` is
in its row, and one that names none has no `agent`. `tui_theme_test.exs`: `done ●` loses
its `●` once read, in the row and the observer. On the chunk's tip a reproduction showed the fresh screen's `root ·
running` and the line typed reaching `root` as input. Tests that typed to root on the
command line now say it to the session's own agent (`say!/2`, as a headless run does) or
type into a branch's window; the theme's corner tests draw the tray, and one checks the
row's mark. `mix check` in `clients/tui`, and the installed TUI driven headlessly against
the installed daemon (the pull request has it).
