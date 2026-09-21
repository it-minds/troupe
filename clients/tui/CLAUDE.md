# Troupe — working notes for agents

Troupe is the terminal client of the troupe daemon: an Elixir TUI, packaged
as one Burrito binary per platform, that runs every session in `troupe_core`
behind `troupe_gateway` — a daemon it embeds when none is running on the
machine, or a plane's worker pod — and talks to over `PROTOCOL.md`. The harness
itself (`troupe_core`, `troupe_gateway`, `troupe_protocol`) is a dependency
pinned to one `it-minds/troupe-remote` commit (`@harness_ref` in `mix.exs`). The spec is `elixir-prmpt.md`; read
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

Manual smoke without a model: put `provider: fake` and `fake_script: <path>` in
the workspace's `.troupe/config.yaml` (the daemon reads the model from the
workspace; a client cannot set the provider), then `scripts/dev run build smoke
--headless --auto-approve`. `test/support/helpers.ex` shows the script shape
(`{"routes": {"root": [steps]}}`). Real providers come from `~/.config/troupe/config.yaml`,
env (`TROUPE_*`), or opencode's `~/.config/opencode/opencode.jsonc` as a
fallback; `scripts/dev config` shows the resolution.

Bumping the harness: change `@harness_ref` in `mix.exs` to the `troupe-remote`
commit, `mise exec -- mix deps.update troupe_core troupe_gateway troupe_protocol`,
commit `mix.lock` with it.


Read skills in the .skills repo

## Layout

- `lib/troupe/client.ex` + `lib/troupe/client/{daemon,remote}.ex` the **only** thing the UI may call; a session routes to one implementation by id. `client/daemon/link.ex` finds or embeds the local daemon (`Troupe.Gateway.Daemon` under `Troupe.Client.Daemons`) and carries fleet calls (`session.list/create`, `agents.list`); each attached session is a `Troupe.Remote.Worker` on the daemon's loopback WebSocket. `client/message.ex` the transcript's content blocks; `settings.ex` the settings page over the core's `Troupe.Config`
- `lib/troupe/remote/*` the remote client: Discovery, Auth (device flow), Credentials, Tokens, Socket (`mint_web_socket`), RPC, Plane (one per plane), Worker (one per attached session), Journal (JSONL + cursor), Translate (remote events → local ones), Capability, TLS, Backoff
- `lib/troupe/ui/tui/*` Model (fold over events, rebuildable), View (widgets), Input (the `{text, cursor}` editor both boxes use), Server (`ExRatatui.App`); `ui/hq.ex` the remote HQ page; `ui/headless/printer.ex`; `cli.ex`, `cli/runner.ex` (Burrito entry, blocks in the UI supervisor), `cli/remote.ex` (login/logout/whoami)
- `lib/troupe/os/process.ex` runs the clipboard and git helpers under the core's reaper (`Troupe.Reaper.path/0`)
- `test/support/helpers.ex` (`start_session!` creates a daemon session whose workspace config names the fake and a script, `say!`, `await_done`, `eventually`), `test/troupe/daemon_client_test.exs` (the embedded daemon end to end), `test/support/tui_helpers.ex` (headless TUI on `CellSession`, `screen_text`, `press`), `test/support/fake_remote.ex` (a plane, workers and an OIDC issuer in this VM, over real HTTP and real WebSocket frames) with `test/support/remote_helpers.ex`

## Rules that matter here

- **Anything under `Troupe.UI` may call `Troupe.Client` and nothing else** in the harness (bar the pure data modules `Config`, `Settings`, `Event`, `Client.Message`, `Codec`). `mix troupe.xref` reads the BEAM import tables and fails the build otherwise; it is in the `check` alias and in CI.
- A remote session must be indistinguishable from a local one on screen: translate at the edge (`Troupe.Remote.Translate`), never branch on "is this remote?" in the model or the view.
- The harness is not edited here. A missing method or event is a `troupe-remote` change (its `PROTOCOL.md`, `DECISIONS.md`), then a pin bump; the TUI's own deviations still go in this repo's `DECISIONS.md`.
- Every OS process goes through `Troupe.OS.Process` (reaper). Never `System.cmd` in lib code.
- A session has one agent, the window `"root"`; a line that does not start with `/` is input to it (Decision 101). Branches inside a session are phase 3.
- Tests: `assert_receive` on events, never `Process.sleep` to wait. A test arranges the fake through the workspace (`start_session!(script: …)`), never by handing the harness a process; a text-only step ends the turn, so helpers append `finish` to it.
- Type checker is the gate: pattern-match structs (`%Config{} = cfg`) before struct updates, avoid `x && y` as a statement.

## Editing gotchas

`mix format` reflows code, so anchors you remember from writing a file may no
longer exist; re-grep before search/replace edits and make scripted edits
assert their matches. Python multi-file edit scripts write file by file — an
assertion failure mid-script leaves earlier files changed and later ones not.

## What is not verified locally

CI on the non-Linux native runners, and the two acceptance items that need a real model
(35, 36 in the spec). The installers live in the `troupe` repository now and install
`troupe-daemon`, not this binary. `feature/` in the
repo root is the user's own git worktree; leave it out of the index.
