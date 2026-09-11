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

Linux and macOS:

```sh
curl -fsSL https://github.com/it-minds/troupe/releases/latest/download/install.sh | sh
```

Windows (PowerShell 5.1 or 7):

```powershell
irm https://github.com/it-minds/troupe/releases/latest/download/install.ps1 | iex
```

Both installers verify the artifact against `SHA256SUMS` and abort on
mismatch. Set `TROUPE_RELEASE_URL` to install from a Forgejo release or an
S3-compatible bucket instead. Re-running upgrades in place and keeps the
previous binary for rollback; `install.sh --uninstall [--purge]` /
`install.ps1 -Uninstall [-Purge]` remove the binary, the PATH entry and
Burrito's extracted payload cache (config and state are kept unless purged).

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
```

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

If Troupe has no API key of its own, it reads the providers from opencode's
`~/.config/opencode/opencode.jsonc` (keys also from its `auth.json`) and uses
opencode's `model` as the default, so an existing opencode setup works with no
Troupe config at all. `troupe config` prints what was resolved with keys
masked.

## Use

```
troupe                                  # TUI in the current directory
troupe --watch                          # TUI with watch mode on
troupe run code "make the tests pass" --headless --auto-approve
troupe run plan "how should we split billing" --worktree
troupe resume [SESSION_ID]
troupe --version
```

Inside the TUI, everything starts with `/`:

| command | effect |
|---|---|
| `/code <prompt>` | edit in your checkout (all tools) |
| `/worktree <prompt>` | same, in its own git worktree; then `/merge` or `/discard` |
| `/worktree <name>: <prompt>` | run in a Troupe worktree of that name, created the first time and reused after |
| `/worktree <existing> <prompt>` | run in a worktree you already checked out (Tab completes them); nothing is committed for you |
| `/plan <prompt>` | investigate and write a task list; read-only |
| `/ask <question>` | answer across finished branches with the cheap model |
| `/watch` | toggle AI-comment watch mode |
| `/cancel`, `/dismiss`, `/merge`, `/discard` `[path]` | act on the activated window or the given path |
| `/agents`, `/sessions` | list agents / persisted sessions |
| `/settings`, `/help` | settings page: tweak settings and read the curated help |
| `/models` | pick the default model from every model Troupe detected |
| `/observer` | agent tree: every branch and subagent, its state, worktree and tokens |

Keys: `1`–`9`, Enter, or a mouse click on its tile activate a window; Esc returns to the command line;
`y`/`n`/`a` answer an approval (allow / deny / allow for session); typing +
Enter sends input or answers a question; Tab switches the window's profile
(`/plan` → Tab to `code` → "go" is plan-then-build); `x` cancels; Tab on the command line completes command names and the window paths for `/merge`, `/discard`, `/cancel`, `/dismiss`; `d`
dismisses a finished window; `e` expands tool output; `@file` completes paths;
Ctrl-C twice, `/quit`, Ctrl-D or Ctrl-Q exit. `/todo cancel <id>` and `/todo add <text>` edit the
activated branch's task list.

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
and its timings, `max_branches`) or to branches dispatched from then on (models,
compaction, timeouts, delegation depth), and is written to the config file that
owns it: the project's `.troupe/config.yaml` when the project has one, else the
global `config.yaml`. Environment variables still win over both, so a setting
masked by `TROUPE_MODEL` is saved but not in effect.

### Watch mode

Any comment ending in `AI!` is a change request and spawns a `/code` branch;
`AI?` is a question and spawns a `/plan` branch; bare `AI` comments are
collected as context. On Linux, native watching needs `inotifywait`; without
it Troupe falls back to polling and says so.

### Agents

Agent definitions are markdown files with YAML frontmatter; the filename is
the name and every `primary` one is a command. Project `.troupe/agents/`
overrides the global `agents/` dir which overrides the built-ins (`code`,
`worktree`, `plan`, `ask`, and the subagents `general` and `explore`).

```markdown
---
description: Reviews a diff for security problems
mode: primary
model: cheap
tools: [read_file, grep, list_files, finish]
---
You are a security reviewer...
```

## Persistence

Every session is an append-only JSONL event log under the platform state dir
(`~/.local/state/troupe/sessions/<workspace-hash>/<session-id>/events.jsonl`,
`%LOCALAPPDATA%\troupe` on Windows). Agent and window state are folds over
that log, so crashes restart from it and `troupe resume` continues running
branches. Tool calls that started but never completed are re-run on resume
(at-least-once); completed calls are never executed twice.

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

Web UI, MCP client, multi-node distribution, a resident assistant or free-text
routing at the dispatcher, auto-commit or undo in the user's checkout,
auto-update, code signing and notarization, native Windows ARM builds.
