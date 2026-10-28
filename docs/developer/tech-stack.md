# Tech stack

Versions are pinned in `.tool-versions`, `mix.lock` and `clients/tui/mix.lock` (which
`scripts/locks-agree.exs` holds to each other), `clients/gui/pnpm-lock.yaml`,
`clients/vscode/pnpm-lock.yaml` and `docker/Dockerfile`; this page says why each thing is
there, as the code's own comments give it.

## Toolchain

| Tool | Why |
|---|---|
| Erlang/OTP 28, Elixir 1.20 | every release; 1.20's type checker is the static analysis, with no Dialyzer |
| Zig 0.16 | builds the `reaper` (and Burrito pins exactly this version for the TUI) |
| Node 24, pnpm | the GUI workspace |
| Rust, Tauri 2 | the desktop app's shell |
| Python 3 | the stdlib-only protocol conformance client in the gateway's tests |
| Docker, kind, kubectl, helm | images, and the only local path to a plane and a worker |

## Elixir dependencies

| Library | Where | Reason |
|---|---|---|
| `phoenix`, `phoenix_html` | plane | the endpoint around the API's `Plug.Router`: the listener's configuration, static files and the error page, which Phoenix encodes with `Phoenix.HTML.Engine`. The console that was a LiveView here is an app of its own |
| `bandit`, `plug`, `websock_adapter` | plane, gateway, a2a | one HTTP server across the umbrella; the pod's WebSocket |
| `mint_web_socket`, `req` | protocol and clients | the client side of the WebSocket on the HTTP stack already underneath `req`; `req` for OpenBao, S3, the plane |
| `ecto_sql`, `postgrex` | plane | the index, ledger, audit trail, identity, settings — never session content |
| `libcluster` | plane | replicas find each other through the Kubernetes API (`mode: :ip`, pod lookup) |
| `oidcc` | plane | a plain OIDC relying party |
| `k8s`, `bonny` | plane, operator | `TokenReview` and writing `WorkerProfile`; Bonny's watch-and-reconcile (spiked on 1.20 / OTP 28 first) |
| `jose` | protocol, plane | JWT shapes both sides see; the plane signs through OpenBao and holds no private key |
| `aws_signature` | protocol | SigV4 only, over `req`, rather than an S3 client with its own HTTP stack |
| `ezstd` | protocol | segments are zstd JSONL; the it-minds fork builds on Windows |
| `yaml_elixir`, `ymlr` | `yaml_elixir`: protocol, core, operator, plane, TUI; `ymlr`: plane | agent and skill frontmatter; GitOps manifests |
| `file_system` | core | the native watch backend (`inotifywait`, `mac_listener`) |
| `ex_ratatui`, `burrito` | TUI | the terminal UI (Rust ratatui through NIFs); one executable per platform |
| `jason`; `telemetry`, `stream_data`; `credo` | `jason` everywhere; `telemetry` and `stream_data` in core, gateway and the TUI; `credo` at the root and in the TUI | JSON; `:telemetry` events, which only the live bench attaches to; property tests; the lint |

## Binaries a session uses

| Binary | Why |
|---|---|
| `reaper` | every OS process Troupe starts runs under it, owned by a Port, so killing the VM kills the whole process tree — no cleanup code on the Elixir side can be relied on when the VM dies outright |
| `bubblewrap` | on a pod every command Troupe starts runs in a mount namespace, `shell`'s built from the same mount table the file tools check, and a pod that cannot start one runs no command (Decision 832); worker image only |
| `git` | worktrees, and a worker cloning a source; worker image only |
| `inotifywait` | the native watch backend on Linux, which `fs_changed` and watch mode use; installed in the worker image, polled for where it is missing or will not run |
| `ripgrep` | `grep` uses it when it is on the `PATH`, and a built-in scan when not |

The services the plane and workers talk to, and what each must provide, are in
[../admin/integrations.md](../admin/integrations.md).
