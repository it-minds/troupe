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
- 2026-09-11 worktree-1: TUI input: the ExRatatui runtime emits bracketed paste as `%ExRatatui.Event.Paste{content: text}` (single event, not per-key). TUI.Server's handle_event/2 now handles it: appends to cmd_text (focus :command), win_text (window), or the settings editing field. Test helper `paste/2` in test/support/tui_helpers.ex injects it via ExRatatui.Runtime.inject_event/2.
- 2026-09-11 librarian-2: 2025-06-14: Sync detected major structural changes since head 07202a9 — new top-level modules (Memory, Codec, Paths, Events, Frontmatter, Telemetry, Settings), new UI.Supervisor, LLM.Catalog subdirectory, Tool namespace with runner/context/diff helpers, Workspace.Survey, agents/definition.ex, and config/jsonc.ex & config/opencode.ex. Tool namespace reorganized: remember.ex, web_fetch.ex, todo.ex (was todo_read/todo_write). Session.Memory exists as standalone module. Count now 138 files.
