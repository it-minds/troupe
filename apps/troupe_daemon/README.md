# troupe-daemon

The local harness, as one release per platform. It is `troupe_core`, `troupe_gateway` and
`troupe_protocol` — the same three applications a worker pod runs, its siblings in this
umbrella — packaged as the `troupe_daemon` Mix release with the platform's own Erlang
runtime inside. The TUI (`clients/tui`) and the desktop app (`clients/gui`) are clients of
it: a session on your machine runs here, speaks [PROTOCOL.md](../../PROTOCOL.md) over a
Unix socket, loopback TCP or a loopback WebSocket, and emits the same events a pod does.

```
troupe-daemon [run]               serve on this machine until idle or stopped
troupe-daemon status              say whether one is running, and where
troupe-daemon config              the resolved providers and models (keys masked)
troupe-daemon config import-opencode   copy opencode's providers into config.yaml
troupe-daemon models [--refresh]  every model this machine can address
troupe-daemon version
```

`troupe-daemon` is a shell wrapper in the release's `bin/`: `run` is the release's
`start`, everything else is `eval` in a second short-lived VM that starts no daemon.
Clients start it themselves: `Troupe.Protocol.Daemon` (Elixir) and the desktop shell find
`troupe-daemon` on the `PATH` and spawn `run` when nothing answers. `run` is idempotent —
a second one on a machine with a daemon already up says where it is and exits 0.

## Install

```sh
curl -fsSLO https://github.com/it-minds/troupe/releases/latest/download/install.sh
sh install.sh
```

```powershell
irm https://github.com/it-minds/troupe/releases/latest/download/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The daemon is always installed. In a terminal the installer asks whether to add the TUI
and the desktop app, shows what it is about to do, and asks before doing it; `--tui` and
`--gui` (`-Tui`, `-Gui`) name them, and `-y` (`-Yes`) asks nothing, installing the daemon
alone when neither is named. The copy attached to a release installs that release.

The Windows release builds the harness's zstd NIF (`ezstd`) from an it-minds fork that
compiles it with Zig ([DECISIONS.md](DECISIONS.md) 5); the release itself needs nothing
beyond what the tarball carries.

The release unpacks to `~/.local/lib/troupe-daemon` (`%LOCALAPPDATA%\Programs\troupe-daemon`)
with `troupe-daemon` linked into `~/.local/bin` (a `.cmd` shim in
`%LOCALAPPDATA%\Programs\troupe`, on the user `PATH`). Both installers verify `SHA256SUMS`,
keep the previous release beside the new one for rollback, and take `--uninstall` /
`-Uninstall`. Releases are at <https://github.com/it-minds/troupe/releases>.

## Configuration

`~/.config/troupe/config.yaml` (`%APPDATA%\troupe\config.yaml` on Windows), then the
project's `.troupe/config.yaml`, then `TROUPE_*`:

```yaml
providers:
  gateway:
    type: anthropic
    base_url: https://gw.example/anthropic/v1
    auth_token: "{env:GW_TOKEN}"
    models:
      claude-opus-5: {id: eu.anthropic.claude-opus-5, context: 400000, max_output: 64000}
models:
  default: gateway/claude-opus-5
  cheap: gateway/claude-haiku-4-5
```

With no key of its own the daemon reuses an opencode installation's providers and default
model. `troupe-daemon config` shows what was resolved; `troupe-daemon models --refresh`
asks every provider what it serves and caches windows and prices in `models.json`.

| variable | meaning |
|---|---|
| `TROUPE_PROVIDER`, `TROUPE_MODEL`, `TROUPE_BASE_URL`, `TROUPE_API_KEY` / `TROUPE_AUTH_TOKEN` | the session-wide provider |
| `TROUPE_DAEMON_IDLE_MINUTES` | exit after this long with nothing running; `0` never (default 10) |
| `TROUPE_SESSION_IDLE_MINUTES`, `TROUPE_SESSION_DETACHED_MINUTES` | when a session goes to sleep, watched and unwatched ([below](#how-long-it-stays-up)) |
| `TROUPE_DAEMON_LOG` | `file` (default: `daemon.log` in the state directory) or `stderr` |
| `TROUPE_LOG_LEVEL` | `debug`, `info`, `warning`, `error` |
| `TROUPE_STATE_HOME`, `TROUPE_CONFIG_HOME` | where sessions and config live |
| `TROUPE_ALLOWED_ORIGINS` | origins admitted at the loopback WebSocket, beyond localhost and the desktop shell |

The daemon is not a distributed Erlang node (`rel/env.sh.eex` sets
`RELEASE_DISTRIBUTION=none`): no name, no `epmd`, no port beyond its own two.

## How long it stays up

A daemon a client started has to go away by itself, and a laptop is not quiet until it
has. A turn that is running — a model call, a tool — is never stopped for it, whether
anybody is attached or not. Below that, each step down has one clock:

| Step | After this long | Set by | Default |
|---|---|---|---|
| a session sleeps, watched | idle or waiting on a person, with a client subscribed to it or in watch mode | `TROUPE_SESSION_IDLE_MINUTES` (`:troupe_core, :session_idle_ms`) | 30 min |
| a session sleeps, unwatched | the same, with nobody watching it | `TROUPE_SESSION_DETACHED_MINUTES` (`:troupe_core, :detached_idle_ms`) | 2 min |
| the daemon exits | no client connected and no session awake | `TROUPE_DAEMON_IDLE_MINUTES` (`:troupe_daemon, :idle_shutdown_ms`) | 10 min |

`0` means never. A session that sleeps stops its tree and keeps its log: the next command
that acts on it — input, an answer, an approval — brings it back, and an approval or a
question it was waiting on is asked again rather than failed, so it can be answered days
later. Reading it (listing, subscribing, its history) wakes nothing. In a session that is
still awake, a call waiting on a person is failed as timed out after the tool's own
timeout, three minutes — one reason an unwatched session sleeps before then.

## Building

From this directory, so that only the harness is compiled:

```sh
cd apps/troupe_daemon
mix test
MIX_ENV=prod mix release troupe_daemon
tar -xzf ../../_build/prod/troupe_daemon-*.tar.gz -C /some/dir
/some/dir/bin/troupe-daemon version
/some/dir/bin/troupe_daemon eval 'IO.puts(Troupe.Version.version())'
```

`zig` must be on the `PATH`: the release step builds the `reaper` helper for the host
triple into the release, and a daemon without it fails every `shell` call. The release is
defined in this directory's `mix.exs`; its runtime configuration is
[`config/runtime.exs`](config/runtime.exs) here, not the platform's, and `rel/` holds its
`env.sh.eex` and `env.bat.eex`. The version is the umbrella's `VERSION`, and so is the
harness's: they are one commit.

`.github/workflows/native.yml` builds the Linux, macOS and Windows targets on native
runners — nightly, for every pre-release and release, and on a pull request that touches
the daemon — and smokes each (unpack, `version`, `status`, `run`, `status`, `eval`; on
Windows `version`, `status` and a zstd round trip in `eval`). A release attaches the
tarballs to the GitHub release with everything else it ships.

[`DECISIONS.md`](DECISIONS.md) says why a release and not a Burrito binary, and the rest.
