# Troupe — working notes for agents

Troupe is an actor-model coding-agent harness in Elixir with a TUI, packaged
as one Burrito binary per platform. The spec is `elixir-prmpt.md`; read
`ARCHITECTURE.md` (contract the code implements) and `DECISIONS.md` (every
deviation, numbered; append one line per new deviation) before changing
behaviour. `FINAL_REPORT.md` maps each done item to the test that proves it.

## Toolchain and commands

Pinned in `.tool-versions` / `mise.toml`: Erlang 28.5, Elixir 1.20.4-otp-28,
Zig 0.16.0 (Burrito 1.6 pins exactly that). Always run mix through mise:

```sh
mise exec -- mix compile --warnings-as-errors   # zero warnings incl. type warnings is the bar
mise exec -- mix format && mise exec -- mix credo --strict
TROUPE_IDLE_TEST_MS=1000 mise exec -- mix test    # fast loop; without the var the idle test waits 60 s
mise exec -- mix troupe.xref                      # the UI only calls Troupe.Client
TROUPE_REMOTE_URL=https://plane... mise exec -- mix troupe.remote.smoke   # login/list/attach/input against a real deployment; skipped without the var
mise exec -- mix test test/troupe/tui_test.exs    # one file
scripts/dev [args]                                # run the CLI/TUI from source, no build (TROUPE_CLI=1 mix run -- ...)
scripts/build-local                               # Burrito binary for this host -> burrito_out/
```

Rebuild the binary only when the user needs one. After rebuilding the same
version, Burrito's extracted payload has to go or the old code keeps running —
`scripts/build-local` does it, but the dir is platform-specific and is
`~/Library/Application Support/.burrito/troupe_erts-*` on macOS,
`~/.local/share/.burrito/troupe_erts-*` on Linux. A binary that behaves like a
build from before your change is this, not a build failure: check `troupe
config` against `scripts/dev config`.

Manual smoke without a model: `TROUPE_PROVIDER=fake TROUPE_FAKE_SCRIPT=fixtures/fake_scripts/smoke.json scripts/dev run code smoke --headless --auto-approve`.
Real providers come from `~/.config/troupe/config.yaml`, env (`TROUPE_*`), or
opencode's `~/.config/opencode/opencode.jsonc` as a fallback; `scripts/dev config` shows the resolution.

## Layout

- `lib/troupe.ex` client API · `lib/troupe/session/*` Log (JSONL, single writer), Approvals, Locks, Branches, Dispatcher (window ledger = fold over log), Watcher, Worktree
- `lib/troupe/agent/*` Spec, Budget, State (fold over the agent's own events — replay and live use the same function), Prompt, Node (one_for_all), Server (`:gen_statem`)
- `lib/troupe/tools/*` one module per tool; `Tools` holds allowlists/permissions; inline tools (`finish`, `todo_*`, `ask_user`, `delegate`) run inside Agent.Server
- `lib/troupe/llm/*` Provider behaviour, Fake (all tests), Anthropic, OpenAI, SSE/HTTP
- `lib/troupe/client.ex` + `lib/troupe/client/{local,remote}.ex` the **only** thing the UI may call; a session routes to one implementation by id
- `lib/troupe/remote/*` the remote client: Discovery, Auth (device flow), Credentials, Tokens, Socket (`mint_web_socket`), RPC, Plane (one per plane), Worker (one per attached session), Journal (JSONL + cursor), Translate (remote events → local ones), Capability, TLS, Backoff
- `lib/troupe/ui/tui/*` Model (fold over events, rebuildable), View (widgets), Server (`ExRatatui.App`); `ui/hq.ex` the remote HQ page; `ui/headless/printer.ex`; `cli.ex`, `cli/runner.ex` (Burrito entry, blocks in the UI supervisor), `cli/remote.ex` (login/logout/whoami)
- `native/reaper/reaper.zig` + `Mix.Tasks.Compile.Reaper` in `mix.exs`: every OS process runs under reaper
- `test/support/helpers.ex` (`start_session!`, `await_state`, `eventually`), `test/support/tui_helpers.ex` (headless TUI on `CellSession`, `screen_text`, `press`), `test/support/fake_remote.ex` (a plane, workers and an OIDC issuer in this VM, over real HTTP and real WebSocket frames) with `test/support/remote_helpers.ex`

## Rules that matter here

- Let it crash everywhere except `Troupe.Tool.Runner`. No `try/rescue` around the agent loop.
- **Anything under `Troupe.UI` may call `Troupe.Client` and nothing else** in the harness (bar the pure data modules `Config`, `Settings`, `Event`, `LLM.Message`, `Codec`). `mix troupe.xref` reads the BEAM import tables and fails the build otherwise; it is in the `check` alias and in CI.
- A remote session must be indistinguishable from a local one on screen: translate at the edge (`Troupe.Remote.Translate`), never branch on "is this remote?" in the model or the view.
- No sync calls between agents or from session actors into agents; agents may call Log/Approvals/Locks.
- Every OS process goes through `Troupe.OS.Process` (reaper). Never `System.cmd` in lib code.
- Persisted event types and data shapes are listed in ARCHITECTURE.md §4.5; adding one means: emit in Server/Dispatcher, fold in `Agent.State` and/or Dispatcher and `UI.TUI.Model`, and note replay implications.
- Tests: `assert_receive` on events, never `Process.sleep` to wait. Scripts for the Fake are keyed by agent path (`"code-1"`); the first dispatch is always `<name>-1`.
- Type checker is the gate: pattern-match structs (`%Config{} = cfg`) before struct updates, avoid `x && y` as a statement.

## Editing gotchas

`mix format` reflows code, so anchors you remember from writing a file may no
longer exist; re-grep before search/replace edits and make scripted edits
assert their matches. Python multi-file edit scripts write file by file — an
assertion failure mid-script leaves earlier files changed and later ones not.

## What is not verified locally

CI on the non-Linux native runners, `install.ps1` on Windows, and the two
acceptance items that need a real model (35, 36 in the spec). `feature/` in the
repo root is the user's own git worktree; leave it out of the index.
