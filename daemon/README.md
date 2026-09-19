# troupe-daemon

The local harness, as one release per platform. It is `troupe_core`, `troupe_gateway` and
`troupe_protocol` from [`troupe-remote`](https://github.com/it-minds/troupe-remote) — the
same three applications a worker pod runs — pinned to one commit in `mix.exs` and packaged
as a Mix release with the platform's own Erlang runtime inside. The TUI and the desktop
app are clients of it: a session on your machine runs here, speaks
[PROTOCOL.md](https://github.com/it-minds/troupe-remote/blob/main/PROTOCOL.md) over a
Unix socket, loopback TCP or a loopback WebSocket, and emits the same events a pod does.

```
troupe-daemon [run]               serve on this machine until idle or stopped
troupe-daemon status              say whether one is running, and where
troupe-daemon config              the resolved providers and models (keys masked)
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
curl -fsSL https://raw.githubusercontent.com/it-minds/troupe/main/install.sh | sh
```

```powershell
irm https://raw.githubusercontent.com/it-minds/troupe/main/install.ps1 | iex
```

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
| `TROUPE_DAEMON_LOG` | `file` (default: `daemon.log` in the state directory) or `stderr` |
| `TROUPE_LOG_LEVEL` | `debug`, `info`, `warning`, `error` |
| `TROUPE_STATE_HOME`, `TROUPE_CONFIG_HOME` | where sessions and config live |
| `TROUPE_ALLOWED_ORIGINS` | origins admitted at the loopback WebSocket, beyond localhost and the desktop shell |

The daemon is not a distributed Erlang node (`rel/env.sh.eex` sets
`RELEASE_DISTRIBUTION=none`): no name, no `epmd`, no port beyond its own two.

## Building

```sh
cd daemon
mix deps.get            # the harness apps come from troupe-remote by git; a private repo
mix check               # compile --warnings-as-errors, format, credo --strict, test
MIX_ENV=prod mix release troupe_daemon
tar -xzf _build/prod/troupe_daemon-*.tar.gz -C /some/dir
/some/dir/bin/troupe-daemon version
/some/dir/bin/troupe_daemon eval 'IO.puts(Troupe.Version.version())'
```

`zig` must be on the `PATH`: the release step builds the `reaper` helper for the host
triple into the release, and a daemon without it fails every `shell` call.
`TROUPE_HARNESS_GIT=/path/to/troupe-remote` points a local build at a checkout on disk;
`TROUPE_HARNESS_REF` overrides the pinned commit. The pinned commit and its harness
version are the two constants at the top of `mix.exs`; bumping them is how the daemon
picks up a core change. `VERSION` is the daemon's own.

`.github/workflows/release.yml` builds all five targets on native runners for every push
that touches `daemon/`, smokes each (unpack, `version`, `status`, `run`, `status`, `eval`;
Windows: `version` and `status`), and on a `v*` tag attaches the tarballs and `SHA256SUMS`
to the GitHub release. It needs a `HARNESS_TOKEN` repository secret: a fine-grained token
with read access to `it-minds/troupe-remote`'s contents.

[`DECISIONS.md`](DECISIONS.md) says why a release and not a Burrito binary, and the rest.
