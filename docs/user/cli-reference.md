> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).

> ## Deprecated — kept as an artifact
>
> This page documents the `troupe` terminal client. That client left this repository on
> 2026-09-14: `apps/troupe_tui` and `apps/troupe_ctl` were deleted, the packaged binary
> and its installers with them, and nothing here builds an executable any more. The
> source citations under each section point at files that now exist only in git history
> (`git show 20fe871 -- apps/troupe_ctl` and the tree at that commit).
>
> On 2026-09-21 the terminal client came back to this repository as `clients/tui`
> (Decision 666), rebuilt since as a client of the daemon, and its current documentation
> is [`clients/tui`](../../clients/tui/README.md); the graphical client's is
> [`clients/gui/docs`](../../clients/gui/docs/README.md). This page describes the client as
> it was in `apps/`, and is not brought up to date.
>
> Nothing in this directory is maintained against the code. It is here because the prose
> is worth keeping until the client repository can take it, and for no other reason.

# `troupe` command reference

Every command, flag and exit code of the `troupe` binary, the terminal UI's keys and
slash commands, HQ's keys, and where the binary reads and writes files.

## Synopsis

```
troupe [OPTIONS]                          open the TUI on a new session in the current directory
troupe [OPTIONS] run "TASK"               run one task and exit
troupe [OPTIONS] resume [SESSION_ID]      reopen a session (the newest here, if unnamed)
troupe [OPTIONS] sessions                 list sessions
troupe hq                                 every local session, and everything waiting on you
troupe verify SESSION_ID                  walk a session's hash chain (local daemon)
troupe verify --log PATH                  ... offline, from a log file or a decrypted segment
troupe login PLANE_URL                    log in to a plane
troupe logout [PLANE_URL]                 forget a plane's credentials
troupe admin [--plane URL] ...            administer a plane
troupe mcp [--plane URL]                  serve the plane's admin tools to a model over stdio
troupe daemon [--idle SECONDS]            run the local daemon in the foreground
troupe --version | -v
troupe --help | -h
```

Options may appear before or after the command word.

## Options

| Option | Applies to | Meaning | Default |
|---|---|---|---|
| `-C, --workspace PATH` | local `troupe`, `run`, `resume`, `sessions` | directory to work in | the current directory |
| `-a, --agent NAME` | `troupe`, `run` | locally: the primary agent to start with; with `--remote`: the **profile** to create on | local `build` (or `default_agent` in config); remote: the only granted profile |
| `-w, --watch` | `troupe`, `run` (local) | start with watch mode on; with `--remote` it is not sent to the pod and only labels the header — use `/watch` inside the UI | off |
| `--worktree MODE` | local `troupe`, `run` | `auto`, `never` or `always` | `auto` |
| `--remote` | `troupe`, `run`, `resume`, `sessions` | run on a plane, not on this machine | off |
| `--plane URL` | `--remote`, `admin`, `mcp`, `login`, `logout` | which plane, when logged in to more than one | the most recently logged-in plane |
| `--headless` | `troupe`, `run`, `resume` (local and remote) | render as plain lines instead of a UI | off |
| `--quiet` | headless | print only structure lines, not the model's streamed text | off |
| `--auto-approve` | `troupe`, `run` (local); `--headless` runs (local and remote) | locally the session is created with auto-approve on and a headless client also answers; with `--remote` only the headless client answers, and with the remote terminal UI the flag has no effect | off |
| `--timeout SECONDS` | headless | give up after this long; exit 124 | 1800 |
| `--idle SECONDS` | `daemon` | shut the daemon down after this long with nothing to do | 600 |
| `--log PATH` | `verify` | check a file instead of a live session | — |
| `-v, --version` | — | print `troupe <version>` | — |
| `-h, --help` | — | print usage | — |

An unknown option or command prints `troupe: unknown option --x` (or `unknown
command`), the usage text, and exits 2. `run` without a task and `login` without a URL
are usage errors too.

Sources:
- apps/troupe_ctl/lib/troupe/cli.ex:278-282, 299-308, 403-410, 460-467, 519-534, 568-587, 589-661, 663-704
- apps/troupe_ctl/lib/troupe/ctl/remote.ex:158-170
- apps/troupe_tui/lib/troupe/ui/tui.ex:20-28

## Commands: local

These talk to the daemon on this machine, starting it if needed.

### `troupe`

Create a session in `--workspace` (default `.`) and open the terminal UI on it.
Prints `working in a new worktree on troupe/<slug>: <path>` first when a worktree was
created. Requires a real terminal; otherwise it prints `could not start the terminal
UI` and suggests `troupe run "…" --headless`. Exit code is the UI's (0 on quit).
Session-scoped options: `--agent`, `--watch`, `--worktree`, `--auto-approve`,
`--headless`.

### `troupe run "TASK"`

Create a session, send TASK, follow it until the root agent finishes, archive the
session, exit. Without `--headless` and with a terminal it opens the UI; the archive
still happens on exit.

Exit codes: 0 finished; 1 error, budget exhausted or daemon gone; 124 timeout; 2
usage.

### `troupe resume [SESSION_ID]`

Reattach to SESSION_ID, or to the newest session recorded for this workspace. `no
session to resume in <path>` and exit 1 when there is none. With `--headless` it
follows the session as plain lines instead.

### `troupe sessions`

List sessions recorded for this workspace: `  <id>  <state>  <last_active_at>`.
`No sessions recorded for <path>.` when empty. (Listing can start the daemon; see
[AUDIT.md](../AUDIT.md) §3 finding 19.)

### `troupe hq`

Open HQ against the local daemon. Local only. Prints `this build has no fleet view in
it` (exit 1) in a build without the terminal UI.

### `troupe verify SESSION_ID` / `troupe verify --log PATH`

Walk the hash chain. Exit 0 intact or empty; 1 broken or refused; 2 file unreadable or
no id given. Messages are in [features.md](features.md#verify).

### `troupe daemon`

Run the daemon in the foreground: `troupe daemon listening on <endpoint>`. Never
returns; exits with the daemon. `--idle SECONDS` sets the quiet period. `this build
has no daemon in it` (exit 1) if the binary lacks it.

Sources:
- apps/troupe_ctl/lib/troupe/cli.ex:97-132, 170-242, 383-401, 415-439, 441-458, 475-477
- apps/troupe_ctl/lib/troupe/ui/headless.ex:28-34, 91-99, 244-265
- apps/troupe_tui/lib/troupe/ui/tui.ex:55-64

## Commands: remote

`--remote` applies to exactly four commands: `troupe`, `run`, `resume`, `sessions`.
`hq`, `verify`, `daemon` and `--watch`/`--worktree` are local-daemon concerns. Every
remote command needs a prior `troupe login`.

### `troupe --remote [--agent PROFILE]`

Create a session on PROFILE (or the only profile you have) and open the UI. Prints
`<id> on <plane> (<profile>)` first. `several profiles are available (a, b); name one
with --agent` (exit 1) when ambiguous; `no profiles are granted to your teams on this
plane yet` when none. With `--headless` it follows the session as plain lines and
sends `run`'s task as the first prompt.

### `troupe --remote run "TASK" [--agent PROFILE]`

The same, with TASK as the session's first prompt, and no UI when `--headless`. The
CLI does not archive a remote session; it goes dormant on its own.

### `troupe --remote resume SESSION_ID`

Open an existing session (activating it if dormant) and attach. Without an id the CLI
asks the plane to *create* a session, so name one.

### `troupe --remote sessions`

Every session you may see on the plane: `  <id>  <state>  <profile>  <title or
last_active_at>`.

Errors are prefixed `troupe:`; typical ones: `not logged in to a plane. Run: troupe
login <plane-url>`, `the identity provider refused the refresh (400): … Run: troupe
login <plane>`, `the plane refused session.create: …`, `could not reach wss://…`.

Sources:
- apps/troupe_ctl/lib/troupe/cli.ex:183-186, 249-331
- apps/troupe_ctl/lib/troupe/ctl/remote.ex:38-51, 62-70, 74-86, 103-128, 149-192

## Commands: identity

### `troupe login PLANE_URL`

Device-code login against the plane's identity provider; stores the refresh token;
prints who you are and your teams and profiles. Exit 1 with a `troupe: …` reason on
failure (`this plane does not publish a device authorization endpoint`, `the identity
provider answered 400: …`, `the login code expired before it was used`, `the plane
refused the login (403): …`).

### `troupe logout [PLANE_URL]`

Forget the named plane, or the most recently used one. `Not logged in to anything.` is
exit 0.

Sources:
- apps/troupe_ctl/lib/troupe/cli.ex:134-168
- apps/troupe_ctl/lib/troupe/ctl/login.ex:34-44, 56-73, 126-132, 137-150

## Commands: admin

```
troupe admin [--plane URL] <command> [ARGS]
```

No arguments prints the list (exit 2). Output is the JSON result. Exit 0 success; 1 the
plane refused (`troupe admin: <message>`) or is unreachable; 2 usage or an unreadable
FILE.

| Command | Method | Team admin may run |
|---|---|---|
| `overview` | `admin.overview` | yes |
| `profiles` | `admin.profiles.list` | yes (granted profiles) |
| `profile show NAME` | `admin.profile.get` | no |
| `profile put FILE` | `admin.profile.put` | no |
| `profile check FILE` | `admin.profile.preview` | no |
| `profile delete NAME` | `admin.profile.delete` | no |
| `pod drain WORKER_ID` | `admin.pod.drain` | no |
| `teams` | `admin.teams.list` | yes (own teams) |
| `team enable GROUP` | `admin.team.enable` | no |
| `team update NAME FILE` | `admin.team.update` | own team |
| `team grant NAME PROFILE` | `admin.team.grant` | no |
| `team revoke NAME PROFILE` | `admin.team.revoke` | no |
| `team admin add NAME SUBJECT` | `admin.team.admin.add` | no |
| `team admin remove NAME SUBJECT` | `admin.team.admin.remove` | no |
| `sessions` | `admin.sessions.list` | yes (own teams) |
| `session erase SESSION_ID` | `admin.session.erase` | own team's sessions |
| `bundles CHANNEL` | `admin.bundles.list` | yes |
| `bundle show CHANNEL VERSION` | `admin.bundle.get` | yes |
| `bundle validate FILE` | `admin.bundle.validate` | no |
| `bundle publish CHANNEL FILE` | `admin.bundle.publish` | no |
| `bundle retire CHANNEL VERSION` | `admin.bundle.retire` | no |
| `mcp check URL` | `admin.mcp.check` | yes |
| `audit` | `admin.audit.list` | yes (not team-filtered) |
| `provisioning` | `admin.provisioning.mode` | yes |
| `settings` | `admin.settings.list` | yes |
| `setting set KEY VALUE` | `admin.setting.put` | no |
| `setting reset KEY` | `admin.setting.reset` | no |
| `identity check [GROUP]` | `admin.identity.check` | yes |
| `principal list TEAM` | `admin.principals.list` | own team |
| `principal create TEAM NAME PROFILES` | `admin.principal.create` | own team |
| `principal rotate SUBJECT` | `admin.principal.rotate` | own team |
| `principal disable SUBJECT` | `admin.principal.disable` | own team |
| `trigger list TEAM` | `admin.triggers.list` | own team |
| `trigger put FILE` | `admin.trigger.put` | own team |
| `trigger delete TEAM NAME` | `admin.trigger.delete` | own team |
| `trigger run TEAM NAME` | `admin.trigger.run` | own team |
| `runs TEAM [TRIGGER]` | `admin.runs.list` | own team |

FILE is a path to a JSON object; for `bundle publish` and `bundle validate` it may be
a directory laid out as `agents/*.md`, `skills/<name>/SKILL.md` and `mcp.yaml` or
`mcp.json`. PROFILES is comma-separated. Arguments in `[brackets]` are optional.

### `troupe mcp [--plane URL]`

Bridge stdin/stdout to the plane's `/mcp`. Exit 0 when stdin closes; 1 when not
logged in. Register with `claude mcp add troupe -- troupe mcp`.

Sources:
- apps/troupe_ctl/lib/troupe/ctl/admin.ex:19-74, 84-95, 110-170, 172-197, 284-294, 349-375, 391-397
- apps/troupe_ctl/lib/troupe/ctl/mcp.ex:54-65
- apps/troupe_plane/lib/troupe/plane/admin.ex:930-962 and per-method role checks (see docs/admin/README.md)

## Exit codes (summary)

| Code | When |
|---|---|
| 0 | success; UI quit; `verify` intact or empty; `logout` with nothing stored |
| 1 | a refused or failed command; headless run ended in error or budget exhaustion; daemon or plane unreachable; an unexpected exception (`troupe: <message>`) |
| 2 | usage error; `verify` with no id and no `--log`, or an unreadable file; `troupe admin` with no or bad arguments |
| 124 | headless run timed out |

Sources:
- apps/troupe_ctl/lib/troupe/cli.ex:52-79, 119-132, 479-482
- apps/troupe_ctl/lib/troupe/ui/headless.ex:28-34
- apps/troupe_ctl/lib/troupe/ctl/verify.ex:54-75
- apps/troupe_ctl/lib/troupe/ctl/admin.ex:84-95, 284-294, 391-397

## Terminal UI keys

| Key | Action |
|---|---|
| Enter | send the input line; when an approval popup is open, allow it |
| `y` / `a` / `n` (popup open) | allow / allow this tool for the session / deny |
| Tab | switch between `plan` and `build` |
| Esc | cancel the current turn |
| Up / Down | select an agent in the tree; the transcript follows the selection |
| PageUp / PageDown | scroll the transcript (stops following) |
| End | follow the transcript again |
| F5 | redraw the focused transcript |
| Backspace | delete a character |
| Ctrl-C twice (within 2 s) | quit; the session keeps running |
| paste | appended to the input line |

Discrepancy: README says Enter on an agent row opens its transcript; there is no such
binding. Up/Down already switches the transcript.

## Terminal UI slash commands

Type at the start of the input line and press Enter.

| Command | Action |
|---|---|
| `/plan`, `/build` | switch the primary agent (`profile.switch`) |
| `/cancel` | cancel the current turn |
| `/watch` | toggle watch mode for this workspace; prints the backend (`native`, `poll`, `off`) |
| `/agents` | print the live agent paths |
| `/sessions` | print up to five session ids recorded for this workspace |
| `/connect` | list personal MCP connectors and whether each is offered |
| `/connect NAME` | offer one to this session (a consent prompt follows) |
| `/connect yes`, `/connect no` | answer the consent prompt |
| `/resume` | prints how to resume from the shell (it does not switch sessions) |
| `/help` | list the commands |
| `/quit` | detach; the session keeps running |
| `@AGENT text` | ask the root agent to delegate `text` to subagent AGENT in one call and report back |

An unknown command prints `unknown command /x — try /help`.

Sources:
- apps/troupe_tui/lib/troupe/ui/tui/server.ex:32, 77-148, 259-323, 335-349, 359-442, 494-504
- apps/troupe_tui/lib/troupe/ui/tui/view.ex:83-86
- README.md:96-100

## HQ keys

| Key | Action |
|---|---|
| Up / Down | select an approval |
| `y` or Enter | allow |
| `a` | allow that tool for the session |
| `n` | deny |
| `q` or Ctrl-C | quit |

Sources:
- apps/troupe_tui/lib/troupe/ui/hq/server.ex:102-119
- apps/troupe_tui/lib/troupe/ui/hq/view.ex:66

## Files and paths

| What | Linux / macOS | Windows | Override |
|---|---|---|---|
| Plane credentials (refresh tokens, per plane) | `$XDG_CONFIG_HOME/troupe/credentials.json` (default `~/.config/troupe/credentials.json`), mode 0600 | same rule; `<home>\.config\troupe\credentials.json` when `XDG_CONFIG_HOME` is unset | `TROUPE_CONFIG_HOME` |
| Global config | `$XDG_CONFIG_HOME/troupe/config.yaml` | `%APPDATA%\troupe\config.yaml` | `TROUPE_CONFIG_HOME` |
| Global agent definitions | `<config dir>/agents/*.md` | same | `TROUPE_CONFIG_HOME` |
| Project config and agents | `<workspace>/.troupe/config.yaml`, `<workspace>/.troupe/agents/*.md` | same | — |
| Session logs and blobs (state) | `$XDG_STATE_HOME/troupe/sessions/<workspace-hash>/<session-id>/` (default `~/.local/state/troupe`) | `%LOCALAPPDATA%\troupe\sessions\...` | `TROUPE_STATE_HOME`, or `state_dir` in config |
| Daemon Unix socket | `$XDG_RUNTIME_DIR/troupe/daemon.sock`, else `~/.troupe/run/troupe/daemon.sock` | — | `TROUPE_DAEMON_SOCKET` |
| Daemon loopback-TCP discovery file (host, port, token) | used where a Unix socket is unavailable | `%LOCALAPPDATA%\troupe\daemon.json` (else `$XDG_RUNTIME_DIR`, else `~/.troupe/run`) | — |
| Daemon start-up lock | next to the socket: `daemon.sock.lock`, or `daemon.lock` beside `daemon.json`; stale after 30 s | same | — |
| Personal MCP connectors | `$XDG_CONFIG_HOME/troupe/mcp.json`, else `$HOME/.config/troupe/mcp.json` | `HOME` is usually unset: set `TROUPE_MCP_CONFIG` | `TROUPE_MCP_CONFIG` |
| Which binary starts the daemon | the running `troupe` binary | same | `TROUPE_DAEMON_COMMAND` |

Environment variables the local configuration honours: `TROUPE_PROVIDER`,
`TROUPE_MODEL`, `TROUPE_BASE_URL`, `TROUPE_API_KEY`, `TROUPE_FAKE_SCRIPT`; and, as
fallbacks when no `api_key` is configured, `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`
depending on the provider. Any string in a config file may embed `{env:VAR}`.

Note: the credentials file and the personal MCP file follow the `~/.config` rule on
every platform, while `config.yaml` uses `%APPDATA%` on Windows. Set
`TROUPE_CONFIG_HOME` on Windows to keep them together.

Sources:
- apps/troupe_ctl/lib/troupe/ctl/credentials.ex:17-26, 111-123
- apps/troupe_core/lib/troupe/paths.ex:5-7, 13-16, 34, 42-46, 69-71, 83-91
- apps/troupe_core/lib/troupe/config.ex:59-61, 75-81, 113-124, 139-146
- apps/troupe_core/lib/troupe/agent/definition.ex:11-12
- apps/troupe_protocol/lib/troupe/protocol/endpoint.ex:27-31, 112-130
- apps/troupe_protocol/lib/troupe/protocol/daemon.ex:11-28, 214-225, 234-243
- apps/troupe_tui/lib/troupe/ui/tui/connectors.ex:32-74
- docs/AUDIT.md §1.7 (provider key fallbacks)
