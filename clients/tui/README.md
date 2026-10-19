# troupe, the terminal client

`troupe` is the terminal client of the Troupe harness. Every session runs in the troupe
daemon (the `troupe-daemon` on this machine, or, when none is running, the same daemon
started inside `troupe` itself) or on a plane's worker pod, and the TUI speaks to all of
them over [`PROTOCOL.md`](../../PROTOCOL.md): a remote session looks exactly like a local
one. It ships as one self-contained executable per platform (Linux, macOS, Windows) built
with [Burrito](https://github.com/burrito-elixir/burrito); users need no Erlang or Elixir
installed.

A session opens in **command mode**: not a chat with an agent, but one screen over
everything the session has going. A line that does not start with `/` is work: Enter starts
the default agent (`build`) on it in your checkout, as a **branch** (a session of its own),
and returns control at once; Ctrl-N chooses the agent instead, with its instruction on
screen, and whether it works in a worktree of its own. `/plan look at the parser` or
`/worktree add rate limiting` start one too. Every branch is a window. Branches run
concurrently; a window that needs you (an approval, a question) blinks; you activate it,
answer, and go back to what you were doing. When nothing is running the harness is truly
idle: no model calls, no tokens.

## Install

The installers put `troupe` on the machine with the daemon when asked (`--tui`, `-Tui` on
Windows): the [quick start](../../docs/quick-start.md#1-install) has the two commands, and
[the daemon's page](../../apps/troupe_daemon/README.md#install) every installer option.
Every release carries a binary per platform, `troupe-<version>-<target>` (`.exe` on
Windows). `scripts/build-local` builds one for this host and installs it as `troupe` in
`~/.local/bin`. `troupe update` installs a newer release over `troupe` and `troupe-daemon`
once its signature checks, replacing the daemon only between turns; `--check` says what it
would do and `--rollback` puts the previous ones back ([updating](../../docs/user/updating.md)).

`troupe` uses the daemon already running on this machine, found through its `daemon.json`
as every client finds it, and starts the same daemon inside itself when none is.
`troupe daemon run` starts the standalone `troupe-daemon` instead (found through
`TROUPE_DAEMON_COMMAND` or on the `PATH`), and `troupe daemon status` says whether one is
running. `troupe daemon login on` has the standalone one start every time you log in and
stay up, `troupe daemon login off` takes that back, and a first run that saves settings
asks the same question.

## Configure a provider

`troupe setup`, or plain `troupe` on a machine with no settings and no key, asks for a
provider, a key and models, and writes `config.yaml`
([the first run](../../docs/user/README.md#first-run)). The file, a complete one for each
provider, and every key are in the [cookbook](../../docs/user/configuration/cookbook.md)
and [configuration](../../docs/user/configuration.md); `troupe config --explain` shows
where each value came from, and `troupe config validate` checks the files.

`read_roots` widens only reading: `read_file`, `grep`, `list_files` and `glob` may look in
those directories as well as the workspace, which lets the agent read a dependency's
source without shelling out. `write_file` and `edit_file` can never write outside the
workspace root. Paths are compared after resolving symlinks, so a link out of the
workspace counts as wherever it points.

## Use

`troupe --help` prints every command line `troupe` takes, and
[the command reference](../../docs/user/cli-reference.md) lists the same; a few of them:

```
troupe                                  # TUI in the current directory
troupe --workspace DIR                  # TUI rooted at DIR, wherever it is started
troupe --prompt "@src/app.ts "          # TUI with that in its input, not yet sent
troupe --watch                          # TUI with watch mode on
troupe --no-mouse                       # TUI without mouse reporting (terminal selection works)
troupe --private                        # a private session, sealed to the plane you signed in to
troupe run build "make the tests pass" --headless --auto-approve
troupe run plan "how should we split billing" --worktree
troupe resume [SESSION_ID]              # no id: reopen the last session here, picker open
troupe resume latest                    # the newest session here, straight in (--private: the newest private one)
troupe resume ID --headless "go on"     # one turn on that session, printed as run --headless, then exit
troupe --remote [PLANE_URL]             # HQ: teams, profiles and sessions on a plane
```

In VS Code, the extension's **Troupe: Open** runs `troupe --workspace <folder>` in a
terminal at the folder you are working in ([vscode.md](../../docs/user/vscode.md)).

`troupe run --headless` prints the transcript, a line per event prefixed with the agent
that wrote it, the harness's notes among them (`done:` and the summary, a compaction, a
reply cut or empty) and each turn's cost line (`turn: 3 calls · ↑ 300 sent · ...`), and
exits when the agent comes to rest: when its turn ends, whether or not the model called
`finish`. An approval is refused, since nobody is there to answer it: pass
`--auto-approve` for a task that writes files or runs commands, or set `auto_approve`,
which `--auto-approve`, `--watch` and `--full-send` beat only when given. A headless run
starts no librarian: the project brief is refreshed by itself only for a session a person
opens, in a git repository, with a model to ask (`memory_auto_refresh`), and not again
within `memory_max_age_days` of a librarian that built nothing; a session that starts
none, for want of a model, because the daemon did not start it, or while a try is waited
out, says so in one line. The exit code says how the run ended:

| code | the run |
|---|---|
| `0` | ended its turn, or the agent finished |
| `1` | stopped short: the agent ran out of budget, refused, or gave a cut or empty reply; its last model request failed; a tool kept failing and the harness stopped the turn; the agent kept crashing and its session stopped; the turn was cancelled; the session could not start; or the connection to the daemon went and did not come back within a minute. The last line says which, and for a crash what the agent raised |
| `2` | never started: the command line did not parse |
| `3` | was refused an approval, with nobody to ask. Run it again with `--auto-approve`, or `troupe resume` the session to carry on by hand |
| `130` | was interrupted with Ctrl-C |

`troupe resume ID --headless "message"` (or `latest`, or `--private`, in place of the id)
does the same for one turn of a session that already has a history: it prints that turn
alone, its turn line included, and exits with the same codes. `troupe --resume` is
`troupe resume`. A session another device holds (it sealed it last, and it is that
device's until you claim it here), or one that is erased or being erased, is refused in a
sentence that says so and suggests `/new`; a dormant one, asleep or archived, is opened,
and the next line wakes it. The terminal UI needs a terminal: `troupe`, `troupe resume`
and `troupe run` without `--headless`, with standard output sent to a file or a pipe, say
so in one line and exit `1` rather than draw into it.

Inside the TUI every command starts with `/`, and `!cmd` runs a shell command where the
session runs (`!!cmd` keeps it from the agent). Every built-in command is in
[the command reference](../../docs/user/cli-reference.md#inside-a-session), generated
from the harness's table as `troupe --help` is, and `/help`, `/` on an empty line or Ctrl-K
opens the same list as the [command palette](#command-palette). Besides those, each agent
is a command, and so is each command you write:

| command | effect |
|---|---|
| `/build <prompt>` | edit in your checkout (all tools); `/worktree <prompt>` does the same in a worktree of its own, then `/merge` or `/discard` |
| `/workflow <task>` | run the engineering pipeline in a worktree: `orchestrate` delegates every step to a subagent ([workflows](../../docs/user/agents.md#workflows)) |
| `/workflow <name> <task>` | the same, with the steps from `.troupe/workflows/<name>.json` |
| `/plan <prompt>` | investigate and write a task list; read-only |
| `/ask <question>` | answer across finished branches with the cheap model |
| `/<name> [arguments]` | a command you or the repository wrote as `<name>.md` in your config's `commands/` or the workspace's `.troupe/commands/` ([your own commands](../../docs/user/agents.md#your-own-commands)) |

Command mode, the screen with no window activated, lists what waits on you first (the
start's questions, a window's approval or question, in the reserved colour), then a row
per branch (its agent, state, how long it has run, the last line it produced, what it used
and cost) and a row per worktree of the repository (its branch, `↑` ahead of and `↓`
behind the checkout's, the lines `+` added and `−` removed, dirty or clean, whose session
and whether it is alive), under the session's model, goal, watch and budget. The session's
own lines (what its start said, what `!` printed) sit above the branches; its own agent is
listed with them only once it has work of its own (`troupe run`'s task, a loop, a watch
trigger, a session on a plane). Enter on a line starts it on `build` in the checkout, or on
the agent Ctrl-N chose (↑↓ the agents, PgUp/PgDn its instruction, Enter, then `w` a
worktree of its own or `c` the checkout); with nothing typed, Ctrl-N's choice waits for the
task on the command line. On a session on a plane, which runs one agent, a line is said to
it.

### Keys

- **Windows.** `1`–`9`, Enter, or a click on its row or tile activates a window; Esc
  returns to the command line. `xx` (x twice) cancels and removes the window; `dd`
  dismisses a finished one, keeping its worktree. Tab chooses the agent the window runs,
  each with its instruction beside it (`/plan` → Tab, `build` → "go" is plan-then-build;
  the title says which agent runs).
- **Answering.** `y`/`n`/`a` answer an approval (allow / deny / allow for the session).
  Typing and Enter sends input or answers a question; when a question offers options a
  digit picks one (with `multiple`, digits tick and untick and Enter sends the ticked
  set). Alt-Enter or Ctrl-J puts a newline in the box instead of sending.
- **Completing.** Tab on the command line completes command names and the window paths
  for `/merge`, `/discard`, `/cancel` and `/dismiss`; `@file` completes paths.
- **Reading.** `e` opens the turn you are reading, every frame of it, and closes it again;
  Ctrl-Y copies the transcript you are reading to the clipboard.
- **The task list.** `/todo complete <n>`, `/todo cancel <n>` (the task's number in the
  side panel) and `/todo add <text>` edit the activated branch's.
- **Quitting.** Ctrl-C twice, `/quit`, Ctrl-D or Ctrl-Q.

Any other command typed into a window's box runs as it would on the command line, on that
window where it takes one (`/copy`, `/merge`); a line that names no command (`/usr/bin is
missing`) goes to the window's agent. `x` and `d` are double presses because the window
they act in is also where you type: the first press puts the letter in the box, which says
what a second would do, and anything else you type (a reply beginning "do it" or "drop
that") keeps the letter as text.

**Selecting text with the mouse.** Drag across the pane to highlight; releasing the
button copies it, rails and line numbers stripped, and Ctrl-Y copies the selection while
one is up (Esc clears it). Troupe owns the selection because mouse reporting, which makes
tiles clickable and the wheel scroll, takes click-and-drag from the terminal. For the
terminal's own (rectangular blocks, the tiles or the observer), hold your emulator's
modifier (Option on iTerm2 and Terminal.app, Shift on GNOME Terminal, Konsole and most X11
terminals), or turn `mouse` off (`troupe --no-mouse`, or `/settings`); windows are still
`1`–`9`, and the pane still scrolls with PgUp/PgDn, ↑/↓ and End. With nothing selected,
Ctrl-Y and `/copy` copy a whole transcript, which no drag across a scrolling pane can.

### Reading a transcript

A turn shows its answer, not its working ([reading a transcript](../../docs/user/README.md#reading-a-transcript)
says what is common to both clients). Everything rendered from something is a frame on a
surface one step from the terminal's background, with a rail, `▎`, down its left; what you
typed and the notes between turns are not on it. By default (`quiet`) a turn's reasoning,
its calls and the prose between them are one line where they began, above the answer:

```
> fix the failing test
▸ 7 steps · 1 failed · grep, read_file, edit_file · 14s
✗ read_file nope · no such file: nope · 2s
▎ ## Fixed
▎ The parser keeps the last line now.
```

`e` opens the turn you are reading (the last one while the pane follows the tail, the one
at the top of the view when you have scrolled) as `everything` draws it, and `e` again
closes it. `/detail quiet`, `/detail tools` or `/detail everything` sets how much of every
turn is open on this session's screen and draws the history again: `tools` opens each
call's frame and keeps reasoning to its header (`▸ thinking · 12s`), `everything`
collapses nothing. A frame longer than 24 lines shows its first 20 and `… 42 more lines`,
and opening its turn shows the rest in place; a scratchpad document stays a card that
`/scratch` opens.

Replies are rendered as in the desktop app, with these of the terminal's own: nested lists
are indented, each level its own marker (`•` `◦` `▪`); `inline code` and **bold** keep their
emphasis without their markers; code has full syntax highlighting; a `csv`, `tsv` or
`json` block that is not one is shown as written; a file an agent read is numbered source,
its line numbers in their own column. Raw HTML, images, footnotes, and a
table wider than 100 columns are left as written, under a line that says so. The same
colours run through diffs and tool calls, by outcome.

While a turn works, the line under it says what is running, how many and for how long,
after a few words from the theatre: `◐ the actors are powdering their nose — thinking
(00:12)`. The words never repeat within a turn, and are not there when a turn waits on
you, in a window's tile, or in `troupe run --headless`, `troupe bench` or anything
`--json` prints. The design, which the desktop app follows too, is
[docs/design/frames.md](../../docs/design/frames.md).

The activated pane follows the tail until you scroll (PgUp/PgDn, Home/End, ↑/↓ while
nothing is typed, or the wheel); the title says where you are (`↕ 120–150/400 · 12 new`),
and End, scrolling to the bottom, sending input or answering follows again. Tool output
keeps its indentation, tabs included; a tool's header says what came back and how long it
took (`· 300 lines`, `· +3 -1`, `· exit 1 (12 lines) · 4s`), and its frame holds the
output, with the diff for an edit you were asked to approve. Whatever a branch is waiting
on is the last thing in the transcript, diff and all, so it reads at any width. `←`/`→`
switch between the branch's agents so a subagent's transcript can be read; input still
goes to the branch root. With a pane open the window strip shrinks to a tray; clicking the
active tile jumps back to the latest output.

### Colours

The themes are the desktop app's, from the same design tokens: Afterglow by default, or
Signal, Footlight or Limelight, the `theme` setting in `/settings`, which is the desktop
app's appearance setting too, so a theme picked in either is the one both draw in. In
Afterglow cyan is the machine working, and pink is for one thing only, a window that needs
you: its border and title (blinking about once a second; the `blink` setting turns that
off), the approval or question waiting in it, and the status line's count. Each theme
keeps its own reserved colour (Signal's magenta, Footlight's amber, Limelight's lime) for
the same thing. Every window carries the mark in its top right corner, and at the start of
its row in command mode: ◐ ◓ ◑ ◒ turning while its agent works, ◑ in the reserved colour
while it needs you, ⏺ done and not yet read, ○ at rest or not yet asked anything, ✗
failed.

Troupe uses as many colours as the terminal says it has: exact colours where `COLORTERM`
is `truecolor` or `24bit` and in Windows Terminal, the nearest of 256 where `TERM` names
`256color`, the terminal's own sixteen otherwise, and none under `NO_COLOR`. It paints no
background but a frame's, one step from the terminal's own, with exact colours and 256
(with sixteen or none the rail alone marks a frame), so it sits on whatever theme the
terminal has; a light background reported in `COLORFGBG` gets the light values.
`TROUPE_COLORS` overrides what the terminal says: `truecolor`, `256`, `16` or `none`, and
`light` or `dark` (`TROUPE_COLORS=256,light`).

### Tokens and cost

A tile reads `↑4.4k ↓3.1k`: tokens sent and received, the whole session's, `↑` what the
provider billed at close to full price. Input served from its prompt cache is reported
apart, as `cached` in the side panel and the observer's detail, and budgets spend the
billed part, so re-reading a cached prompt does not exhaust `max_input_tokens`. What one
turn cost is said when it ends, its subagents' calls included and `no price` when nothing
prices the model ([what a call costs](../../docs/user/models.md#what-a-call-costs)). The
side panel says it under `This turn`, with the session's totals under `Session` and, once
a limit is near, how near:

```
This turn:
  3 calls · $0.04
  ↑ 300 sent · 3.0k cached
  ↓ 120 received
Session:
  41 calls · $0.61
  ↑ 1.2M sent · 310.0k cached
  ↓ 19.0k received
  ⚠ 82% of input tokens
```

While the next turn runs, `This turn` says `said when it ends`. Below 100 columns there is
no side panel, and the turn's cost is a line under the turn instead: `turn: 3 calls · ↑ 300
sent · 3.0k cached · ↓ 120 received · $0.04`.

### Observer

`/observer` is the overview across branches: every root agent with the subagents it
delegated to nested under it, each with what it is doing now (`thinking`, the tool it is
running, `needs you`), how long it has been at it and what it has spent. The panel beside
the tree details the selected agent: its definition and depth, its branch, whether that
branch is in your checkout or a worktree (and which), the model it called, its task list,
anything it is waiting on, and its recent tool calls. `↑`/`↓` moves, Enter opens that
agent's branch window, Esc goes back.

### Command palette

`/` on an empty command line, Ctrl-K with nothing typed, or `/help` opens a popup listing
every command in sections (Session, Navigate, Workspace, Setup, Agents, one entry per
agent with its description, Custom, the commands you and the repository wrote, with the
file each came from, and Quit), each with a one-line description, and the selected one
explained beside it with an example. Typing filters by name, alias or description (`mer`
narrows to `/merge`); `↑`/`↓` and PgUp/PgDn move; Enter runs the command, or leaves it on
the line when it needs an argument; Tab or Space leave it on the line too, so `/merge 2`
types as it always did; Esc goes back. A command that cannot run now (one that acts on a
window when none is activated, or a local one in a plane session) is shown greyed with the
reason. The list is the daemon's (`commands.list`), so the desktop app shows the same.

### Settings page

`/settings` lists every setting with its value and the file it came from, and help beside
it: what the selected setting does, and the commands, keys and concepts worth knowing.
`↑`/`↓` moves; Enter toggles a boolean, opens a menu (the models, and the provider, each
type saying what else it needs) or edits a value; `s` changes which file a change goes to;
PgUp/PgDn or the wheel scrolls the help; Esc goes back. The page and the desktop app read
and write through the daemon, so they always agree
([settings in both clients](../../docs/user/configuration.md#settings-in-the-desktop-app-and-the-terminal)).
`/models` opens the model menu directly ([models](../../docs/user/models.md#the-models-troupe-can-address)).

Watch mode applies to the running session at once, and so do the theme, blinking and
`transcript detail` (`quiet`, `tools` or `everything`, typed), which the screen draws by
unless `/detail` set this session's own; everything else applies to sessions and branches
started from then on. A change is written by its current name (`models.default`, never the
old `model`). Environment variables still win over every file, so a setting masked by
`TROUPE_MODEL` is saved but not in effect, and the status line says so.

### Watch mode

A comment ending in `AI!` is a change request and starts a `quick` branch; `AI?` is a
question and starts an `answer` branch, which cannot edit; bare `AI` comments are
collected as context. The branch works in the checkout the comment is in, its window opens
as `quick-1` (and so on), and the line under the screen says which file and comment
started it; the session's own agent is told nothing. Both agents run on the cheap model
with few turns, since saving a comment is a cheap gesture and the branch it starts should
be one too. For something heavier, redefine `quick` or `answer` in `.troupe/agents/` or
your own `agents/`, which is what `/quick` starts too.

Anything that writes a file can write a comment, so a branch a comment started asks before
every write, edit and shell command, whatever `auto_approve` says, until you set
`watch_auto_approve: true`. The status line says whether the workspace is watched,
whichever client turned it on, and `/watch` turns it off. On Linux, native watching needs
`inotifywait`; without it Troupe falls back to polling and says so.

### Agents

`/agents` lists the primary agents with where each comes from, its model, its tools,
whether it is read-only, its cap on turns and which windows run it; Enter reads one's
whole instruction. `e` opens it in your editor (`VISUAL`, then `EDITOR`; Notepad or `vi`
without either) and the daemon checks what you saved: refused, the errors are on the page
and your edit is kept for the next `e`; accepted, you pick where it goes, `r` the
repository's `.troupe/agents/` or `m` your own `agents/`, after it says which tools it
would run without asking, and asks again when the save adds one. `c` copies one into the
repository in one key, `n` starts one from a template, `x` deletes a copy and says what
answers to the name after. A bundle's agents, and every agent on a pod, are read-only here
and say where they are changed. What a definition holds, and the built-ins, are on
[agents, commands and workflows](../../docs/user/agents.md).

## Remote sessions

A session can run on a plane, a Troupe deployment, instead of this machine: a *plane* that
knows who you are and hands out sessions, and *workers* that run them. Sign in once per
plane:

```
troupe login https://plane.example
```

It reads the plane's `/.well-known/troupe`, runs the OAuth device flow against the issuer
it names, and prints a code to enter in a browser. The refresh token lands in
`credentials.json` in your config directory ([where](../../docs/user/configuration/files.md)),
readable by your account alone (`0600` on Unix, an ACL naming only you on Windows).
`troupe whoami` says who you are and which teams you are in; `troupe logout` forgets one
plane, `troupe logout --all` every one.

Signed in, `troupe` links the daemon on this machine to you at that plane and hands it the
plane token, when it attaches, a minute before the token runs out and after the daemon
restarted; the daemon keeps it in memory only and seals a
[private session](../../docs/user/README.md#words-you-will-meet) with it (`troupe
--private`, `troupe run --private`). A daemon somebody else linked is left as it is.

`troupe --remote` opens HQ: the teams you are in, the profiles each can run with their
health and free capacity, and the sessions on the plane, with this machine's own in the
same list, labelled `local`. ↑↓ moves, ←/→ or Tab changes column, Enter opens a session,
`n` creates one (profile, source, visibility, prompt) and attaches to it, `r` refreshes.
An open remote session looks exactly like a local one: the same window, transcript,
approvals and keys. What is different:

* **Browsing never wakes anything.** Opening a dormant session reads it; the first thing
  you do (input, an approval, a todo edit, a profile switch) activates it, once, and
  follows the worker it is given.
* **Your input appears before the server has seen it**, and is reconciled when the worker
  accepts it. Someone else's appears when it is queued.
* **What your token does not allow is disabled, with the reason on the input box**: a
  read-only session, or a token with only the `observe` scope.
* **If the plane goes down, attached sessions keep streaming.** HQ says that creating and
  activating are unavailable, and still lists what it knows.
* **`/files` and `/upload`** work against the worker's checkout over the session's mount,
  and refresh themselves when the worker says files changed.

TLS is verified against your operating system's trust store. For a deployment behind a
private CA, `TROUPE_CA_FILE=/path/to/ca.pem` adds it to the trust store, never in place of
it. `mix troupe.remote.smoke` runs login, list, attach and one input against a real
deployment when `TROUPE_REMOTE_URL` is set, and skips itself otherwise.

## Persistence

Every session is an append-only JSONL event log, `sessions/<workspace-hash>/<session-id>/events.jsonl`
in the state directory ([where](../../docs/user/configuration/files.md#what-troupe-keeps-for-itself)).
Agent and window state are folds over that log, so a crash restarts from it and `troupe
resume` continues running branches. Tool calls that started but never completed are run
again on resume (at least once); completed calls are never run twice.

A remote session keeps a journal of the same shape under
`remote/<plane-hash>/<session-id>/events.jsonl`: its transcript survives a restart, and
the highest `seq` in it is the cursor the next subscription resumes from, so reattaching
costs no replay and shows no line twice.

The directory decides what you can come back to: sessions are keyed by a hash of the
workspace path, so `/resume` (or `troupe resume` with no id) lists what *this* directory
has (each session that said something to a model or started a branch, when it was last
touched, its branches and which of them need you or have stopped), and Enter replays the
one you pick into the window you are looking at.

`/new` starts another session in the same directory without leaving the TUI, and the one
you were in carries on: it stays in `/resume`'s list, and `/back` returns to it (and
`/back` again comes back, one step either way). `/new --private` makes a private session,
`/new --remote PROFILE` one on that profile of the plane you are signed in to, and
`/new --branch` a fork of the session on screen: a session whose log starts as a copy of
this one's, so its agent goes on from the conversation as it stands while the first
carries on as it was. In command mode the conversations are the branches', so it is typed
in the branch's window and forks that branch; on the command line it says which window to
open. The new session's command line is where its first line goes.

`troupe`'s own log is `troupe.log` in the same state directory, beside the daemon's
`daemon.log`; `troupe daemon status` prints the directory as `state`. A daemon `troupe`
starts inside itself logs there too.

## Development

The toolchain is pinned in `.tool-versions` / `mise.toml`: Erlang 28.5, Elixir 1.20.4, Zig
0.16.0 (Burrito 1.6 requires exactly that Zig).

```sh
mix deps.get              # the harness apps are path dependencies on ../../apps
mix check                 # compile --warnings-as-errors, format, credo --strict, xref, the generated files' checks, test
scripts/dev [args]        # run the CLI/TUI from source without a build (dev loop)
scripts/build-local       # Burrito binary for this host, installed as ~/.local/bin/troupe
TROUPE_PROVIDER=fake TROUPE_FAKE_SCRIPT="$PWD/fixtures/fake_scripts/smoke.json" \
  troupe run build smoke --headless --auto-approve
```

The harness (`troupe_core`, `troupe_gateway`, `troupe_protocol`) is a path dependency on
`../../apps/`, the umbrella this project sits in, at the same commit: there is no pin to
bump, and a change to the harness is made there, with `PROTOCOL.md` and a decision in
`docs/decisions/`, in the same pull request as the TUI change that needs it. A package
both this project and the umbrella lock must be at one version in both `mix.lock` files;
`elixir scripts/locks-agree.exs` at the repository root checks the ones they share, and CI
runs it. The version is the root `VERSION`. `troupe_core`'s compile cross-compiles the
`reaper` helper for the host, and `TROUPE_REAPER_TARGETS=all` builds every target (the
release does this). Every OS process a session starts runs under reaper, which kills the
whole process tree when its owner dies. `TROUPE_PROVIDER=fake` and `TROUPE_FAKE_SCRIPT`
give a deterministic model; so do `provider: fake` and `fake_script:` in a workspace's
`.troupe/config.yaml`, once the workspace is trusted, which is how the test suite does it.

The harness is the root [ARCHITECTURE.md](../../ARCHITECTURE.md); this client's boundary,
its supervision tree and its remote client are
[architecture.md §6](../../docs/developer/architecture.md#6-the-tui-clientstui); and
[its decisions](../../docs/decisions/tui/README.md) are every deviation from the original
specification.

## Out of scope (for now)

Offering this machine's built-in tools (its files, its shell) to a remote session (a
person's own signed-in MCP servers are offered), a GUI for the remote side (that is
`clients/gui`, beside this directory), a Web UI, multi-node distribution, a resident
assistant or free-text routing at the dispatcher, auto-commit or undo in the user's
checkout, updating itself unasked, code signing and notarisation, and native Windows ARM
builds.
