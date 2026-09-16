---
built_at: 2026-09-11T16:18:03.569038Z
head: 59f3453
files: 137
---

## Overview
Troupe is a local coding-agent harness built in Elixir on OTP (the actor model). It ships as one self-contained Burrito binary per platform (Linux, macOS, Windows) so users need no Erlang/Elixir installed. The root of a session is a dispatcher that spawns independent, supervised branch agents for each command (e.g. `/code fix the failing test`); branches run concurrently and the TUI shows them as tiles. Every session is an append-only JSONL event log; agent and window state are folds over that log, so crashes replay from it and `troupe resume` continues running branches. Zero LLM calls/tokens when idle.

## Layout
- `lib/troupe/` — the full application
  - `lib/troupe.ex` — public client API (`Troupe.run/2`, `Troupe.run/3`, etc.)
  - `lib/troupe/application.ex` — OTP application supervisor (troupe, ui, watch, agents, session)
  - `lib/troupe/cli.ex` — CLI entry point; `cli/runner.ex` — actual CLI logic (Burrito entry, blocks in the UI supervisor)
  - `lib/troupe/session/` — Log (JSONL, single-writer), Approvals, Locks, Branches, Dispatcher (window ledger = fold over log), Watcher, Worktree, Memory, Dispatcher
  - `lib/troupe/agent/` — Spec, Budget, State (fold over agent's own events — replay/live use same function), Prompt, Node (one_for_all), Server (`:gen_statem`)
  - `lib/troupe/agents/` — `agents.ex` (registry), `agents/definition.ex` (YAML frontmatter parsing for agent profiles)
  - `lib/troupe/tools/` — one module per tool (read_file, write_file, edit_file, grep, list_files, shell, diff, remember, todo, read_branch, web_fetch); `Tools` holds allowlists/permissions; inline tools (`finish`, `todo_*`, `ask_user`, `delegate`) run inside Agent.Server
  - `lib/troupe/tool/` — `tool.ex` (base behaviour), `tool/context.ex` (context gathering), `tool/diff.ex` (unified diff output), `tool/runner.ex` (the only module allowed `try/rescue`)
  - `lib/troupe/llm/` — Provider behaviour, Fake (all tests), Anthropic, OpenAI, HTTP client, SSE streaming, Message/Request structs; `llm/catalog.ex` + `catalog/store.ex` for provider catalog resolution
  - `lib/troupe/ui/tui/` — Model (fold over events, rebuildable), View (widgets), Server (`ExRatatui.App`); `ui/headless/printer.ex`; `ui/supervisor.ex` (UI child supervisors)
  - `lib/troupe/watch/` — Backend behaviour, File system backend, Polling backend, Ignore patterns, Markers
  - `lib/troupe/workspace.ex` — Workspace survey, paths, config, settings, memory; `workspace/survey.ex` for directory/file enumeration
  - Supporting modules: `memory.ex` (brief parse/render/add_note), `codec.ex`, `paths.ex`, `event.ex`/`events.ex`, `frontmatter.ex`, `telemetry.ex`, `settings.ex`; `config/` subdirectory with `jsonc.ex` and `opencode.ex` providers; `os/process.ex` (reaper-wrapped OS processes)
- `native/reaper/` — `reaper.zig`: process tree reaper; `Mix.Tasks.Compile.Reaper` in `mix.exs` cross-compiles it
- `priv/agents/` — Built-in agent definitions (markdown + YAML frontmatter): code, plan, ask, explore, general, librarian, worktree
- `test/` — Unit, property, and TUI tests; `test/support/helpers.ex` (`start_session!`, `await_state`, `eventually`), `test/support/tui_helpers.ex` (headless TUI on `CellSession`, `screen_text`, `press`)
- `config/` — `config.exs`, dev, test, prod, runtime configs
- `scripts/dev` — Run CLI/TUI from source without a build
- `scripts/build-local` — Burrito binary for this host → `burrito_out/`
- `.tool-versions` / `mise.toml` — Pinned toolchain: Erlang 28.5, Elixir 1.20.4-otp-28, Zig 0.16.0

## Commands
Pinned in `.tool-versions` / `mise.toml`: Erlang 28.5, Elixir 1.20.4-otp-28, Zig 0.16.0 (Burrito 1.6 pins exactly that). Always run mix through mise:
```sh
mise exec -- mix compile --warnings-as-errors   # zero warnings incl. type warnings is the bar
mise exec -- mix format && mise exec -- mix credo --strict
TROUPE_IDLE_TEST_MS=1000 mise exec -- mix test    # fast loop; without the var the idle test waits 60 s
mise exec -- mix test test/troupe/tui_test.exs    # one file
scripts/dev [args]                                # run the CLI/TUI from source, no build (TROUPE_CLI=1 mix run -- ...)
scripts/build-local                               # Burrito binary for this host -> burrito_out/
```
Rebuild the binary only when the user needs one. After rebuilding the same version, delete Burrito's extracted payload or the old code keeps running: `rm -rf ~/.local/share/.burrito/troupe_erts-*`.

Manual smoke without a model: `TROUPE_PROVIDER=fake TROUPE_FAKE_SCRIPT=fixtures/fake_scripts/smoke.json scripts/dev run code smoke --headless --auto-approve`. Real providers come from `~/.config/troupe/config.yaml`, env (`TROUPE_*`), or opencode's `~/.config/opencode/opencode.jsonc` as a fallback; `scripts.dev config` shows the resolution.

`mix check` is a wrapper that runs compile --warnings-as-errors, format --check-formatted, credo --strict, and test. `TROUPE_REAPER_TARGETS=all` cross-compiles the reaper helper for every target.

## Conventions
- Let it crash everywhere except `Troupe.Tool.Runner`. No `try/rescue` around the agent loop.
- No sync calls between agents or from session actors into agents; agents may call Log/Approvals/Locks.
- Every OS process goes through `Troupe.OS.Process` (reaper). Never `System.cmd` in lib code.
- Persisted event types and data shapes are listed in ARCHITECTURE.md §4.5; adding one means: emit in Server/Dispatcher, fold in `Agent.State` and/or Dispatcher and `UI.TUI.Model`, and note replay implications.
- Tests: `assert_receive` on events, never `Process.sleep` to wait. Scripts for the Fake are keyed by agent path (`"code-1"`); the first dispatch is always `<name>-1`.
- Type checker is the gate: pattern-match structs (`%Config{} = cfg`) before struct updates, avoid `x && y` as a statement.
- `mix format` reflows code, so anchors you remember from writing a file may no longer exist; re-grep before search/replace edits and make scripted edits assert their matches. Python multi-file edit scripts write file by file — an assertion failure mid-script leaves earlier files changed and later ones not.
- CI does not cover non-Linux native runners, `install.ps1` on Windows, and two acceptance items needing a real model (35, 36 in the spec). `feature/` is the user's own git worktree; leave it out of the index.
- Before changing behaviour: read `ARCHITECTURE.md` (contract the code implements) and `DECISIONS.md` (every deviation, numbered; append one line per new deviation). `FINAL_REPORT.md` maps each done item to the test that proves it.

## Notes
- 2026-09-16 code-2: TUI mouse selection (Decision 69) is implemented: TUI.Server holds `selection: %{anchor, cursor, dragging?} | nil` as view state (never a log fold), with both ends as *transcript* coordinates `{visual_row, cell_col}` — absolute wrapped-row index, so scrolling and new output do not move a selection, but a %Resize{} must clear it. `View.pane_point/3`/`pane_edge/2` map screen cells to those coordinates; `Model.split_row/3` splits a wrapped row's segments at two cell columns (never cutting a wide glyph) and `Model.row_slice/3` gives its plain text with rail tags (:gutter/:code_rail/:quote_rail/:linenum) dropped. Row splitting lives in Model, re-tagging with `%Style{modifiers: [:reversed]}` in View.highlight/3, so styling stays in one module. Test helpers: `drag/3`, `drag_to/2`, `mouse_up/3`, `screen_cells/2` in test/support/tui_helpers.ex and `clipboard_path/0`/`capture_clipboard_to/1` in test/support/helpers.ex. When locating text on the drawn screen in a test, convert to cells with `Model.cell_width/1` — rail glyphs like `│` are multi-byte, so byte offsets are not columns.
- 2026-09-16 code-1: TUI mouse: ExRatatui 0.13.1 has no runtime mouse-capture toggle — `mouse_capture:` is only consumed once by `Native.init_terminal/2` (deps/ex_ratatui/native/ex_ratatui/src/terminal.rs:121) and there is no raw-escape passthrough NIF (only `set_terminal_title/1`), so `--no-mouse`/the `mouse` setting can only ever be `:next_run`. crossterm's EnableMouseCapture writes ?1000h ?1002h ?1003h ?1015h ?1006h, i.e. button-event and any-event tracking are already on, so `%Event.Mouse{kind: "drag"|"moved"|"up"}` events already reach `TUI.Server.handle_event/2` (it currently ignores them) — in-app text selection needs no dep change, only `Style{modifiers: [:reversed]}` on the selected segments.
- 2026-09-15 ask-5: `ask_user` questions may carry `options` (list of `%{label, description}`) and `multiple`; all model input is coerced once by `Troupe.Tools.AskUser.normalize/1` (lib/troupe/tools/ask_user.ex) so the `question_asked` event, the Approvals payload, the TUI and the answer text all agree. The normalised map is what gets logged and what the restart path re-registers, so a crash restores the offer from the log. The TUI holds an in-progress multi-select in `state.answer` (`%{call_id, selected}`) — UI-only, never logged — and `Model.pane_blocks/6` takes it as its last argument.
- 2026-09-15 code-2: In `UI.TUI.Server.window_key/3` clause order matters: the `y`/`n`/`a` approval clause matches ANY modifier list, so any new Ctrl-<letter> binding for those letters must be defined above it (Ctrl-Y/copy hit this). Shift-Enter cannot be detected in most terminals — crossterm's unix parser maps a bare `\r` to Enter with no modifiers — so newline-in-input is bound to any-modified Enter plus Ctrl-J (in raw mode `\n` = 0x0A parses as Char('j')+CONTROL, verified in crossterm parse.rs). `Troupe.UI.Clipboard` shells to pbcopy/clip/wl-copy/xclip/xsel via a staged temp file because `OS.Process` gives the reaper the child's stdin; `config :troupe, clipboard_command:` overrides it and config/test.exs points it at /dev/null so tests never touch the real clipboard.
- 2026-09-15 code-1/explore-1: TUI keyboard input: ExRatatui.Event.Key has fields code (string), kind ("press"/"release"/"repeat"), modifiers (list of strings: "shift", "ctrl", "alt", "super", "hyper", "meta"). Currently Troupe only handles Shift+Enter for newline insertion; no Alt/Ctrl modifiers on Enter are distinguished. Mouse capture (`:mouse_capture`) defaults to false. Paste events arrive as ExRatatui.Event.Paste with content field.
- 2026-09-11 code-2: Any primary agent defined in priv/agents/*.md (or project/global .troupe/agents) is automatically dispatchable: `Troupe.dispatch(sid, "<name>", prompt)` and the TUI `/name prompt` command, `/agents` list, tab-completion, and the Help "Dispatching work" section all derive from `Agents.primaries/1`. So adding a new primary agent profile is deep-integrated for free. A primary agent with `isolation: worktree` runs in its own git worktree branch and auto-commits on finish (see Agent.Server.maybe_commit). Worktree-managed branches can be `/merge`d or `/discard`ed from the TUI. Delegation (`delegate` tool) hands subagents the parent's workspace, which for a worktree parent is the worktree path.
- 2026-09-11 code-1: TUI input boxes (command line and window input) accept multiline via Shift-Enter; multiline text renders the box title as `<pasted N lines>` instead of the normal hint (View.command_line/2 in lib/troupe/ui/tui/view.ex). Enter still sends the whole text regardless of newlines; Server has dedicated `window_key(%Key{code: "enter", ...})` / `command_key(...)` shift clauses that append "\n".
- 2026-09-11 worktree-1: TUI input: the ExRatatui runtime emits bracketed paste as `%ExRatatui.Event.Paste{content: text}` (single event, not per-key). TUI.Server's handle_event/2 now handles it: appends to cmd_text (focus :command), win_text (window), or the settings editing field. Test helper `paste/2` in test/support/tui_helpers.ex injects it via ExRatatui.Runtime.inject_event/2.
- 2026-09-11 librarian-2: 2025-06-14: Sync detected major structural changes since head 07202a9 — new top-level modules (Memory, Codec, Paths, Events, Frontmatter, Telemetry, Settings), new UI.Supervisor, LLM.Catalog subdirectory, Tool namespace with runner/context/diff helpers, Workspace.Survey, agents/definition.ex, and config/jsonc.ex & config/opencode.ex. Tool namespace reorganized: remember.ex, web_fetch.ex, todo.ex (was todo_read/todo_write). Session.Memory exists as standalone module. Count now 138 files.
