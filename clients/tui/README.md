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
| `/plan <prompt>` | investigate and write a task list; read-only |
| `/ask <question>` | answer across finished branches with the cheap model |
| `/watch` | toggle AI-comment watch mode |
| `/cancel`, `/dismiss`, `/merge`, `/discard` `[path]` | act on the activated window or the given path |
| `/agents`, `/sessions` | list agents / persisted sessions |

Keys: `1`–`9` or Enter activate a window; Esc returns to the command line;
`y`/`n`/`a` answer an approval (allow / deny / allow for session); typing +
Enter sends input or answers a question; Tab switches the window's profile
(`/plan` → Tab to `code` → "go" is plan-then-build); `x` cancels; `d`
dismisses a finished window; `e` expands tool output; `@file` completes paths;
Ctrl-C twice, `/quit`, Ctrl-D or Ctrl-Q exit. `/todo cancel <id>` and `/todo add <text>` edit the
activated branch's task list.

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
