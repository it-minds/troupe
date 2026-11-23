# The terminal client

`troupe` is the terminal client of the Troupe harness. Every session runs in the troupe
daemon (the `troupe-daemon` on this machine, or, when none is running, the same daemon
started inside `troupe` itself) or on a plane's worker pod, and the TUI speaks to all of
them over [`PROTOCOL.md`](../../PROTOCOL.md): a remote session looks exactly like a local
one. It ships as one self-contained executable per platform (Linux, macOS, Windows) built
with [Burrito](https://github.com/burrito-elixir/burrito); users need no Erlang or Elixir
installed. Every release carries one, `troupe-<version>-<target>` (`.exe` on Windows),
which the installers put on the machine with `--tui` (`-Tui`)
([quick start](../quick-start.md#1-install)), and `troupe update` installs a newer one
([updating](updating.md)). Building it is in [its README](../../clients/tui/README.md).

A session opens in **command mode**: not a chat with an agent, but one screen over
everything the session has going. A line that does not start with `/` is work: Enter starts
the default agent (`build`) on it in your checkout, as a **branch** (a session of its own),
and returns control at once; Ctrl-N chooses the agent instead, with its instruction on
screen, and whether it works in a worktree of its own. `/plan look at the parser` or
`/worktree add rate limiting` start one too. Every branch is a window. Branches run
concurrently; a window that needs you (an approval, a question) blinks; you activate it,
answer, and go back to what you were doing. When nothing is running the harness is truly
idle: no model calls, no tokens.

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
it. Its keys and pages are on [the terminal client's screen](terminal-screen.md), and every
command line and command on [the command reference](cli-reference.md).

## Use

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

## Remote sessions

A session can run on a plane, a Troupe deployment, instead of this machine: a *plane* that
knows who you are and hands out sessions, and *workers* that run them. Sign in once per
plane:

```
troupe login https://plane.example
```

It reads the plane's `/.well-known/troupe`, runs the OAuth device flow against the issuer
it names, and prints a code to enter in a browser. The refresh token lands in
`credentials.json` in your config directory ([where](configuration/files.md)),
readable by your account alone (`0600` on Unix, an ACL naming only you on Windows). The
file is the machine's sign-in, not the terminal's: the desktop app reads and renews the
same token, and whichever program renews it holds `credentials.lock` beside it meanwhile,
so the other spends the renewed token rather than a retired one. `troupe whoami` says who
you are and which teams you are in; `troupe logout` forgets one plane, `troupe logout
--all` every one, for the desktop app as well. What the sign-in gives the daemon is on
[sessions](sessions.md#private-session); a daemon somebody else linked is left as it is.

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
* **A long session opens at its last compaction.** The window starts with that
  compaction's summary, under *Earlier*, and what happened after it. PgUp or Home at the
  top of the window loads the history above it, a page at a time.

TLS is verified against your operating system's trust store. For a deployment behind a
private CA, `TROUPE_CA_FILE=/path/to/ca.pem` adds it to the trust store, never in place of
it.

## Persistence

Every session is an append-only JSONL event log, `sessions/<workspace-hash>/<session-id>/events.jsonl`
in the state directory ([where](configuration/files.md#what-troupe-keeps-for-itself)).
Agent and window state are folds over that log, so a crash restarts from it and `troupe
resume` continues running branches. Tool calls that started but never completed are run
again on resume (at least once); completed calls are never run twice.

The directory decides what you can come back to: sessions are keyed by a hash of the
workspace path, so `/resume` (or `troupe resume` with no id) lists what *this* directory
has (each session that said something to a model or started a branch, when it was last
touched, its branches and which of them need you or have stopped), and Enter replays the
one you pick into the window you are looking at.
