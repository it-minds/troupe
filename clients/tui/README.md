# Troupe

Troupe is a local coding-agent harness built all the way down on the actor
model and OTP. It ships as one self-contained executable per platform (Linux,
macOS, Windows) built with [Burrito](https://github.com/burrito-elixir/burrito);
users need no Erlang or Elixir installed.

There is no resident assistant. The root of a session is a **dispatcher**: you
type `/code fix the failing test` or `/worktree add rate limiting`, it spawns
an independent, supervised **branch** for each command and returns control
immediately. Every branch is a window in the TUI. Branches run concurrently;
a window that needs you (an approval, a question) blinks; you activate it,
answer, and go back to what you were doing. When nothing is running the
harness is truly idle: zero LLM calls, zero tokens.

## Install

The TUI binary is built by this repository's release workflow (one Burrito binary per
platform, attached to the tag's GitHub release). Download the one for your platform and
put it on your `PATH`.

The **local daemon** it will stand on — `troupe-daemon`, from the
[`troupe`](https://github.com/it-minds/troupe) repository — has installers of its own:

```sh
curl -fsSL https://raw.githubusercontent.com/it-minds/troupe/main/install.sh | sh
```

```powershell
irm https://raw.githubusercontent.com/it-minds/troupe/main/install.ps1 | iex
```

`troupe daemon status` says whether one is running; `troupe daemon run` starts it.
Today's `troupe` still runs sessions in-process; phase 2 of the daemon plan makes it a
client of the daemon.

### Unsigned binaries

The binaries are not code-signed.

* **macOS Gatekeeper**: downloads made with `curl` carry no quarantine
  attribute and run directly. If you downloaded with a browser, either
  right-click → Open once, or run `xattr -d com.apple.quarantine ~/.local/bin/troupe`.
* **Windows SmartScreen**: the first run may show "Windows protected your PC".
  Click *More info* → *Run anyway*. `Invoke-WebRequest` downloads do not carry
  a Mark-of-the-Web, so the installer itself is unaffected.

## Configure a provider

```yaml
# ~/.config/troupe/config.yaml (Linux/macOS) or %APPDATA%\troupe\config.yaml
provider: anthropic          # anthropic | openai | fake
api_key: sk-ant-...          # or TROUPE_API_KEY / ANTHROPIC_API_KEY
models:
  default: claude-opus-5     # expensive: editing
  cheap: claude-haiku-4-5    # cheap: exploration, synthesis, /ask
max_branches: 8
compaction: {fraction: 0.8, keep_last_turns: 4}
read_roots:                  # extra directories the *read* tools may reach into
  - ~/src/some-dependency
```

`read_roots` widens only reading. `read_file`, `grep`, `list_files` and `glob`
may look inside these directories as well as the workspace, which is what lets
the agent read a dependency's source without shelling out; `write_file` and
`edit_file` are unaffected and can never write outside the workspace root.
Paths are compared after resolving symlinks, so a link out of the workspace
counts as wherever it actually points.

A project `.troupe/config.yaml` overrides keys; environment variables
(`TROUPE_PROVIDER`, `TROUPE_BASE_URL`, `TROUPE_API_KEY`, `TROUPE_MODEL`)
override both. `provider: openai` speaks Chat Completions against any
`base_url` (LiteLLM, vLLM, Mistral, ...).

### Several providers, or reusing opencode

Name providers and address models as `<provider>/<model>`, so the expensive and
the cheap model can live on different gateways:

```yaml
providers:
  portal:
    type: openai                       # openai (default) | anthropic
    base_url: https://llm-gw.example/v1
    api_key: ...
    models: {glm-5.2: {context: 100000}, qwen3.6-35b: {context: 100000}}
  anthropic:
    type: anthropic
    api_key: sk-ant-...
models:
  default: anthropic/claude-opus-5
  cheap: portal/qwen3.6-35b
```

### Behind a gateway

A gateway usually renames the models, and one in front of Anthropic normally
takes a bearer token instead of `x-api-key`. Both are declared per provider, and
each model may carry the effort level and the output cap to ask for:

```yaml
providers:
  lego-anthropic:
    type: anthropic
    base_url: https://api.genai.example.com/anthropic/v1   # /v1 is not doubled
    auth_token: ...                    # Authorization: Bearer (api_key: sends x-api-key)
    models:
      claude-opus-5:                   # the name you address
        id: eu.anthropic.claude-opus-5 # the name that goes on the wire
        context: 400000
        max_output: 64000
        reasoning_effort: medium       # none | minimal | low | medium | high | xhigh
```

`reasoning_effort` goes to an OpenAI-compatible provider verbatim (with
`max_completion_tokens`, which is what a reasoning model wants); for Anthropic it
becomes a thinking budget and raises the output cap to fit. An agent definition's
own `reasoning_effort:` overrides it, and a top-level `reasoning_effort:` (or
`TROUPE_REASONING_EFFORT`) is the fallback when neither says anything. The
session-wide provider takes `auth_token:` too, or `TROUPE_AUTH_TOKEN`.

### MCP servers

[MCP (Model Context Protocol)](https://modelcontextprotocol.io) servers extend
the agent with extra tools — a filesystem, a database, a browser — without
changing how Troupe works. Each server you configure connects at session start,
advertises its tools, and the agent can call them with `y`/`n` approval, just
like `shell` or `web_fetch`. Tools are namespaced `mcp__<server>__<tool>`, so
they never collide with built-in tools.

```yaml
mcp:
  filesystem:                       # stdio server: a subprocess Troupe talks to over stdin/stdout
    command: npx
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    env: {FOO: bar}                 # optional
    cd: /some/dir                   # optional working directory
  remote:                           # SSE server: an HTTP event stream
    url: http://localhost:3001/sse
```

`/mcp` in the TUI shows each server's state (✓ ready, … connecting, ✗ error)
and its tools. A server that fails to start is marked, not fatal — the rest
still work.

If Troupe has no API key of its own, it reads the providers from opencode's
`~/.config/opencode/opencode.jsonc` (keys also from its `auth.json`) and uses
opencode's `model` as the default, so an existing opencode setup works with no
Troupe config at all — `options.baseURL`, `options.apiKey`, `options.authToken`,
and per model `id`, `limit.context`, `limit.output` and
`options.reasoningEffort`. `variants`, `agent` and `permission` are not read;
agents are files (see below). `troupe config` prints what was resolved with keys
masked.

## Use

```
troupe                                  # TUI in the current directory
troupe --watch                          # TUI with watch mode on
troupe --no-mouse                       # TUI without mouse reporting (terminal selection works)
troupe run code "make the tests pass" --headless --auto-approve
troupe run plan "how should we split billing" --worktree
troupe resume [SESSION_ID]              # no id: reopen the last session here, picker open
troupe models [--refresh]               # every model, its window and its price
troupe login PLANE_URL                  # sign in to a Troupe Remote plane (device flow)
troupe logout [PLANE_URL] [--all]       # forget a plane's credentials
troupe whoami [PLANE_URL]               # who the plane says you are, and your teams
troupe --remote [PLANE_URL]             # HQ: teams, profiles and sessions on a plane
troupe --version
```

Inside the TUI, everything starts with `/`:

| command | effect |
|---|---|
| `/code <prompt>` | edit in your checkout (all tools) |
| `/worktree <prompt>` | same, in its own git worktree; then `/merge` or `/discard` |
| `/worktree <name>: <prompt>` | run in a Troupe worktree of that name, created the first time and reused after |
| `/worktree <existing> <prompt>` | run in a worktree you already checked out (Tab completes them); nothing is committed for you |
| `/workflow <task>` | orchestrate the engineering pipeline in a worktree: an expensive orchestrator delegates every step to a subagent |
| `/workflow <name> <task>` | the same, with the steps from `.troupe/workflows/<name>.json` |
| `/plan <prompt>` | investigate and write a task list; read-only |
| `/ask <question>` | answer across finished branches with the cheap model |
| `/watch` | toggle AI-comment watch mode |
| `/cancel [n]` | stop branch `n` and remove it: the window goes, and so does the worktree Troupe made for it |
| `/dismiss`, `/merge`, `/discard` `[n]` | act on the activated window or the one on tile `n` (a path works too) |
| `/agents` | list the agents you can dispatch |
| `/resume`, `/sessions` | this directory's sessions, newest first: Enter switches the window to one (`/resume <n\|ID>` goes straight there) |
| `/settings`, `/help` | settings page: tweak settings and read the curated help |
| `/hq`, `/remote` | HQ: a plane's teams, profiles and sessions, with this machine's own listed alongside |
| `/files` | the session's files, live: Enter opens, ← goes up, `r` reloads |
| `/mcp` | MCP servers: each one's state, tools and errors |
| `/upload <path>` | send a local file into the session's own mount |
| `/models` | pick the default model from every model Troupe detected |
| `/observer` | agent tree: every branch and subagent, its state, worktree and tokens |
| `/copy [n]` | copy the activated transcript (or tile `n`'s) to the system clipboard |

Keys: `1`–`9`, Enter, or a mouse click on its tile activate a window; Esc returns to the command line;
`y`/`n`/`a` answer an approval (allow / deny / allow for session); typing +
Enter sends input or answers a question, and when a question offers options a
digit picks one (with `multiple`, digits tick and untick and Enter sends the
ticked set); Alt-Enter (or Ctrl-J) puts a newline in the box instead of
sending; Tab switches the window's profile
(`/plan` → Tab to `code` → "go" is plan-then-build); `xx` (x twice) cancels and removes the window; Tab on the command line completes command names and the window paths for `/merge`, `/discard`, `/cancel`, `/dismiss`; `dd`
dismisses a finished window, keeping its worktree; `e` expands tool output; Ctrl-Y copies the
transcript you are reading to the clipboard; `@file` completes paths;
Ctrl-C twice, `/quit`, Ctrl-D or Ctrl-Q exit. `/todo cancel <id>` and `/todo add <text>` edit the
activated branch's task list.

`x` and `d` are double presses (`xx`, `dd`) because the window they act in is also where you type:
the first press puts the letter in the input box and the box says what a second one would do, and
anything else you type — a reply beginning "do it" or "drop that" — keeps the letter as text.

Selecting text with the mouse: drag across the pane and Troupe highlights what you cover; releasing
the button copies it to the clipboard, and `Ctrl-Y` copies the selection while one is up (Esc clears
it). Troupe owns the selection because mouse reporting — the thing that makes tiles clickable and the
wheel scroll — takes click-and-drag away from the terminal, and it copies the rows as you see them,
rails and line numbers stripped. For the terminal's own selection (rectangular blocks, selecting from
the tiles or the observer), most emulators let you hold a modifier to bypass mouse reporting (Option
on iTerm2 and Terminal.app, Shift on GNOME Terminal, Konsole and most X11 terminals), or start with
`troupe --no-mouse` / turn the `mouse` setting off in `/settings` — windows are still `1`–`9` and the
pane still scrolls with PgUp/PgDn, ↑/↓ and End. With nothing selected, `Ctrl-Y` and `/copy` copy a
whole transcript, which no drag across a scrolling pane can.

Reading a transcript: replies are rendered rather than printed raw. Headings,
bullets, quotes and rules read as such, `inline code` and **bold** keep their
emphasis without their markers, and a fenced code block gets a rule with its
language on it, a rail down its left and full syntax highlighting. A file an
agent read is shown as numbered source, its line numbers in their own column
and its indentation intact. The same colours run through diffs (green and red)
and tool calls (green, red or amber by outcome).

The activated pane follows the tail until you scroll —
PgUp/PgDn, Home/End, ↑/↓ (while nothing is typed) or the mouse wheel; the
title says where you are (`↕ 120–150/400 · 12 new`) and End (or scrolling to
the bottom, sending input, answering) follows again. Tool output keeps its
indentation, tabs included; a collapsed tool line says what came back
(`· 300 lines`, `· +3 -1`, `· exit 1 (12 lines)`) and `e` opens it in full,
with the diff for an edit you were asked to approve. Whatever a branch is
waiting on is the last thing in the transcript, diff and all, so it can be
read at any width. `←`/`→` switch between the branch's agents so a subagent's
transcript can be read; input still goes to the branch root. With a pane open
the window strip shrinks to a tray; clicking the active tile jumps back to
the latest output.

Tokens are counted sent and received, not as one number: a tile reads
`↑4.4k ↓3.1k`, and `↑` is what the provider billed at close to full price.
Input it served from its prompt cache — most of a long conversation's prompt,
at a fraction of the price — is reported separately, in the activated pane's
side panel (`⟳ 148.0k from cache`) and in the observer's detail. Budgets spend
the billed part, so re-reading a cached prompt does not exhaust
`max_input_tokens`.

### Observer

`/observer` is the overview across branches: every root agent with the
subagents it delegated to, nested under it, each with what it is doing right
now (`thinking`, the tool it is running, `needs you`), how long it has been at
it and what it has spent. The panel beside the tree details the selected agent:
its definition and depth, the branch it belongs to, whether that branch is in
your checkout or a worktree (and which), the model it called, its task list,
anything it is waiting on, and its recent tool calls. `↑`/`↓` moves, Enter opens
that agent's branch window, Esc goes back.

### Models

Troupe detects every model it can address: the ones each provider declares in
`config.yaml`, the ones opencode's config declares, and whatever `models.default`
and `models.cheap` already name. `troupe config` prints the list with each
model's context window, where it came from, and whether a key was found.

`troupe models --refresh` asks the providers themselves what they serve and
caches the answer in `models.json` next to the config, so windows and prices are
theirs rather than typed by hand:

```
  model                                   ctx     $in/$out per Mtok source
  anthropic/claude-opus-5                 1000k   -                 catalog
  portal/glm-5.2                          100k    $1.80/$5.50       yaml      provider says 256k
  portal/qwen3.6-35b                      256k    $0.25/$1.50       catalog     <- cheap
```

A LiteLLM gateway reports windows and prices; Anthropic reports windows only
(it has no pricing endpoint, and an unpriced model reads as unpriced, not free);
a plain OpenAI-compatible server reports whatever it feels like. A window you
wrote in `config.yaml` still wins — the listing just says when the provider
disagrees, which is usually a window that went stale. Refreshing is always
explicit: starting a session reads the cache and never the network.

`/models` opens that list as a menu in the TUI, with the model in use first;
`↑`/`↓` move, Enter picks one and writes it to the config file that owns the
setting, Esc goes back. The last entry types a model by hand for anything the
config does not mention. The cheap model has the same menu on the settings page.

### Settings page

`/settings` (or `/help`) opens a page listing every tweakable setting with its
current value, and a curated help text next to it: what the selected setting
does, plus the commands, keys and concepts worth knowing. `↑`/`↓` moves, Enter
toggles a boolean, opens a menu (the models) or edits a value, PgUp/PgDn or the
wheel scrolls the help, Esc goes back.

A change applies to the running session immediately (`auto_approve`, watch mode
with its timings and profiles, `max_branches`) or to branches dispatched from
then on (models, reasoning effort, compaction, timeouts, delegation depth), and
is written to the config file that
owns it: the project's `.troupe/config.yaml` when the project has one, else the
global `config.yaml`. Environment variables still win over both, so a setting
masked by `TROUPE_MODEL` is saved but not in effect.

### Watch mode

Any comment ending in `AI!` is a change request and spawns a `/quick` branch;
`AI?` is a question and spawns an `/answer` branch; bare `AI` comments are
collected as context. Both profiles run on the cheap model with a small
reasoning budget and few turns, because saving a comment is a cheap gesture and
the branch it starts should be one too. Point them somewhere heavier with
`watch.change_command` / `watch.question_command` (`code` and `plan` are the
obvious ones) when a comment deserves the full treatment.

On Linux, native watching needs `inotifywait`; without it Troupe falls back to
polling and says so.

### Agents

Agent definitions are markdown files with YAML frontmatter; the filename is
the name and every `primary` one is a command. Project `.troupe/agents/`
overrides the global `agents/` dir which overrides the built-ins (`code`,
`worktree`, `plan`, `workflow`, `ask`, the watch-mode pair `quick` and `answer`,
and the subagents `general`, `explore`, `implementer`, `reviewer` and
`librarian`).

A definition's `model:` is `default`, `cheap`, `expensive`, or a model named
outright, and
`reasoning_effort:` (`none` | `minimal` | `low` | `medium` | `high` | `xhigh`,
or a token budget) says how much thinking its turns are worth. That beats what a
provider declares for the model, which beats the global `reasoning_effort`
setting — so a cheap, short-lived profile is not stuck with the budget the same
model uses for a coding branch.

The tools a definition can list are `read_file`, `write_file`, `edit_file`,
`list_files`, `grep`, `shell`, `web_fetch`, `todo_write` / `todo_read`,
`delegate`, `remember`, `ask_user` and `finish` (`tools: all` is everything).
`write_file`, `edit_file`, `shell` and `web_fetch` ask before they run — `y` /
`n` / `a` in the window, or `auto_approve` for the session — and the rest run
unattended; a definition can change either with a `permissions:` block.
`web_fetch` is a GET that returns a URL as text, HTML reduced to readable text
with its links kept, so an agent can read the documentation it is pointed at
instead of guessing; `explore` and `plan` have it as well.

### Workflows

`/workflow <task>` runs an *orchestration* rather than one agent doing
everything. The `workflow` agent is the expensive one — `model: expensive`, and
it cannot write a file, edit a file or run a command. What it does is decide:
it writes the step list as its todo list, hands each step to the subagent that
owns it, judges what comes back, and carries each result into the next step's
prompt. The steps run in its own git worktree, which is committed on `finish`
and reviewed with `/merge` or `/discard`, exactly like `/worktree`.

The bundled pipeline is `understand` (`explore`), `plan` (the orchestrator
itself), `implement`, `test` and `document` (`implementer`), then `verify`
(`reviewer` — it runs the build, tests and lint, reads the diff and reports
problems, but is not allowed to fix them). Those subagents delegate further
themselves, up to `max_delegation_depth`; `/observer` shows the whole tree.

A project defines its own pipelines as `.troupe/workflows/<name>.json`, and
`/workflow <name> <task>` runs one:

```json
[
  {"name": "research", "agent": "explore", "prompt": "Find every call site of ..."},
  {"name": "decide", "prompt": "Pick the approach and write the todo list."},
  {"name": "port", "agent": "implementer", "prompt": "Apply the change ...", "parallel": true},
  {"name": "docs", "agent": "implementer", "prompt": "Update the guide ...", "parallel": true},
  {"name": "verify", "agent": "reviewer", "prompt": "mix test && mix credo --strict"}
]
```

`agent` is the subagent responsible for the step; leave it out and the
orchestrator does that step itself. `parallel` marks steps that may be
delegated in one turn, which runs them concurrently — only do that for steps
that write disjoint files. A file that is missing or does not parse falls back
to the bundled pipeline rather than failing the run.

`models.expensive` is what `model: expensive` resolves to; unset, it is
`models.default`, so the orchestrator still runs on a provider with no premium
tier. Set it in `config.yaml`, on the settings page, or with
`TROUPE_EXPENSIVE_MODEL`.

```markdown
---
description: Reviews a diff for security problems
mode: primary
model: cheap
tools: [read_file, grep, list_files, finish]
---
You are a security reviewer...
```

## Remote sessions

A session can run on a Troupe Remote deployment instead of this machine: a
*plane* that knows who you are and hands out sessions, and *workers* that run
them. Sign in once per plane:

```
troupe login https://plane.example
```

It reads the plane's `/.well-known/troupe`, runs the OAuth device flow against
the issuer it names, and prints a code to enter in a browser. The refresh token
lands in `~/.config/troupe/credentials.json` (`%APPDATA%\troupe` on Windows) as
a file only your account can read — `0600` on unix, an ACL naming only you on
Windows. `troupe whoami` says who you are and which teams you are in;
`troupe logout` forgets one plane, `troupe logout --all` every one.

```
troupe --remote
```

opens HQ: the teams you are in, the profiles each can run with their health and
free capacity, and the sessions on the plane — with this machine's own sessions
in the same list, labelled `local`. ↑↓ moves, ←/→ or Tab changes column, Enter
opens a session, `n` creates one (profile, source, visibility, prompt) and
attaches to it, `r` refreshes. A remote session looks exactly like a local one
once it is open: the same window, transcript, approvals and keys.

What is different, and why:

* **Browsing never wakes anything.** Opening a dormant session reads it; the
  first thing you actually do (input, an approval, a todo edit, a profile
  switch) activates it, once, and follows the worker it is given.
* **Your input appears before the server has seen it**, and is reconciled when
  the worker accepts it. Someone else's input appears when it is queued.
* **What your token does not allow is disabled, with the reason on the input
  box** — a read-only session, or a token with only the `observe` scope.
* **If the plane goes down, attached sessions keep streaming.** HQ says that
  creating and activating are unavailable, and still lists what it knows.
* **`/files` and `/upload`** work against the worker's checkout over the
  session's mount, and refresh themselves when the worker says files changed.

TLS is verified against your operating system's trust store. For a deployment
behind a private CA, `TROUPE_CA_FILE=/path/to/ca.pem` adds it — it is added to
the trust store, never swapped for it.

`mix troupe.remote.smoke` runs login, list, attach and one input against a real
deployment when `TROUPE_REMOTE_URL` is set, and skips itself otherwise.

## Persistence

Every session is an append-only JSONL event log under the platform state dir
(`~/.local/state/troupe/sessions/<workspace-hash>/<session-id>/events.jsonl`,
`%LOCALAPPDATA%\troupe` on Windows). Agent and window state are folds over
that log, so crashes restart from it and `troupe resume` continues running
branches. Tool calls that started but never completed are re-run on resume
(at-least-once); completed calls are never executed twice.

A remote session keeps a journal of the same shape under
`.../remote/<plane-hash>/<session-id>/events.jsonl`: its transcript survives a
restart, and the highest `seq` in it is the cursor the next subscription
resumes from, so reattaching costs no replay and shows no line twice.

The directory decides what you can come back to: sessions are keyed by a hash
of the workspace path, so `/resume` inside the TUI (or `troupe resume` with no
id) lists what *this* directory has — when each session was last touched, its
branches and how they came to rest, and the first prompt as a title — and Enter
replays the one you pick into the window you are already looking at.

## Development

Pinned toolchain in `.tool-versions` / `mise.toml`: Erlang 28.5, Elixir
1.20.4, Zig 0.16.0 (Burrito 1.6 requires exactly that Zig).

```sh
mix deps.get
mix check                 # compile --warnings-as-errors, format, credo --strict, test
scripts/dev [args]        # run the CLI/TUI from source without a build (dev loop)
scripts/build-local       # Burrito binary for this host into burrito_out/
TROUPE_PROVIDER=fake TROUPE_FAKE_SCRIPT=fixtures/fake_scripts/smoke.json \
  burrito_out/troupe_linux_x86_64 run code smoke --headless --auto-approve
```

`mix compile` cross-compiles the `reaper` helper (`native/reaper/reaper.zig`)
for the host; `TROUPE_REAPER_TARGETS=all` builds every target (the release
does this). Every OS process the harness starts runs under reaper, which kills
the whole process tree when its owner dies.

See `ARCHITECTURE.md` for the supervision tree, state machines, message
protocol and failure matrix, and `DECISIONS.md` for every deviation from the
original specification.

## Out of scope (for now)

Offering this machine's tools to a remote session, a GUI for the remote side,
Web UI, multi-node distribution, a resident assistant or free-text
routing at the dispatcher, auto-commit or undo in the user's checkout,
auto-update, code signing and notarization, native Windows ARM builds.
