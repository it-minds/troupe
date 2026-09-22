# Architecture, for someone changing the code

Where things are and which rules the build enforces. The design and its reasons are in
[../../ARCHITECTURE.md](../../ARCHITECTURE.md); the wire is [../../PROTOCOL.md](../../PROTOCOL.md);
runtime configuration is [../admin/configuration.md](../admin/configuration.md).

## 1. Apps and releases

Eight Mix projects under `apps/`. The root `mix.exs` releases four of them as container
images; `apps/troupe_daemon` releases the fifth from its own directory, one build per
platform, so a Windows or macOS runner compiles the harness and nothing of the platform.

| App | What | Umbrella deps |
|---|---|---|
| `troupe_protocol` | the wire (JSON-RPC, events, schemas, errors, tokens) and the contracts plane and workers share: OpenBao, S3, MCP clients, the sealer, `TroupePolicy` and `WorkerProfile` parsing | none |
| `troupe_core` | sessions: agents, tools, providers, the log, the index | protocol |
| `troupe_gateway` | the daemon: transports, connections, subscriptions, scopes, idempotency | core, protocol |
| `troupe_daemon` | the harness and a command line, released as `troupe-daemon` | core, gateway, protocol |
| `troupe_worker` | a worker pod: plane link, sealing, restore, auth, bundles | core, gateway, protocol (plane in tests) |
| `troupe_plane` | the control plane: identity, placement, budgets, `/rpc`, `/mcp`, the console | protocol |
| `troupe_operator` | the Kubernetes reconciler (Bonny) | protocol |
| `troupe_a2a` | the A2A facade | protocol |

| Release | Applications | Packaging |
|---|---|---|
| `troupe_operator`, `troupe_plane`, `troupe_a2a` | protocol + the app | image, `docker/Dockerfile` |
| `troupe_worker` | core, protocol, gateway, worker; `Troupe.Release.build_reapers/1` builds the two Linux `reaper`s | image |
| `troupe_daemon` | the harness | a tarball per platform, `apps/troupe_daemon` |

The clients are outside the umbrella: `clients/tui` is its own Mix project depending on
the three harness apps by path, and `clients/gui` a pnpm workspace depending on nothing
here but the protocol. One `VERSION` versions everything ([build.md §4](build.md#4-version)).

## 2. Boundaries

`mix troupe.boundaries` reads the `imports` chunk of every compiled beam and fails on:

| Rule | Reason in the task |
|---|---|
| `troupe_a2a` calls only `troupe_protocol` | "the A2A facade is a protocol client and gets no private access" |
| `troupe_plane` never calls `troupe_core` or `troupe_gateway` | "the plane does not run agents" |
| `troupe_operator` never calls core, gateway or plane | "the operator holds cluster privileges and has no public surface" |
| `troupe_daemon` calls only protocol, core and gateway | "the daemon is the harness and a command line, and nothing of the platform" |
| `Troupe.Plane.Web.Live.*` calls only `Troupe.Plane.Admin` among `Troupe.Plane.*` | "a LiveView is an admin API client and gets no private access" |

Every cross-app call must also be declared `in_umbrella` in the caller's `mix.exs`.
Test-only reverse dependencies pass because only `lib/` beams are read. The TUI has its own
check, `mix troupe.xref` in `clients/tui`: UI modules call only `Troupe.Client` and pure
data modules, and the whole TUI reaches the harness only through `Troupe.Protocol.{Client,
Daemon,Endpoint}`, `Troupe.Config`, `Troupe.Paths`, `Troupe.Reaper` and
`Troupe.LLM.Catalog.Store` (Decision 673). The Python conformance client in
`apps/troupe_gateway/test/conformance/` is the check that the protocol alone is enough.

The operator and the worker both compose a pod's hostname `<ordinal>-<profile>.<domain>`;
the two cannot share a function across the boundary, and both say so.

## 3. Supervision trees

**Core** (`Troupe.Application`, `one_for_one`): `Troupe.Registry`, `Troupe.Events`
(internal pub/sub), `Troupe.Sessions.Index`, and `Troupe.Sessions`, a `DynamicSupervisor`
of `:transient` sessions. One session (`Troupe.Session`, `rest_for_one`, 3 restarts in
10 s), in dependency order:

```
Session.Log          the log and hash chain; everything persists through it
Session.Approvals    the permission gate
Session.Questions    what the agent asks a person
Session.ClientTools  tools a connected client offered
Session.MCP          the workspace's own MCP servers
[LLM.Fake]           only for provider: fake
Agent.Node           the root agent: Agent.Tasks, Agent.Children, Agent.Server (one_for_all)
Session.Watcher      watch mode; after the agent, so its crash restarts nothing above
Session.Files        fs_changed events
Session.Summary      the summary projection, last on purpose
```

**Daemon** (`Troupe.Gateway.Daemon`, `rest_for_one`, started only under
`TROUPE_DAEMON_AUTOSTART`): `Commands` (idempotency ledger), `Plane` (where the plane is,
if anybody linked one), `Private.Sealers` (a sealer per private session), `Connections`
(one process per client, at most 256), `Listener` (Unix socket or loopback TCP),
`Loopback` (a WebSocket on 127.0.0.1, the only door a browser has) and `Idle`. Sessions
are not in this tree, so the daemon can lose its listener without disturbing an agent.

**Worker** (`Troupe.Worker.Supervisor`, empty unless `TROUPE_WORKER_AUTOSTART`):
`Sessions` (a `Session.Manager` per active session), `Auth`, `Connections`, `MCP`,
`Bundles` (before the link: enrolment claims the bundle hash), `Usage`, `Disk.Watch`,
`Plane.Link` (only with
`TROUPE_PLANE_CONTROL`), and `Harness` — the gateway's `Commands`, `Connections`, a raw
NDJSON `Listener` on 4100 and `Gateway.Web` (Bandit on 4000: `/health/live`,
`/health/ready`, `/v1/socket`).

**Plane** (`Troupe.Plane.Supervisor`, empty unless `TROUPE_PLANE_AUTOSTART`): `Repo`,
`Settings` (5 s cache), PubSub, `Singleton` (a `DynamicSupervisor` for the `:global`
actors: one `Placement` per profile, one `TeamBudget` per team), `Fleet.Sweeper`, the
keepers of the trigger scheduler and the fleet scaler, `Fleet.ReleaseImage` (rewrites
`release` profiles after an upgrade), the control channel's registry, connections and `:gen_tcp`
listener on 4001, `Ledger.Cache`, `Tokens.Credential` (the OpenBao login), the Phoenix
endpoint on 4000, and libcluster when `RELEASE_DISTRIBUTION=name`. The `:global` actors
are why the chart refuses more than one replica without distribution.

**Operator** (`rest_for_one`, under `TROUPE_OPERATOR_AUTOSTART`): `Reconcilers` (one per
resource), `Watch` (Bonny: watch, resync, `Lease` leadership), `Descendants`. **A2A**:
a plane-token cache, the stream registry, and Bandit when autostarted.

## 4. Transports

One JSON-RPC framing, three transports: a Unix socket (NDJSON, mode 0600, authenticated
by file permissions), loopback TCP (NDJSON, a random token in a user-only file; chosen by
*trying* `AF_UNIX`), and WebSocket (one message per text frame): a pod's `/v1/socket`
with a session token whose audience is the pod, and the daemon's loopback WebSocket
published in `daemon.json`. `TROUPE_DAEMON_SOCKET=tcp` forces loopback TCP; any other
value is a socket path. `Troupe.Protocol.Daemon` finds or starts the local daemon —
`TROUPE_DAEMON_COMMAND`, else `troupe-daemon` on the `PATH` — serialising concurrent
starts with an `O_EXCL` lock.

## 5. Where state lives

| State | Where |
|---|---|
| A local session's log | `<state>/sessions/<workspace-hash>/<session-id>/events.jsonl`; `<state>` is `TROUPE_STATE_HOME`, else `$XDG_STATE_HOME/troupe` or `%LOCALAPPDATA%\troupe`; blobs beside it |
| Local config | `TROUPE_CONFIG_HOME`, else `$XDG_CONFIG_HOME/troupe` or `%APPDATA%\troupe`: `config.yaml`, `agents/`, `models.json` |
| The project brief | `<repository root>/.troupe/memory.md` |
| Daemon discovery | `$XDG_RUNTIME_DIR/troupe/daemon.sock`, or `daemon.json` (TCP port and token, loopback WebSocket) |
| A pod's working copies | the `data` volume at `/var/lib/troupe` |
| Sealed sessions | S3 `sessions/<id>/…`, written by workers and by daemons for private sessions |
| Session keys | OpenBao KV v2, `troupe/teams/<team>/…` for pods, `troupe/people/<subject>/…` for a person |
| Index, identity, ledger, audit, settings, triggers | PostgreSQL, never session content |
| `WorkerProfile` (written), `TroupePolicy` (read), `TokenReview` | the plane, through the Kubernetes API |
| Everything in `troupe-w-<profile>` | the operator, server-side apply as `troupe-operator` |

## 6. The TUI (`clients/tui`)

The TUI and its HQ page call one module, `Troupe.Client`, a behaviour with two
implementations routed by session id through `Troupe.Client.Registry`:
`Troupe.Client.Daemon` (the `troupe-daemon` on the machine, or a `Troupe.Gateway.Daemon`
the TUI embeds when none answers, reached over its loopback WebSocket) and
`Troupe.Client.Remote` (a plane and its pods). Both attach a session through the same
`Troupe.Remote.Worker`, so a local session and a pod's look identical on screen. Fleet
calls take an origin, `{:local, workspace}` or `{:remote, plane_url}`.

```
Troupe.Remote.Supervisor (one_for_one)
├── Remote.Tokens        refresh, plane and session tokens
├── Remote.Connections   one Remote.Plane per plane
└── Remote.Sessions      a Remote.Journal (JSONL + cursor) and a Remote.Worker (the WebSocket) per attached session
```

`one_for_one` is the degraded mode: an unreachable plane does not touch attached sessions.
A worker connection subscribes from the journal's cursor + 1; the journal drops a batch it
already has, so a reconnect, `resync_required` or `-32012` all produce the same transcript.
Deltas are coalesced per 33 ms and dropped past 64 KB. `Troupe.Remote.Translate` turns
protocol events into the harness's own at the edge — the model and view never branch on
"is this remote". Browsing opens with `session.open read`; the first activating action
calls `session.open activate` once and reconnects to whatever endpoint comes back.
Merge, discard, watch mode, the brief and settings are local-only and answer a remote
session with a sentence rather than failing silently.

## 7. The GUI (`clients/gui`)

The package layout is in the [GUI README](../../clients/gui/README.md). What its code
settles:

- **The fold is in `@troupe/client`**, a pure function of the event stream, tested without
  a DOM — two clients agreeing is a property of that function. The React layer is an
  adapter over the client's stores and holds nothing. `@troupe/client` has no runtime
  dependencies; every protocol type is an open object, because v1 is additive.
- **The view owns the cursor**; `SessionAttachment` swaps the socket underneath it. On
  `auth.expiring` it mints (`token.mint`) and hands the token over with `auth.refresh` on
  the same socket; on a drop it reconnects with backoff (250 ms to 10 s) and resubscribes
  from the last `seq` it processed.
- **Sign-in**: a browser uses authorization code + PKCE (Entra's `devicecode` endpoint
  sends no CORS headers), with `prompt=select_account` and, for a tenant-scoped Microsoft
  issuer, `domain_hint=organizations`; anything else uses the device grant. Redeeming a
  code is idempotent, and the code comes off the address bar either way. The redirect URI
  is the origin plus the base path with no trailing slash, registered as a single-page
  application.
- **Storage**: the provider's refresh token is the only persisted secret
  (`localStorage` `troupe.auth.refresh:<planeUrl>`, or the desktop shell's credential
  store); the PKCE verifier sits in `sessionStorage` `troupe.auth.pending` between leaving
  and coming back; preferences are `troupe.pref.*`. Plane and pod tokens live in memory.
- **The fleet** is one list from several sources (the plane's `sessions.list`, polled
  every 4 s because the plane does not push, and the daemon), merged by id with the
  daemon's copy winning. A source that fails keeps its last rows and reports an error.
- **An input is shown as queued**, below the stream, until `input_accepted` names its
  command id — never inserted optimistically. Approvals are a sticky panel; the inbox
  opens each waiting session in `read` mode.
- **The base path is baked into the image** (`TROUPE_GUI_BASE`), the Ingress strips it,
  and a GUI mounted at a sub-path prefills the plane URL with its own origin.
- **Design tokens are generated**: `pnpm tokens` writes `tokens.css` and `mark.ts` from
  `docs/design/themes/*.tokens.json` and refuses a theme whose token names differ. Theme
  and mode are `data-theme` and `data-mode` on the root, kept in the browser; Signal is the
  default.

## 8. Things a reader will trip over

- `troupe_protocol` is not "no I/O beyond a socket": it holds the OpenBao, S3 and MCP
  clients and the CRD parsers, because they are contracts the plane and workers both hold.
- `apps/troupe_protocol/test/troupe/policy_test.exs` imports `Troupe.Operator.Fixtures`
  from the operator's test support without declaring the dependency; run the protocol
  suite from the root.
- `troupe_plane`'s `web/live/status.ex` reads its states from `priv/design/statuses.json`,
  which `mix troupe.admin.tokens` writes, not from `docs/design/admin/tokens.json`
  directly: the image build does not see `docs/`.
