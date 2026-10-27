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
opens the same list as the [command palette](../../docs/user/terminal-screen.md#command-palette). Besides those, each agent
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

What the screen shows once a session is open, and its keys and pages, are on
[the terminal client's screen](../../docs/user/terminal-screen.md):

- <a id="keys"></a>[Keys](../../docs/user/terminal-screen.md#keys): windows, answering, completing, reading, the task list, quitting, and selecting text with the mouse.
- <a id="reading-a-transcript"></a>[Reading a transcript](../../docs/user/terminal-screen.md#reading-a-transcript): frames, how much of a turn is open, how replies are rendered, scrolling.
- <a id="colours"></a>[Colours](../../docs/user/terminal-screen.md#colours): the themes, the reserved colour, the mark, and how many colours the terminal has.
- <a id="tokens-and-cost"></a>[Tokens and cost](../../docs/user/terminal-screen.md#tokens-and-cost): what a tile and the side panel say a turn and the session used.
- <a id="observer"></a>[Observer](../../docs/user/terminal-screen.md#observer): the overview across branches.
- <a id="command-palette"></a>[Command palette](../../docs/user/terminal-screen.md#command-palette): every command, filtered as you type.
- <a id="settings-page"></a>[Settings page](../../docs/user/terminal-screen.md#settings-page): every setting, its value and the file it came from.
- <a id="watch-mode"></a>[Watch mode](../../docs/user/terminal-screen.md#watch-mode): `AI!`, `AI?` and `AI` comments in saved files.
- <a id="agents"></a>[Agents](../../docs/user/terminal-screen.md#agents): the agent picker, and editing, copying and making agents.
- <a id="artifacts"></a>[Artifacts](../../docs/user/terminal-screen.md#artifacts): what is published for you, by who can see it, opened in the browser or read here.
- <a id="memory"></a>[Memory](../../docs/user/terminal-screen.md#memory): what every new session of yours starts knowing, entry by entry, and your own to change.

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
readable by your account alone (`0600` on Unix, an ACL naming only you on Windows). The
file is the machine's sign-in, not the terminal's: the desktop app reads and renews the
same token, and whichever program renews it holds `credentials.lock` beside it meanwhile,
so the other spends the renewed token rather than a retired one. `troupe whoami` says who
you are and which teams you are in; `troupe logout` forgets one plane, `troupe logout
--all` every one, for the desktop app as well.

`troupe login` links the daemon on this machine to you at that plane there and then and
hands it the plane token, starting the installed `troupe-daemon` where none is running.
Signed in, `troupe` hands the token over again when it attaches, a minute before the token
runs out and after the daemon restarted; the daemon keeps it in memory only and seals a
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
carries on as it was. `/new` and `/new --private` open the agent picker first: Enter starts
the session on the agent chosen, and the first line typed on its command line starts that
agent (`n` there makes a new agent first, and the save comes back to start on it). In
command mode the conversations are the branches', so `--branch` is typed
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
