# Troupe — final report

Built from `elixir-prmpt.md`. Toolchain: Erlang/OTP 28.5, Elixir 1.20.4, Zig 0.16.0
(pinned in `.tool-versions` and `mise.toml`). Everything below was run on Linux
x86_64 on 2026-09-11; commands are relative to the repository root and use the
pinned toolchain (`mise exec -- mix ...`).

## Done items

Legend: ✅ passes locally with output shown · 📝 written, cannot run on this machine (no CI runners / Windows / real model) · the test file proving an item is given so `mix test <file>` reproduces it.

### Core

| # | item | proof |
|---|------|-------|
| 1 | toolchain, warnings-as-errors, format, credo, 10 green runs | ✅ `elixir --version` → `Elixir 1.20.4 (compiled with Erlang/OTP 28)`; `mix compile --force --warnings-as-errors` (zero warnings, zero type warnings); `mix format --check-formatted`; `mix credo --strict` → "found no issues"; `for i in $(seq 10); do mix test \|\| exit 1; done` → **ALL 10 PASSED** (42 tests incl. 1 property, ~63 s per run) |
| 2 | single-branch loop read→edit→finish | ✅ `test/troupe/core_test.exs` "single-branch loop" |
| 3 | three 500 ms tool calls in <1 s | ✅ `core_test.exs` "three 500ms tool calls" |
| 4 | kill Agent.Server during :acting; rebuilt from log; no completed call runs twice | ✅ `test/troupe/recovery_test.exs` "killing the agent server during :acting" |
| 5 | raising tool → error tool_result, agent pid unchanged | ✅ `core_test.exs` "a tool that raises" |
| 6 | cancel kills shell child + grandchild <1 s by OS pid | ✅ `recovery_test.exs` "cancel during a shell sleep" |
| 7 | SIGKILL the VM → child and grandchild gone <3 s | ✅ `recovery_test.exs` "SIGKILLing the VM" (a second `erl` VM owns the reaper Port and is `kill -9`ed) |
| 8 | max_turns 2 → :budget_exhausted, exactly 2 Fake calls | ✅ `core_test.exs` "budget" |
| 9 | path confinement incl. symlinks and Windows rules | ✅ `test/troupe/workspace_test.exs` (unix on disk; Windows drive/UNC/junction/case rules as pure functions with `os: :windows`) |
| 10 | approvals block until allow; deny readable; needs_input carries agent_path | ✅ `core_test.exs` "approvals" and "allow-for-session" |
| 11 | property test: random interleavings never crash; branches end idle/done | ✅ `test/troupe/property_test.exs` |
| 12 | edit_file keeps CRLF | ✅ `core_test.exs` "edit_file on a CRLF file" |

### Dispatcher and branches

| # | item | proof |
|---|------|-------|
| 13 | four concurrent /code, interleaved Fake streams; one crashing past restart intensity → failed_unread, others finish | ✅ `test/troupe/dispatcher_test.exs` two tests |
| 14 | killing a Node leaves zero live processes under it | ✅ `recovery_test.exs` "killing a branch Node" |
| 15 | truly idle for 60 s: zero Fake calls, no Agent.Node, also with two done_unread windows | ✅ `dispatcher_test.exs` "truly idle" (60 s by default; `TROUPE_IDLE_TEST_MS` shortens it for iteration) |
| 16 | Dispatcher kill: branches keep going, ledger identical | ✅ `dispatcher_test.exs` "dispatcher crash" |
| 17 | resume running / needs_input (same pending call) / done_unread; dismissed stays gone | ✅ `dispatcher_test.exs` "resume restores" |
| 18 | continue a done_unread branch | ✅ `core_test.exs` "continue" |
| 19 | ninth command refused | ✅ `dispatcher_test.exs` "the ninth command" |
| 20 | project override of explore; explore write_file denied; depth cap; delegate description names model aliases | ✅ `test/troupe/definitions_test.exs` two tests |
| 21 | plan rejects write/shell; Tab to code keeps conversation + todo list, code tool set | ✅ `definitions_test.exs` "plan rejects" |
| 22 | two in_progress rejected; window cancel visible in next request | ✅ `definitions_test.exs` "todo" |
| 23 | /ask on cheap alias with read_branch results in the request | ✅ `definitions_test.exs` "/ask" |

### Isolation

| # | item | proof |
|---|------|-------|
| 24 | shared locks: error names the holder, both finish | ✅ `test/troupe/isolation_test.exs` |
| 25 | worktree write invisible in checkout; /merge → merge commit; /discard removes worktree and branch | ✅ `isolation_test.exs` |

### Watch mode

| # | item | proof |
|---|------|-------|
| 26 | AI! → one code branch with file/line/comment + bare AI context; 5 writes in 300 ms → one branch; own edit no retrigger; gitignored ignored; AI? → plan that cannot write — once per backend | ✅ `test/troupe/watch_test.exs` (native `file_system` and `polling`) |

### TUI

| # | item | proof |
|---|------|-------|
| 27 | snapshots: strip with running / needs_input / done_unread / failed_unread, activated pane with transcript + todo list, approval with diff, ask_user question | ✅ `test/troupe/tui_test.exs` "snapshots" (ExRatatui `CellSession` headless buffer) |
| 28 | focus never stolen; Esc, 2, y, Esc | ✅ `tui_test.exs` "focus" |
| 29 | kill TUI mid-stream: branches unaffected, TUI restarts and redraws from log | ✅ `tui_test.exs` "killing the TUI" |
| 30 | 10k deltas over four branches with a slow renderer: no turn-latency increase, bounded mailbox | ✅ `tui_test.exs` "backpressure" |
| — | Decision 52: markdown and syntax-highlighted transcript rendering (segmented lines, code rails, numbered source) | ✅ `test/troupe/tui_scroll_test.exs` (`TUIRichTextTest`) |
| — | Decision 51: every configured model detected (`Config.models/1`), listed by `troupe config`, and pickable from a menu via `/models` | ✅ `test/troupe/settings_test.exs` (`ModelMenuTest`) |
| — | Decisions 45–50: scrolling pane that follows the tail, pre-wrapped rows (no bottom clipping, indentation and tabs kept), full tool results with outcome summaries and diffs, subagent transcripts via ←/→, tray layout, trimmed diff context | ✅ `test/troupe/tui_scroll_test.exs` (`TUIScrollTest`, `TUIModelTextTest`, `TUIPaneRegressionTest`) |

### Packaging

| # | item | proof |
|---|------|-------|
| 31 | CI matrix: five artifacts + SHA256SUMS, per-runner `--version` and headless Fake run through reaper | 📝 `.github/workflows/release.yml` (native runners: ubuntu-24.04, ubuntu-24.04-arm, macos-15-intel, macos-14, windows-2022). Not executable locally; the Linux leg was executed by hand: `MIX_ENV=prod BURRITO_TARGET=linux_x86_64 TARGET_ABI=musl TROUPE_REAPER_TARGETS=all mix release --overwrite` → `burrito_out/troupe_linux_x86_64`; `--version` → `troupe 0.1.0`; `TROUPE_PROVIDER=fake TROUPE_FAKE_SCRIPT=fixtures/fake_scripts/smoke.json troupe run code smoke --headless --auto-approve` wrote `hello.txt` and read it back via `shell` under reaper, exit 0 |
| 32 | Linux binary in clean `ubuntu:24.04` and `alpine:3.20` (no Erlang/Elixir/inotify-tools), watch falls back to polling | ✅ run with podman; both containers: `troupe --version`, headless Fake run wrote `hello.txt`, `shell` result read back, and the line `watch mode: native file watching unavailable (inotifywait not found); using polling` printed. Alpine surfaced that `bash` is absent → `shell` now falls back to `sh` (Decision 30) |
| 33 | warm start to first TUI frame < 2 s; cold extraction time and size reported | ✅ Linux x86_64: first TUI frame **112 ms** after VM start (`TROUPE_TRACE_STARTUP=1` under a pty); `--version` warm **152–174 ms**, cold (first-run extraction + `--version`) **1.0–1.05 s**; binary **18.6 MB**. Other targets: 📝 measured by the CI smoke step ("cold first run" / "warm --version" lines) |
| 34 | installers: install, clean upgrade, uninstall leaving nothing outside config/state, corrupted artifact rejected; `install.sh` in ubuntu:24.04 with a zsh user, `install.ps1` on Windows | ✅ `install.sh` run in a podman `ubuntu:24.04` container with a zsh user against a local HTTP server: install → `--version` OK, PATH line added once to `.zshrc`; re-run → upgrade kept `troupe.previous`; `--uninstall` removed binary, PATH line and Burrito payload cache, left no files outside `~/.config` and `~/.local/state`; corrupted artifact → "checksum mismatch … nothing installed". 📝 `install.ps1` written (same flow, `Get-FileHash`, user PATH) and wired into the Windows CI job; not runnable here |

### Acceptance (manual, real model)

| # | item | status |
|---|------|--------|
| 35 | `troupe run code "make the tests pass" --workspace fixtures/sample_repo --headless --auto-approve` ends green | 📝 fixture in place (`fixtures/sample_repo`, one failing test: `sum/1` subtracts); needs an API key: `TROUPE_API_KEY=… burrito_out/troupe_linux_x86_64 run code "make the tests pass" --workspace fixtures/sample_repo --headless --auto-approve && (cd fixtures/sample_repo && mix test)` |
| 36 | TUI: two /worktree + one /plan streaming concurrently, responsive command line, approval blinks without moving focus, /ask summarizes | 📝 needs a real model and a terminal; the same behaviours are covered with the Fake by items 13, 25, 27, 28, 23 |

## Deviations from the specification

Every deviation and ambiguity resolution is in `DECISIONS.md` (32 entries). The ones that change observable behaviour:

* OTP 28.5 / Elixir 1.20.4 / **Zig 0.16.0** (spec said 0.15.2; Burrito 1.6 hard-pins 0.16.0) — Decisions 1, 2.
* LLM deltas, `agent_state` and notices are published but **not persisted** — Decisions 3, 4.
* A text-only assistant reply is an **implicit `finish`** — Decision 5.
* Finished branches **release their Node**; continue re-spawns it from the log — Decision 6 (required by done item 15).
* Cancel rests the window as `:done_unread` with reason `:cancelled` — Decision 7.
* `file_system`'s own listener process is the one OS process not under reaper — Decision 19.
* Headless mode denies approvals and auto-answers questions — Decision 20.
* `shell` falls back to `sh` without bash — Decision 30.
* Burrito argv read via `:init.get_plain_arguments/0`; CLI blocks in the UI supervisor — Decisions 31, 32.

## Binary size and start times

| target | size | cold first run | warm start | first TUI frame |
|---|---|---|---|---|
| linux_x86_64 (musl ERTS, musl NIF) | 18.6 MB | 1.0–1.05 s (extraction + `--version`) | 152–174 ms (`--version`) | 112 ms after VM start |
| linux_aarch64, macos_x86_64, macos_aarch64, windows_x86_64 | reported by the CI smoke step per runner | — | — | — |

The reaper helper is 13–66 KB per target (`priv/reaper/<target>/`), all five cross-compiled by `mix compile` with `TROUPE_REAPER_TARGETS=all`.

## Known limitations

* Items 31 (other four native runners), 34 (Windows installer run), 35 and 36 (real model) were not executed here; the code and workflow for them exist.
* Windows behaviour (Git-for-Windows bash / pwsh / powershell selection, Job Object reaper, junction and drive-letter confinement) compiles (`x86_64-windows-gnu` reaper) and the pure path rules are unit-tested, but nothing was run on Windows.
* The real providers (`Troupe.LLM.Anthropic`, `Troupe.LLM.OpenAI`) are exercised only through their request encoders and SSE parser paths in review, not against live endpoints in this run; all tests use the Fake.
* `/resume` inside the TUI picks from the sessions of the directory it was opened in and swaps the live session under the window (Decision 65, `session_picker_test.exs`). Sessions of other directories are not offered, and matching is by exact workspace path: a session started in a subdirectory is a separate list.
* The TUI transcript is rendered in Elixir (pre-wrapped `Text.Line`s of tagged segments: markdown structure, inline code and bold, syntect highlighting for fenced blocks and file reads). It is not a full markdown implementation — tables, nested emphasis, links and reference definitions are shown as written, and highlighting stops at 400 lines a block (Decision 52).
* At-least-once re-execution of tool calls that started but never completed is by design (documented in ARCHITECTURE.md §2); a `shell` command that is not idempotent can therefore run twice after a crash mid-call.
* Compaction keeps the last `keep_last_turns` turns and summarizes the rest with the cheap model; unresolved tool calls are always in the kept region because the boundary is chosen at a plain user message.
