# Architecture, for someone changing the code

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).

This document says where things are and which rules the build enforces. Data flows and
the reasons behind the design are in [../whitepaper.md](../whitepaper.md); runtime
configuration is in [../admin/configuration.md](../admin/configuration.md). Where the
prose in `ARCHITECTURE.md` disagrees with the code, the code is quoted and the stale
line is named.

## 1. One umbrella, nine apps, five releases

`mix.exs:8` sets `apps_path: "apps"`. Nine Mix projects live there; `mix.exs:50-102`
declares five releases from them.

| App | Description (from its `mix.exs`) | Umbrella deps (runtime) | Test-only umbrella deps |
|---|---|---|---|
| `troupe_protocol` | "Wire format: JSON-RPC messages, events, schemas, and a client" (`apps/troupe_protocol/mix.exs:15`) | none | none declared; see §7 |
| `troupe_core` | "Session actor trees: agents, tools, providers, and the log" (`apps/troupe_core/mix.exs:17`) | `troupe_protocol` (`:33`) | — |
| `troupe_gateway` | "The daemon: transports, connections, subscriptions, scopes" (`apps/troupe_gateway/mix.exs:15`) | `troupe_core`, `troupe_protocol` (`:31-32`) | — |
| `troupe_tui` | "The terminal client. Speaks only the protocol." (`apps/troupe_tui/mix.exs:15`) | `troupe_protocol` (`:30`) | `troupe_gateway` (`:34`) |
| `troupe_ctl` | "The command line. Speaks only the protocol." (`apps/troupe_ctl/mix.exs:15`) | `troupe_protocol` (`:32`) | `troupe_gateway` (`:39`) |
| `troupe_worker` | "Remote worker runtime (stage 2)" (`apps/troupe_worker/mix.exs:15`) | `troupe_core`, `troupe_protocol`, `troupe_gateway` (`:31-33`) | `troupe_plane` (`:38`) |
| `troupe_plane` | "Control plane: identity, placement, budgets, admin (stage 2)" (`apps/troupe_plane/mix.exs:15`) | `troupe_protocol` (`:31`) | `troupe_ctl` (`:65`) |
| `troupe_operator` | "Kubernetes operator (stage 2)" (`apps/troupe_operator/mix.exs:15`) | `troupe_protocol` (`:31`) | — |
| `troupe_a2a` | "The A2A facade: a profile as an agent other agents can call" (`apps/troupe_a2a/mix.exs:15`) | `troupe_protocol` (`:35`) | — |

Discrepancy: `ARCHITECTURE.md:19-30` says "Four releases" and lists eight apps without
`troupe_a2a`; `mix.exs:50-102` defines five releases and `apps/` holds nine projects.
The "(stage 2)" descriptions in `apps/troupe_worker/mix.exs:15`,
`apps/troupe_plane/mix.exs:15` and `apps/troupe_operator/mix.exs:15` predate stages 3-6.

Releases (`mix.exs:50-102`):

| Release | Applications | Steps | Packaging |
|---|---|---|---|
| `troupe_operator` | `troupe_protocol`, `troupe_operator` | `:assemble`, `:tar` | OCI image, `docker/Dockerfile` |
| `troupe_plane` | `troupe_protocol`, `troupe_plane` | `:assemble`, `:tar` | OCI image |
| `troupe_a2a` | `troupe_protocol`, `troupe_a2a` | `:assemble`, `:tar` | OCI image |
| `troupe_worker` | `troupe_core`, `troupe_protocol`, `troupe_gateway`, `troupe_worker` | `:assemble`, `Troupe.Release.build_reapers/1`, `:tar` | OCI image |
| `troupe` | `troupe_core`, `troupe_protocol`, `troupe_gateway`, `troupe_tui`, `troupe_ctl` | `:assemble`, `build_reapers/1`, `Troupe.Release.verify_linux_nif/1`, `Burrito.wrap/1` | Burrito binary for five targets (`mix.exs:93-99`) |

The comment at `mix.exs:44-49` gives the split: the client is one Burrito executable
"so it needs nothing installed alongside it"; the other four run "in a cluster where an
Erlang runtime is the container's business, not the user's". `troupe_ctl` is listed last
in the `troupe` release because `Troupe.CLI` blocks for `troupe daemon` and the core and
gateway must already be up (`apps/troupe_ctl/lib/troupe/ctl/application.ex:5-8`).

Every app and the chart are version `0.2.0` (`mix.exs:4`, each `apps/*/mix.exs:7`,
`charts/troupe/Chart.yaml`).

## 2. Boundaries and how they are enforced

`mix troupe.boundaries` (`apps/troupe_core/lib/mix/tasks/troupe.boundaries.ex`) reads the
`imports` chunk of every compiled beam and compares it against the app rules at `:29-39`
and the module rule at `:48-51`:

| Rule | Text in the task |
|---|---|
| `troupe_tui` may call only `troupe_protocol` | "the TUI is a protocol client and gets no private access" (`:30-31`) |
| `troupe_ctl` may call only `troupe_protocol` | `:32-33` |
| `troupe_a2a` may call only `troupe_protocol` | `:34-35` |
| `troupe_plane` never calls `troupe_core` or `troupe_gateway` | "the plane does not run agents" (`:36`) |
| `troupe_operator` never calls `troupe_core`, `troupe_gateway` or `troupe_plane` | "the operator holds cluster privileges and has no public surface" (`:37-38`) |
| Every `Troupe.Plane.Web.Live.*` module may call only `Troupe.Plane.Admin` among `Troupe.Plane.*` | "a LiveView is an admin API client and gets no private access" (`:49-50`) |

Two further checks run in the same task: every cross-app call must be declared as
`{:app, in_umbrella: true}` in the caller's `mix.exs` (`:128-139`, regex at `:224`), and
the task raises on the first violation (`:179-188`). It runs as part of `mix check`
(`mix.exs:34-40`) and in CI (`.github/workflows/ci.yml:79-80`).

Test-only umbrella dependencies do not violate the rules because the task reads beams
under `_build/<env>/lib/<app>/ebin` (`:212-217`) and `lib/` never calls them; the
comments at `apps/troupe_ctl/mix.exs:36-38`, `apps/troupe_plane/mix.exs:61-64` and
`apps/troupe_worker/mix.exs:34-37` say so.

Runtime seams that keep the rules true without a compile-time dependency:

- `troupe_ctl` finds the TUI, the HQ view and the daemon module through
  `config :troupe_ctl, frontend:, fleet_view:, daemon:` (`config/config.exs:3-10`).
- The operator and the worker both compose the pod hostname
  `<ordinal>-<profile>.<domain>`; `apps/troupe_operator/lib/troupe/operator/names.ex:45-50`
  and `config/runtime.exs:50-64` each say the two "cannot share a function across the app
  boundary".

## 3. Supervision trees

### 3.1 The core (`troupe_core`)

`Troupe.Application` (`apps/troupe_core/lib/troupe/application.ex:17-27`), `one_for_one`:

```
Troupe.Supervisor
├── Troupe.Registry
├── Troupe.Events                 duplicate-key Registry; internal pub/sub (events.ex:1-14)
├── Troupe.Sessions.Index
├── Troupe.Sessions               DynamicSupervisor, :transient children (session.ex:200-244)
│   └── Troupe.Session            per session, rest_for_one, max_restarts 3 / 10 s (session.ex:54-88)
│       ├── Session.Log           the JSONL log and hash chain
│       ├── Session.Approvals
│       ├── Session.ClientTools
│       ├── [Troupe.LLM.Fake]     only when provider is "fake" and no fake was injected
│       ├── Agent.Node            the root agent
│       ├── Session.Watcher       watch mode
│       ├── Session.Files         fs_changed events
│       └── Session.Summary       the summary projection, last on purpose
└── [Troupe.Wrapper]              only inside a Burrito binary (wrapper.ex:1-21)
```

The ordering argument is in the moduledoc at `apps/troupe_core/lib/troupe/session.ex:2-12`:
`Log` first because everything persists through it; `Approvals` and `ClientTools` above
the agent so a restarted agent finds the same answers and registrations; `Watcher` after
the agent so a watch-mode crash restarts nothing above it; `Summary` last because "a
projection that could restart an agent by crashing would be worse than no projection"
(`:83-85`).

### 3.2 The local daemon (`troupe_gateway`)

`Troupe.Gateway.Application` starts `Troupe.Gateway.Daemon` only when
`:troupe_gateway, :autostart` is set (`apps/troupe_gateway/lib/troupe/gateway/application.ex:13-22`);
`config/runtime.exs:411` sets it from `TROUPE_DAEMON_AUTOSTART`. The tree
(`daemon.ex:10-16`, `:61-70`), `rest_for_one`, max_restarts 5 / 10 s:

```
Troupe.Gateway.Daemon
├── Gateway.Commands          idempotency ledger, command_id -> acknowledgement
├── Gateway.Connections       DynamicSupervisor, max_children 256 (daemon.ex:83)
│   └── Gateway.Connection    one per attached client
├── Gateway.Listener          Unix socket or loopback TCP
└── Gateway.Idle              stops the daemon after a quiet period
```

Sessions are not in this tree; they live in `Troupe.Application` "so the daemon can
restart its listener without disturbing a running agent" (`daemon.ex:18-20`).

### 3.3 A worker pod (`troupe_worker`)

`Troupe.Worker.Application` is empty unless `:troupe_worker, :autostart`
(`apps/troupe_worker/lib/troupe/worker/application.ex:16-21`), which
`config/runtime.exs:347-356` sets from `TROUPE_WORKER_AUTOSTART`. Children, `one_for_one`
(`application.ex:26-46`):

```
Troupe.Worker.Supervisor
├── Worker.Sessions              Registry + DynamicSupervisor of Session.Manager (sessions.ex:22-30)
├── Worker.Auth
├── Worker.MCP                   before Bundles: a bundle hands its servers to the registry
├── Worker.Bundles               before the link: enrolment claims the bundle hash
├── Worker.Usage
├── Worker.Disk.Watch
├── [Worker.Plane.Link]          only when :plane is configured (TROUPE_PLANE_CONTROL)
└── Worker.Harness               Supervisor, one_for_one (harness.ex:56-73)
    ├── Gateway.Commands
    ├── Gateway.Connections
    ├── Gateway.Listener         raw NDJSON on TROUPE_HARNESS_PORT (4100)
    └── Gateway.Web              Bandit on TROUPE_HTTP_PORT (4000): /health/live, /health/ready, /v1/socket
```

A pod without `TROUPE_PLANE_CONTROL` does not start the link at all
(`application.ex:37-40`, `config/runtime.exs:381-383`). The harness owns its own
`Commands` and `Connections` because "a pod never runs the local daemon, so there is
exactly one owner either way" (`harness.ex:26-30`).

### 3.4 The plane (`troupe_plane`)

`Troupe.Plane.Application` is empty unless `:troupe_plane, :autostart`
(`apps/troupe_plane/lib/troupe/plane/application.ex:18-23`; `config/config.exs:33-37`
sets it `false`, `config/runtime.exs:182,311-312` sets it `true` under
`TROUPE_PLANE_AUTOSTART=true`). Children, `one_for_one` (`application.ex:25-59`):

```
Troupe.Plane.Supervisor
├── Plane.Repo                        Ecto, PostgreSQL
├── Plane.Settings                    5 s ETS cache over platform_settings (settings.ex:37-45)
├── Phoenix.PubSub  (Troupe.Plane.PubSub)
├── Plane.Singleton                   DynamicSupervisor for :global actors (singleton.ex:1-27)
├── Plane.Fleet.Sweeper
├── Plane.Triggers.Scheduler.Keeper
├── Registry  (Plane.Control.Registry, :duplicate)
├── Plane.Control.Connections         DynamicSupervisor, max_children 512 (control/listener.ex:141)
├── Plane.Control.Listener            :gen_tcp on TROUPE_PLANE_CONTROL_PORT (4001)
├── Plane.Ledger.Cache                60 s cache of ledger sums
├── Plane.Tokens.Credential           the plane's OpenBao credential
├── Plane.Web.Endpoint                Phoenix + Bandit on TROUPE_HTTP_PORT (4000)
└── [Cluster.Supervisor]              libcluster, only when :topologies is set (RELEASE_DISTRIBUTION=name)
```

The cluster-unique actors — one `Placement` per profile, one `TeamBudget` per team — are
started on demand under `Singleton` and registered with `:global`
(`application.ex:9-12`, `singleton.ex:4-17`). This is why the chart refuses
`plane.replicas > 1` without `plane.distribution: name`
(`charts/troupe/templates/_helpers.tpl:22-35`).

### 3.5 The operator (`troupe_operator`)

`Troupe.Operator.Application` starts `Troupe.Operator.Supervisor` only under
`:troupe_operator, :autostart` (`apps/troupe_operator/lib/troupe/operator/application.ex:17-26`;
`config/runtime.exs:97-98`). The supervisor is `rest_for_one`, max_restarts 5 / 30 s
(`supervisor.ex:25-44`):

```
Troupe.Operator.Supervisor
├── Operator.Reconcilers      Registry + DynamicSupervisor, one Reconciler per resource (reconcilers.ex:29-34)
├── Operator.Watch            Bonny: watch WorkerProfile/TeamVolume, resync, Lease-based leader election
└── Operator.Descendants      watches the objects the operator created
```

The Kubernetes connection is built once in `init/1` (`supervisor.ex:28`) by
`Troupe.Operator.Conn` — in-cluster ServiceAccount, or `KUBECONFIG` /
`TROUPE_KUBE_CONTEXT` outside a pod (`conn.ex:1-11`, `:49-57`). The watch namespace
defaults to `TROUPE_PLANE_NAMESPACE` or `troupe-system` (`supervisor.ex:46`).

### 3.6 The A2A facade and the CLI

`Troupe.A2A.Application` always starts `Troupe.A2A.Plane.Cache` and `Troupe.A2A.Streams`;
Bandit on `Troupe.A2A.Router` is added only when `Troupe.A2A.autostart?/0`
(`apps/troupe_a2a/lib/troupe/a2a/application.ex:14-30`; `config/runtime.exs:415-442`).

`Troupe.Ctl.Application` supervises `Troupe.CLI`, which runs the command synchronously
inside a Burrito binary and is a no-op otherwise (`apps/troupe_ctl/lib/troupe/ctl/application.ex:2-19`).

## 4. The three transports

One JSON-RPC framing, three transports (`ARCHITECTURE.md:131-143` matches the code):

| Transport | Code | Authentication |
|---|---|---|
| Unix socket, NDJSON, mode 0600 | `Troupe.Protocol.Endpoint.unix/1`, `apps/troupe_protocol/lib/troupe/protocol/endpoint.ex:4-12,44` | file permissions |
| Loopback TCP, NDJSON, random token in a user-only file | `Endpoint.tcp/1`, `endpoint.ex:47-50`; chosen when `AF_UNIX` is unavailable (`:37-39`) | the token |
| WebSocket, one message per text frame | `Troupe.Gateway.Web` `GET /v1/socket`, `apps/troupe_gateway/lib/troupe/gateway/web.ex:1-13,36` | a plane-minted session token with the pod as audience (`apps/troupe_worker/lib/troupe/worker/harness.ex:4-8`) |

`TROUPE_DAEMON_SOCKET` overrides the local choice: `tcp` forces loopback TCP, any other
value is a Unix socket path (`endpoint.ex:27-33`). The pod also serves raw NDJSON on port
4100 for in-cluster callers (`harness.ex:20-23`, `config/runtime.exs:358-362`).

Discrepancy: `README.md:9` and `:262` describe "JSON-RPC over a Unix socket" as the
protocol; the code has three transports, and remote clients use the WebSocket.

The local daemon does not serve a WebSocket: `Troupe.Gateway.Daemon` has no `Gateway.Web`
child (`daemon.ex:61-66`). `docs/plans/README.md:52` lists that as still to do (see
[../AUDIT.md](../AUDIT.md) §1.2).

## 5. Rules the code states about itself

- **`Session.Log` is the only publisher of durable events.** The log appends, fsyncs and
  publishes in one mailbox (`apps/troupe_core/lib/troupe/session/log.ex:2-17`,
  `:44-55`). `Troupe.Events` is "internal to core" and clients subscribe only through the
  protocol (`events.ex:2-9`).
- **Ephemeral events are never persisted.** `Troupe.Protocol.Event` moduledoc,
  `apps/troupe_protocol/lib/troupe/protocol/event.ex:5-11`.
- **The response is an acknowledgement, never the effect**, and **replaying a
  `command_id` is a no-op** returning the original acknowledgement
  (`apps/troupe_gateway/lib/troupe/gateway/dispatch.ex:7-14`; the ledger is
  `Troupe.Gateway.Commands`, keyed by subject plus `command_id`, TTL 30 minutes,
  `commands.ex:1-31`).
- **Scopes** `observe`, `control`, `admin` are checked per method against the table at
  `dispatch.ex:41-74`.
- **Old logs are upcast one version at a time and never lose a field**
  (`apps/troupe_core/lib/troupe/log/upcast.ex:1-19`; `@current 1` at `:23`). The fold
  hash over a witness of durable types is what fixtures check
  (`apps/troupe_core/lib/troupe/log/fold.ex:1-27,59-70`).
- **Schema compatibility is add-only** within major version 1
  (`apps/troupe_protocol/lib/troupe/protocol/schema.ex:9-12`; enforced by
  `mix troupe.schema.diff`, `apps/troupe_protocol/lib/mix/tasks/troupe.schema.diff.ex:8-14`).
- **Admin parity**: the console, `/rpc`, `troupe admin` and the MCP tool list are four
  renderings of `Troupe.Plane.Admin`, enumerated by
  `apps/troupe_plane/test/troupe/plane/admin_parity_test.exs`. Discrepancy: the
  moduledocs at `apps/troupe_plane/lib/troupe/plane/admin.ex:5` and
  `admin_parity_test.exs:3` still say "three"; `apps/troupe_plane/lib/troupe/plane/admin/api.ex:16-17`
  says four, and the test checks four (`admin_parity_test.exs:87-134`).

## 6. Where state lives

| State | Where | Written by | Code |
|---|---|---|---|
| Local session log | `<state>/sessions/<workspace-hash>/<session-id>/events.jsonl`; `<state>` is `TROUPE_STATE_HOME`, else `$XDG_STATE_HOME/troupe` or `%LOCALAPPDATA%\troupe` | `Session.Log` | `apps/troupe_core/lib/troupe/paths.ex:29-47,88-93`; `session/log.ex:109,190` |
| Local blobs | `<session dir>/blobs/<digest>` | `Session.Blobs` | `apps/troupe_core/lib/troupe/session/blobs.ex:119-123` |
| Local config | `TROUPE_CONFIG_HOME`, else `$XDG_CONFIG_HOME/troupe` or `%APPDATA%\troupe`; `config.yaml`, `agents/`, `credentials.json`, `mcp.json` | user, `troupe login` | `paths.ex:13-20,81-86`; `apps/troupe_ctl/lib/troupe/ctl/credentials.ex:20-24`; `apps/troupe_tui/lib/troupe/ui/tui/connectors.ex:35-36` |
| Daemon discovery | `$XDG_RUNTIME_DIR/troupe/daemon.sock` or a `daemon.json` with a TCP token; `O_EXCL` lock, stale after 30 s | the daemon | `apps/troupe_protocol/lib/troupe/protocol/daemon.ex:1-29` |
| Pod working copies | PVC `data` at `/var/lib/troupe` | worker | `apps/troupe_operator/lib/troupe/operator/resources.ex:756` |
| Sealed session data | S3 `sessions/<id>/{manifest.json, segments/, snapshots/, workspace/, blobs/}` | workers; the plane reads manifests only in `mix troupe.index.rebuild` | `apps/troupe_protocol/lib/troupe/sessions/storage.ex`; `apps/troupe_plane/lib/mix/tasks/troupe.index.rebuild.ex:4-17` |
| Per-session data keys | OpenBao KV v2 `troupe/teams/<team>/sessions/<id>` | workers | `apps/troupe_protocol/lib/troupe/kms/open_bao.ex` |
| Token signing key | OpenBao transit `troupe-session-tokens` | created out of band (`dev/docker-compose.yml:116-117`, `dev/kind/dependencies.yaml:231-232`) | `apps/troupe_plane/lib/troupe/plane/tokens.ex` |
| Index, identity, ledger, audit, settings | PostgreSQL, 20 tables from 11 migrations; never session content | plane | `apps/troupe_plane/priv/repo/migrations/`, `apps/troupe_plane/lib/troupe/plane/repo.ex:5-8` |
| `WorkerProfile` (write), `TroupePolicy` (read), `TokenReview` | Kubernetes API | plane | `apps/troupe_plane/lib/troupe/plane/provision.ex`, `cluster_policy.ex`, `enrolment.ex` |
| Everything in `troupe-w-<profile>` | Kubernetes API | operator, SSA field manager `troupe-operator` | `apps/troupe_operator/lib/troupe/operator/resources.ex` |

Caveat from [../AUDIT.md](../AUDIT.md) §3.1: nothing under `config/` or `apps/*/lib`
sets `:troupe_plane, :k8s_conn`, which `Provision` and `ClusterPolicy` read; only
enrolment builds its own connection (`apps/troupe_plane/lib/troupe/plane/enrolment.ex:169-185`).

## 7. Things a reader will trip over

- `troupe_protocol` is not "no I/O beyond a socket" (`ARCHITECTURE.md:23`): it holds the
  OpenBao client (`lib/troupe/kms/open_bao.ex`), the SigV4 S3 client
  (`lib/troupe/object_store.ex`), the MCP client (`lib/troupe/mcp/client.ex`), and the
  `TroupePolicy` / `WorkerProfile` parsers (`lib/troupe/policy.ex`, `lib/troupe/worker_profile.ex`).
  The reason is in its `mix.exs:40-42`: these are "contracts both the plane and the
  workers hold".
- `apps/troupe_protocol/test/troupe/policy_test.exs:12` does `import Troupe.Operator.Fixtures`,
  a module under `apps/troupe_operator/test/support/fixtures.ex`, although
  `apps/troupe_protocol/mix.exs` declares no dependency on `troupe_operator`. See
  [testing.md](testing.md) §6 for what that means for running the suite.
- `config/runtime.exs:237` names `Troupe.Plane.Web.Breakglass`; the module is
  `Troupe.Plane.Breakglass` (`apps/troupe_plane/lib/troupe/plane/breakglass.ex`).
- `apps/troupe_plane/lib/troupe/plane/web/live/status.ex:9` says the states are read from
  `docs/design/admin/tokens.json` at compile time; they are read from
  `apps/troupe_plane/priv/design/statuses.json`, which `mix troupe.admin.tokens` writes
  (`apps/troupe_plane/lib/mix/tasks/troupe.admin.tokens.ex:38-43`).
