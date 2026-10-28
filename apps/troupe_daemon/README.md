# troupe-daemon

The local harness, as one release per platform. It is `troupe_core`, `troupe_gateway` and
`troupe_protocol` — the same three applications a worker pod runs, its siblings in this
umbrella — packaged as the `troupe_daemon` Mix release with the platform's own Erlang
runtime inside. The TUI (`clients/tui`) and the desktop app (`clients/gui`) are clients of
it: a session on your machine runs here, speaks [PROTOCOL.md](../../PROTOCOL.md) over a
Unix socket, loopback TCP or a loopback WebSocket, and emits the same events a pod does.

```
troupe-daemon [run] [--detached]  serve on this machine until idle or stopped; --detached (Windows) with no console
troupe-daemon status              say whether one is running, and where
troupe-daemon stop                stop the one running here, between turns, and wait until it has
troupe-daemon open [--url URL]    start it if need be, and open the web app connected to it
troupe-daemon config              the resolved providers and models (keys masked)
troupe-daemon config --explain [KEY] [--json]   every setting, or KEY's, and which file set it
troupe-daemon config validate [PATH]   check the config files, or one; exits 1 on any problem
troupe-daemon config migrate [--write] [PATH]   show, or make, the rewrite to the current spellings
troupe-daemon config trust [PATH]   let a workspace's own files set the trusted keys; --list shows them
troupe-daemon config untrust [PATH]   take that back
troupe-daemon config import-opencode   copy opencode's providers into config.yaml
troupe-daemon models [--refresh]  what each provider serves; asked again when stale, or now with --refresh
troupe-daemon doctor              check the setup: provider, key, models, daemon, PATH, plane; exits 1 on a failure
troupe-daemon login on|off|status   start at login, or not; status exits 1 when it does not
troupe-daemon version
```

`troupe-daemon` is a shell wrapper in the release's `bin/`: `run` is the release's
`start`, everything else is `eval` in a second short-lived VM that starts no daemon.
Clients start it themselves: `Troupe.Protocol.Daemon` (Elixir) and the desktop shell find
`troupe-daemon` on the `PATH` and spawn `run` when nothing answers. `run` is idempotent —
a second one on a machine with a daemon already up says where it is and exits 0. On
Windows a daemon a client starts runs in a console window of its own, minimised to the
taskbar: closing the terminal it was started from leaves it running, and closing its own
window stops it
([Decision 802](../../docs/decisions/0802-a-started-daemon-has-its-own-console-and-open-asks-the-plane.md)).
One started at login has no window at all: `run --detached` starts the VM detached from
any console, the runtime's own `erl -detached`
([Decision 962](../../docs/decisions/0962-on-windows-the-daemon-started-at-login-runs-detached-from-any-console.md)).

## Install

```sh
curl -fsSLO https://github.com/it-minds/troupe/releases/latest/download/install.sh
sh install.sh
```

```powershell
irm https://github.com/it-minds/troupe/releases/latest/download/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The daemon is always installed. In a terminal the installer asks whether to add the TUI,
the desktop app and the VS Code extension, shows what it is about to do, and asks before
doing it; `--tui`, `--gui` and `--vscode` (`-Tui`, `-Gui`, `-VSCode`) name them, and `-y`
(`-Yes`) asks nothing, installing the daemon alone when none is named. Once the daemon is
in place it asks whether to [start it at login](#start-at-login), Enter meaning no;
`--start-at-login` and `--no-start-at-login` (`-StartAtLogin`, `-NoStartAtLogin`) answer
without the question, and `-y` alone turns nothing on.

The copy attached to a release installs that release, and `TROUPE_VERSION=0.15.0-beta`
names another (with `minisign` installed, none from before 0.13, which were not signed). A
private repository answers `/releases/latest` only to somebody signed in, so there the
installers ask for `TROUPE_VERSION`, and `TROUPE_RELEASE_URL` names a mirror. Each release
at <https://github.com/it-minds/troupe/releases> carries
`troupe-daemon-<version>-<target>.tar.gz`, the `troupe` binaries and one `SHA256SUMS`,
which both installers check every download against before replacing anything (and the
release's signature where minisign is installed, [updating](../../docs/user/updating.md#what-the-signature-proves-and-what-it-does-not)).

The release unpacks to `~/.local/lib/troupe-daemon` (`%LOCALAPPDATA%\Programs\troupe-daemon`)
with `troupe-daemon` linked into `~/.local/bin` (a `.cmd` shim in
`%LOCALAPPDATA%\Programs\troupe`, on the user `PATH`). Both installers keep the previous
release beside the new one for rollback, and take `--uninstall` / `-Uninstall` (with
`--purge` / `-Purge`, the settings and session logs too). The Windows release builds the
harness's zstd NIF (`ezstd`) from an it-minds fork that compiles it with Zig
([the daemon's Decision 5](../../docs/decisions/daemon/0005-windows-is-back-in-the-matrix-on-a-fork-of-ezstd.md));
the release itself needs nothing beyond what the tarball carries.

### Start at login

`troupe-daemon login on` has the daemon start every time you log in, and `login off` takes
that back; `login status` says which. The installers ask the same thing once the daemon
is installed, and so do the first run's questions, in the desktop app and in
`troupe config`; `--uninstall` (`-Uninstall`) runs `login off` before it removes anything
([Decision 818](../../docs/decisions/0818-the-installers-offer-start-at-login-and-uninstall-takes-it-back.md)).
Each platform gets its own per-user entry, and none needs an administrator
([Decision 762](../../docs/decisions/0762-the-daemon-starts-at-login-when-a-person-says-so.md)):

| Platform | The entry |
|---|---|
| Windows | `troupe-daemon.cmd` in your Startup folder (`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup`), which runs `troupe-daemon run --detached`: no window, the daemon's VM detached from any console; `troupe-daemon stop` stops it, its log is `daemon.log` in the state directory, and Task Manager's Startup list shows the entry |
| macOS | a launchd agent, `~/Library/LaunchAgents/com.objective-mj.troupe.daemon.plist` |
| Linux with systemd | a user unit, `~/.config/systemd/user/troupe-daemon.service`, enabled for `default.target` |
| Linux without systemd | an autostart entry, `~/.config/autostart/troupe-daemon.desktop`, which a desktop session starts |

The entry runs `troupe-daemon run` — the one on the `PATH`, as a client finds it — with
`TROUPE_DAEMON_IDLE_MINUTES=0`, so a daemon started at login stays up until you log out
rather than exiting when idle. Turning it on takes effect at the next login and starts
nothing now; turning it off removes the file and stops nothing that is running. An entry
written by an earlier daemon on Windows still opens a minimised console window:
`troupe-daemon login on` again writes the current one.

### The web app

A page in a browser cannot read `daemon.json` or start a program, so `troupe-daemon open`
does both for it: it starts the daemon if none is answering, then opens your browser at
the web app with the loopback WebSocket's port and token after a `#`. The page connects,
takes them off its address bar and keeps them in the browser, so a reload or a new tab
connects again; the token changes every time the daemon starts, and running `open` again
hands over the new one. Nothing printed names the token.

The web app is `--url`'s, or the one the plane the daemon is linked to says it serves (its
`/.well-known/troupe`), or, from a plane that does not say or does not answer, the one at
its `/app/`; `--url` is needed when the daemon is not linked. The
daemon admits that page's origin by itself, as it admits the linked plane's
([Decision 797](../../docs/decisions/0797-troupe-daemon-open-connects-the-web-app.md)); an
upgrade it refuses is a warning in its log, naming the origin. `BROWSER`, where it is set,
is what the address is opened with; on Linux and macOS the browser is given a page that
only you can read, which sends it on, so the token is never on a command line.

## Configuration

The daemon reads the same files as every client: the organisation's defaults, your
`config.yaml`, a project's `.troupe/config.yaml` and `.troupe/config.local.yaml`, then
`TROUPE_*`, merged by key, and what the organisation enforces over all of them; a
project's files set the trusted keys only in a workspace you trust, and a pod's never do.
The layers, every key and the commands above are on
[configuration](../../docs/user/configuration.md), with a gateway's file among the
[examples](../../docs/user/configuration.md#examples); `troupe-daemon models` and its
cache on [models and providers](../../docs/user/models.md).

| variable | meaning |
|---|---|
| `TROUPE_PROVIDER`, `TROUPE_MODEL`, `TROUPE_BASE_URL`, `TROUPE_API_KEY` / `TROUPE_AUTH_TOKEN` | the session-wide provider ([all of them](../../docs/user/configuration.md#the-files)) |
| `TROUPE_DAEMON_IDLE_MINUTES` | exit after this long with nothing running; `0` never (default 10) |
| `TROUPE_SESSION_IDLE_MINUTES`, `TROUPE_SESSION_DETACHED_MINUTES` | when a session goes to sleep, watched and unwatched ([below](#how-long-it-stays-up)) |
| `TROUPE_CLIENT_TOOL_GRACE_SECONDS` | how long a call to a client's own tool waits for that client to come back ([below](#how-long-it-stays-up)) |
| `TROUPE_DAEMON_LOG` | `file` (default: `daemon.log` in the state directory, beside the TUI's `troupe.log`) or `stderr` |
| `TROUPE_LOG_LEVEL` | `debug`, `info`, `warning`, `error` |
| `TROUPE_STATE_HOME`, `TROUPE_CONFIG_HOME` | where sessions and config live |
| `TROUPE_ALLOWED_ORIGINS` | the origins admitted at the loopback WebSocket, in place of localhost, the desktop shell, the linked plane and the pages `open` opened |
| `BROWSER` | what `troupe-daemon open` opens the web app with, in place of the system's default browser |

The daemon is not a distributed Erlang node (`rel/env.sh.eex` sets
`RELEASE_DISTRIBUTION=none`): no name, no `epmd`, no port beyond its own two.

## How long it stays up

A daemon a client started has to go away by itself, and a laptop is not quiet until it
has. This is the whole ladder, from a running turn down to the daemon's exit; each rung
has one clock, and the three modules that keep them (`Troupe.Session.ClientTools`,
`Troupe.Sessions.Index`, `Troupe.Gateway.Idle`) point here rather than saying it again.

| Rung | After this long | Set by | Default |
|---|---|---|---|
| a turn runs | never stopped for it — a model call or a tool, whether anybody is attached or not | | |
| a tool call ends | the tool's own timeout: `shell_timeout_ms` for a shell command and for a client's own tool; the agent cuts any tool a minute after that, three minutes at least | `shell_timeout_ms` ([configuration](../../docs/user/configuration.md#tools)) | 2 min |
| a client's own tool call whose client left is failed | nobody has offered the tool again within the grace, which comes out of the call's timeout; a client back inside it is asked the same call | `TROUPE_CLIENT_TOOL_GRACE_SECONDS` (`:troupe_core, :client_tool_grace_ms`); `0` fails it at once | 60 s |
| a session sleeps, read | never, while a client is subscribed to it by name: a session is not stopped under the person looking at it, and the clocks below start when they leave | | |
| a session sleeps, watched | idle or waiting on a person, with somebody following it but not reading it — a `fleet` subscriber, watch mode | `TROUPE_SESSION_IDLE_MINUTES` (`:troupe_core, :session_idle_ms`) | 30 min |
| a session sleeps, unwatched | the same, with nobody watching it | `TROUPE_SESSION_DETACHED_MINUTES` (`:troupe_core, :detached_idle_ms`) | 2 min |
| the daemon exits | no client connected, no session awake and none offered for steering from another device; never for one started at login ([above](#start-at-login)) | `TROUPE_DAEMON_IDLE_MINUTES` (`:troupe_daemon, :idle_shutdown_ms`) | 10 min |

`troupe-daemon stop` does not wait for the last rung: it asks the daemon running here to
stop between turns, as `troupe update` does, waits while a turn is at work and until
nothing answers, and leaves a daemon a TUI runs inside itself, exiting 1.

`0` means never on the minute clocks. A session that sleeps stops its tree and keeps its
log: the next command that acts on it — input, an answer, an approval — brings it back,
and an approval or a question it was waiting on is asked again rather than failed, so it
can be answered days later. Reading it (listing, subscribing, its history) wakes nothing.
In a session that is still awake, a call waiting on a person is failed as timed out after
the tool's own timeout — one reason an unwatched session sleeps before then. What ended
or was asked while nobody was reading a session is in its `session.list` row as `unseen`
([PROTOCOL.md](../../PROTOCOL.md#sessionlist)), for the client that comes back.

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
the daemon, Linux and Windows only — and smokes each (unpack, `version`, `status`, `run`, `status`, `eval`; on
Windows `version`, `status` and a zstd round trip in `eval`). A release attaches the
tarballs to the GitHub release with everything else it ships.

[The daemon's decisions](../../docs/decisions/daemon/README.md) say why a release and not a
Burrito binary, and the rest.
