# Local setup

## 1. Prerequisites

From `.tool-versions`: Erlang/OTP 28.5.0.5, Elixir 1.20.4-otp-28, Zig 0.16.0 (for
`mix compile.reaper`; without it `shell` does not run), Node for the GUI. On Windows,
`scripts/setup-windows-toolchain.ps1` installs them. Optional, each unlocking a part of
the suite that otherwise skips ([testing.md](testing.md)):

| Tool | Unlocks |
|---|---|
| Docker with compose | `scripts/dev-up`: PostgreSQL, MinIO, OpenBao for the plane, worker and protocol suites |
| `python3` | the protocol conformance test |
| `bubblewrap` | the sandbox tests |
| `inotify-tools` (Linux) | the native watch backend |
| `kind`, `kubectl`, `helm` | `scripts/remote-up` and the cluster suites |

**None of it, with Docker.** `scripts/toolbox` runs a command in a container with the
pinned toolchain plus `inotify-tools` and `bubblewrap`, joined to `scripts/dev-up`'s
network, with `_build` and `deps` in named volumes:

```bash
scripts/dev-up
scripts/toolbox mix check
scripts/toolbox            # a shell
```

Five tests do not pass in a container and are not made to: the OS-pid cancellation test
and four gateway tests that spawn or `kill -9` a daemon. They pass on a Linux runner.

| Service | Image | Host port | Credentials | Notes |
|---|---|---|---|---|
| `postgres` | `postgres:16-alpine` | 55432 (5432 in the container); 55433 is mapped to 5433 for the restored cluster `scripts/pitr-drill` starts | `troupe` / `troupe`, database `troupe_plane_dev` | `wal_level=replica`, `archive_mode=on`, `archive_timeout=60`, data checksums; WAL archive volume chowned to 70:70 by a `busybox` init service (`docker-compose.yml:14-53`) |
| `minio` | `pgsty/minio:RELEASE.2026-08-04T00-00-00Z`, pinned by digest (Pigsty's community build; MinIO's own images are no longer public) | 59000 (S3), 59001 (console) | `troupe` / `troupe-secret` | `minio-setup` creates bucket `troupe-sessions` and enables versioning (`:74-85`) |
| `openbao` | `openbao/openbao:2.4.1`, dev mode | 58200 | root token `troupe-dev-root` | `openbao-setup` enables `transit` and creates key `troupe-session-tokens` (`ecdsa-p256`) (`:106-119`); KV v2 is at `secret/` in dev mode |

`config/config.exs:61-70` points the dev and test repos at `localhost:55432`
(`troupe_plane_dev` / `troupe_plane_test`), `:86-96` points the object store at
`localhost:59000`, and `:98-113` points both the worker's KMS and the plane's transit at
`localhost:58200` with the dev root token — "for these two environments only".

Stop them with `scripts/dev-down`; `scripts/dev-down --purge` also removes the volumes
(`scripts/dev-down:7-11`).

Then create and migrate the test database, which is what `apps/troupe_plane/test/test_helper.exs:26-31`
tells you to do when it finds none:

```bash
mix deps.get
mix check          # compile with warnings as errors, format, credo --strict, boundaries, test
```

## 3. Development services

`scripts/dev-up` starts compose project `troupe-dev` on ports chosen not to collide with a
Postgres or MinIO already on the machine; `scripts/dev-down` stops it (`--purge` drops the
volumes).

| Service | Port | Credentials | Notes |
|---|---|---|---|
| PostgreSQL 16 | 55432 (55433 for the PITR drill's restored cluster) | `troupe` / `troupe` | WAL archiving on, for `scripts/pitr-drill` |
| MinIO | 59000, console 59001 | `troupe` / `troupe-secret` | bucket `troupe-sessions`, versioned |
| OpenBao, dev mode | 58200 | root token `troupe-dev-root` | `transit` with `troupe-session-tokens`; KV v2 at `secret/` |

`config/config.exs` points the dev and test environments at these. Then
`MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate` for the plane's suite.

## 4. A plane and a worker on kind

There is no bare `mix` path to a serving plane: `config/config.exs` turns autostart off,
and only `config/runtime.exs` — inside `if config_env() == :prod` — turns it on. The one
supported path is:

```bash
scripts/remote-up          # idempotent: run it again to pick up a change
```

It creates kind cluster `troupe-dev` (host ports 30080/30443), installs ingress-nginx and
labels its namespace, builds the images and loads them (`TROUPE_SKIP_BUILD=1` skips),
applies `dev/kind/dependencies.yaml` (PostgreSQL, MinIO, OpenBao with Kubernetes auth,
Dex), applies the CRDs, installs the chart with `dev/kind/values.yaml` and restarts the
plane and operator, then creates a `WorkerProfile` and its namespace's Secrets. It prints:

| Thing | Address |
|---|---|
| plane, console | `http://plane.localtest.me:30080`, `/admin` |
| identity | `http://dex.localtest.me:30080/dex`, user `ada@example.test`, password `troupe` |
| workers | `ws://<ordinal>-<profile>.workers.localtest.me:30080/v1/socket` |

Then `troupe login http://plane.localtest.me:30080` and `troupe --remote`.
`scripts/kind-down` deletes the cluster. `mix troupe.e2e` runs the cluster suite against it.

## 5. Configuration

`Troupe.Config` layers built-in defaults, `<config dir>/config.yaml`,
`<workspace>/.troupe/config.yaml`, environment variables, then explicit options; merging
is key-wise and any string may say `{env:VAR}`. Its moduledoc and struct in
`apps/troupe_core/lib/troupe/config.ex` are the reference for every key and default; the
[TUI README](../../clients/tui/README.md#configure-a-provider) shows the common ones.
A workspace can name `provider: fake` and a `fake_script` to run the daemon without a
model.

## 6. Development variables

| Variable | Read by | Effect |
|---|---|---|
| `TROUPE_SKIP_BUILD`, `TROUPE_PROFILE_NAME`, `TROUPE_GATEWAY_URL`, `TROUPE_GATEWAY_MODEL`, `TROUPE_GATEWAY_SMALL_MODEL`, `ITM_LLM_GW_KEY` | `scripts/remote-up` | skip the image build; the dev profile's name (`dev`), model endpoint, models, and the key written into its `llm-credentials` Secret (never into a file here) |
| `TROUPE_KIND_CLUSTER`, `TROUPE_REGISTRY`, `TROUPE_IMAGE_TAG`, `TROUPE_PUSH` | kind scripts, `scripts/build-images` | cluster name (`troupe-dev`), image prefix, tag (`dev`), push instead of `kind load` |
| `TROUPE_PG_CONTAINER`, `TROUPE_PITR_DB` | `scripts/pitr-drill` | the compose container and database |
| `TROUPE_REAPER_TARGETS` | `mix compile.reaper` | triples to build, or `all` |
| `ZIG_LOCAL_CACHE_DIR`, `ZIG_GLOBAL_CACHE_DIR` | Zig | point at a plain local filesystem: Zig aborts on ecryptfs and some network mounts |
| `TROUPE_PROVIDER`, `TROUPE_BASE_URL`, `TROUPE_API_KEY`, `TROUPE_MODEL`, `TROUPE_FAKE_SCRIPT` | `Troupe.Config` | override `config.yaml` |
| `TROUPE_STATE_HOME`, `TROUPE_CONFIG_HOME`, `XDG_*`, `APPDATA`, `LOCALAPPDATA` | `Troupe.Paths` | state and config directories |
| `TROUPE_DAEMON_SOCKET`, `TROUPE_DAEMON_COMMAND` | `Troupe.Protocol.Endpoint`, `.Daemon` | `tcp` or a socket path; what a client spawns as a daemon (else `troupe-daemon` on the `PATH`) |
| `KUBECONFIG`, `TROUPE_KUBE_CONTEXT` | operator outside a pod, cluster suites | which cluster |

## 7. The clients

`clients/tui`: `mise exec -- mix check` there, `scripts/dev` to run it from source,
`scripts/build-local` for a binary ([clients/tui/CLAUDE.md](../../clients/tui/CLAUDE.md)).
`clients/gui`: `pnpm install`, then `pnpm dev:local` - the default. It runs a second
instance of the installed `troupe-daemon` with the scripted `fake` provider, under
`TROUPE_DEV_HOME` (default: `troupe-dev-local` in the temp directory), and the GUI in
local-only mode against it: no plane, no identity provider, no key. `pnpm fake` (an
identity provider, plane and worker on loopback) and `pnpm dev` are for the plane path,
as the [GUI README](../../clients/gui/README.md) shows, and
[e2e.md](../../clients/gui/docs/e2e.md) covers the suites against a real plane and worker.

On this Windows machine the whole install is `scripts/install-local.ps1`, checked by
`scripts/verify-local.ps1` ([fixing-issues.md](fixing-issues.md)).
