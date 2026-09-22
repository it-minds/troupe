# Local setup

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../history/AUDIT.md).

> **Re-audited 2026-09-14.** This repository is the remote and ships no client. The
> Kubernetes-only change removed `apps/troupe_tui`, `apps/troupe_ctl`, the `troupe`
> Burrito release, `install.sh`, `install.ps1`, `scripts/build-local`,
> `scripts/test-install.*` and the `build`, `containers`, `installer-sh` and
> `installer-ps1` CI jobs, and moved `clients/python` to
> `apps/troupe_gateway/test/conformance/`. Statements below have been brought in line with
> that; line citations that predate it refer to the tree at commit `20fe871`.

> **2026-09-21: the monorepo** (Decision 666). The TUI, the GUI and the daemon are in this
> repository again — `clients/tui`, `clients/gui`, `apps/troupe_daemon` — and the
> installers are back at the root, installing the TUI and the daemon (671). A merged
> `VERSION` change releases and deploys everything (669). Where this page says the
> repository ships no client or no binary, that was true of the tree it was audited
> against and is not now.

There is no `.env.example` in this repository ([../history/AUDIT.md](../history/AUDIT.md) §1.5). The
variables a developer may set are tabulated in §7 of this document; every runtime
variable a deployment sets is in [../admin/configuration.md](../admin/configuration.md).

## 1. Prerequisites

From `.tool-versions`:

| Tool | Version | Needed for |
|---|---|---|
| Erlang/OTP | 28.5.0.5 | everything |
| Elixir | 1.20.4-otp-28 | everything |
| Zig | 0.16.0 | `mix compile.reaper` (runs as a compiler on every `mix compile`, `apps/troupe_core/mix.exs:15`). Without `zig` on `PATH` it prints a warning and skips, and "the `shell` tool will not run until it is built" (`apps/troupe_core/lib/mix/tasks/compile.reaper.ex:45-53`). `docker/Dockerfile` installs it for the worker image and fails the build if no reaper comes out |

Optional, each unlocking a part of the suite that otherwise skips (details in
[testing.md](testing.md)):

| Tool | Unlocks |
|---|---|
| Docker (with `docker compose`) | `scripts/dev-up`: PostgreSQL, MinIO, OpenBao for the plane, worker and protocol suites |
| `python3` | the protocol conformance test (`apps/troupe_gateway/test/troupe/gateway/python_client_test.exs:23-25`) |
| `bubblewrap` | `apps/troupe_core/test/troupe/sandbox_test.exs` |
| `inotify-tools` (Linux) | the native watch backend; CI installs it (`.github/workflows/ci.yml:56-59`) |
| `kind`, `kubectl`, `helm` | `scripts/kind-up`, `scripts/remote-up`, and the operator's and plane's cluster suites |

### 1.1 None of it, with Docker

`scripts/toolbox` runs a command against this repository with the toolchain
`.tool-versions` names, in a container built from `dev/toolbox/`, without installing any
of it — Erlang, Elixir and Zig, plus `inotify-tools` and `bubblewrap`, which are the
difference between the watch and sandbox done items being proven and being skipped.

```bash
scripts/dev-up          # Postgres, MinIO, OpenBao — the container joins their network
scripts/toolbox mix check
scripts/toolbox         # an interactive shell
```

The container joins the network `scripts/dev-up` created and carries `localhost:55432`,
`localhost:59000` and `localhost:58200` to it, so `config/config.exs` is not forked for
one way of running the suite. `_build` and `deps` live in named volumes: a Linux build and
a host build cannot share either, and a bind-mounted `_build` on a non-Linux host is the
slowest part of a compile by an order of magnitude.

Five tests do not pass in a container and are not made to — `Troupe.Agent.ResilienceTest`'s
OS-pid cancellation test, and the four gateway tests that spawn or `kill -9` a daemon. They
pass on a Linux runner, which is where that claim is settled (`DECISIONS.md` 328).

It is not a deployment artifact; `docker/Dockerfile` builds those, and CI installs the
toolchain directly.

**One trap, on a Windows checkout.** This repository's blobs are CRLF, and `mix format`
run inside the container writes LF — so after a format, `mix credo --strict` reports a
hundred-odd `Consistency.LineEndings` issues about a working tree that has become mixed.
Nothing is actually wrong: `core.autocrlf` converts the files back on `git add`, `git
diff` shows no content change, and credo run against the tree as it would be committed
finds none of them. To check the gate rather than the checkout:

```bash
git add -A && TREE=$(git write-tree) && git reset
scripts/toolbox bash -c "mkdir -p /tmp/w && git archive --format=tar $TREE | tar -x -C /tmp/w   && cd /tmp/w && ln -s /workspace/deps deps && ln -s /workspace/_build _build   && MIX_ENV=test mix credo --strict"
```

## 2. Dependencies and the gate

```bash
mix deps.get
```

```bash
mix check
```

`check` is the only alias in `mix.exs:32-42`: `compile --force --warnings-as-errors`,
`format --check-formatted`, `credo --strict`, `troupe.boundaries`, `test`. It runs in the
test environment (`mix.exs:18-21`, `preferred_envs: [check: :test]`) so the compile step
checks the same files the tests run against.

## 3. Development services

```bash
scripts/dev-up
```

Runs `docker compose --project-directory dev --file dev/docker-compose.yml up --detach --wait`
(`scripts/dev-up:10-12`). Project name `troupe-dev`; the ports are deliberately not the
defaults "so a machine that already runs a Postgres and a MinIO does not notice this one"
(`dev/docker-compose.yml:3-6`).

| Service | Image | Host port | Credentials | Notes |
|---|---|---|---|---|
| `postgres` | `postgres:16-alpine` | 55432 (5432 in the container); 55433 is mapped to 5433 for the restored cluster `scripts/pitr-drill` starts | `troupe` / `troupe`, database `troupe_plane_dev` | `wal_level=replica`, `archive_mode=on`, `archive_timeout=60`, data checksums; WAL archive volume chowned to 70:70 by a `busybox` init service (`docker-compose.yml:14-53`) |
| `minio` | `quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z` | 59000 (S3), 59001 (console) | `troupe` / `troupe-secret` | `minio-setup` creates bucket `troupe-sessions` and enables versioning (`:74-85`) |
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
MIX_ENV=test mix ecto.create
```

```bash
MIX_ENV=test mix ecto.migrate
```

CI runs the same two commands with `--quiet` (`.github/workflows/ci.yml:84-85`).

## 4. Running the plane and a worker locally

The only supported path is `scripts/remote-up`, which brings the whole remote up on a
kind cluster. There is no bare `mix` path:

- `config/config.exs:33-37` sets `:troupe_plane, autostart: false` and `:42-47` sets the
  endpoint `server: false`; `:84` sets `:troupe_worker, autostart: false`. `iex -S mix`
  therefore boots every app with an empty supervision tree except the core's.
- The only place that turns them on is `config/runtime.exs`, and everything in it is
  inside `if config_env() == :prod do` (`config/runtime.exs:94`). `TROUPE_PLANE_AUTOSTART`
  and `TROUPE_WORKER_AUTOSTART` are read there and nowhere else.
- A plane that does start refuses to run without `DATABASE_URL`, `TROUPE_SECRET_KEY_BASE`,
  `TROUPE_OIDC_ISSUER`, `TROUPE_OIDC_CLIENT_ID`, `TROUPE_OIDC_DEVICE_URL` and
  `TROUPE_OIDC_TOKEN_URL` (`config/runtime.exs:182-218,323-338`).

The compose stack in §3 exists for the test suites, which start `Repo`, the endpoint on
port 0 and the worker's machinery themselves (`apps/troupe_plane/test/test_helper.exs:4-24`,
`apps/troupe_worker/test/support/session_case.ex`).

```bash
scripts/remote-up
```

Requires `kind`, `kubectl`, `helm` and `docker` (`scripts/remote-up:25-28`). The steps,
in the script's own numbering:

| Step | What happens | Lines |
|---|---|---|
| 1 | `scripts/kind-up` unless cluster `troupe-dev` exists: one control-plane node labelled `ingress-ready=true`, host 30080 to container 80 and 30443 to 443 | `remote-up:36-41`, `kind-up:13-37` |
| 2 | ingress-nginx `controller-v1.14.1` kind manifest; namespace `ingress-nginx` labelled `troupe.dev/ingress=true`; waits for the controller pod and its admission webhook endpoints | `remote-up:49-76` |
| 3 | `scripts/build-images` (five images, loaded into kind) unless `TROUPE_SKIP_BUILD=1` | `remote-up:80-85` |
| 4 | namespace `troupe-system`; `kubectl apply -f dev/kind/dependencies.yaml` with five retries; `llm-credentials` secret rewritten from `ITM_LLM_GW_KEY` if set, else a warning that "workers will start but cannot reach a model" | `remote-up:89-111` |
| 4b | CoreDNS rewrite of `dex.localtest.me` to `dex-public.troupe-system.svc.cluster.local`, then a CoreDNS rollout | `remote-up:116-127` |
| — | waits for the `postgres`, `minio`, `openbao`, `dex` deployments | `remote-up:129-131` |
| 5 | `kubectl apply -f charts/troupe/crds/` — Helm installs CRDs once and never upgrades them | `remote-up:135-140` |
| 6 | `helm upgrade --install troupe charts/troupe --namespace troupe-system --values dev/kind/values.yaml --wait --timeout 5m`; then `rollout restart` of the plane and operator unless the build was skipped, because a rebuilt image under the same tag changes nothing in the pod spec | `remote-up:143-156` |
| 7 | a `WorkerProfile` named `${TROUPE_PROFILE_NAME:-dev}`: image `ghcr.io/objective-mj/troupe-worker:dev`, 1 replica, 2 sessions per pod, `llm.endpoint` from `TROUPE_GATEWAY_URL`, `provider: openai`, `model` from `TROUPE_GATEWAY_MODEL`, `smallModel` from `TROUPE_GATEWAY_SMALL_MODEL`, `secretRef` `llm-credentials`/`api-key`; waits for the StatefulSet; then creates `llm-credentials` (if `ITM_LLM_GW_KEY` is set) and `troupe-object-store` in `troupe-w-<profile>`, because "Troupe creates no secrets" | `remote-up:164-219` |
| 8 | prints the addresses | `remote-up:228-242` |

What step 8 prints (`scripts/remote-up:231-240`):

| Thing | Address |
|---|---|
| plane | `http://plane.localtest.me:30080` |
| console | `http://plane.localtest.me:30080/admin` |
| identity | `http://dex.localtest.me:30080/dex`, user `ada@example.test`, password `troupe` |
| workers | `ws://<n>-<profile>.workers.localtest.me:30080/v1/socket` (the script prints `<n>.${profile}` with a dot; the operator composes `<ordinal>-<profile>` with a hyphen, `apps/troupe_operator/lib/troupe/operator/names.ex:50`. Discrepancy: the printed hint is wrong by one character) |

Then, with a `troupe` binary on `PATH`:

```bash
troupe login http://plane.localtest.me:30080
```

```bash
troupe --remote sessions
```

The script is idempotent by design: "running it again after a change is the way to pick
the change up" (`scripts/remote-up:11-12`). `scripts/kind-down` deletes the cluster.

## 5. What `dev/kind/dependencies.yaml` installs

"Development shapes, and deliberately so. Single replicas, `emptyDir` volumes, static
credentials in plain `Secret`s, OpenBao in dev mode with a root token" (`dependencies.yaml:4-7`).

| Object | Contents | Lines |
|---|---|---|
| Secret `troupe-plane-database` | `url: ecto://troupe:troupe@postgres.troupe-system.svc:5432/troupe_plane` | 9-15 |
| Secret `troupe-plane-secret-key-base` | a 64-byte development value | 17-25 |
| Secret `troupe-object-store` | `access-key-id: troupe`, `secret-access-key: troupe-secret` | 27-34 |
| Secret `troupe-bao-token` | `token: troupe-dev-root` | 36-42 |
| Secret `llm-credentials` | `api-key: replace-me`, overwritten from `ITM_LLM_GW_KEY` by `remote-up` | 44-52 |
| PostgreSQL | `postgres:18.1-bookworm`, database `troupe_plane`, `emptyDir` | 54-89 |
| MinIO | same image as compose, Service ports 9000/9001, `minio-setup` Job creating `troupe-sessions` with versioning | 91-150 |
| OpenBao | `openbao/openbao:2.5.0` dev mode; ServiceAccount `openbao-reviewer` bound to `system:auth-delegator`; `openbao-setup` Job enabling `transit`, key `troupe-session-tokens`, Kubernetes auth with a reviewer JWT, policies `troupe-worker-dev` (create/read/update under `secret/data/troupe/teams/+/sessions/*`) and `troupe-plane` (delete/list/read on metadata only), roles `troupe-worker` (audience `troupe-kms`, any namespace) and `troupe-plane` (namespace `troupe-system`) | 152-274 |
| Dex | `ghcr.io/dexidp/dex:v2.45.0`; issuer `http://dex.localtest.me:30080/dex`; public static client `troupe`; static password `ada@example.test` / `troupe` (bcrypt in the ConfigMap), groups `troupe-platform-admins` and `engineering`; `skipApprovalScreen: true`; Service `dex-public` on 30080 so the issuer URL resolves inside the cluster; Ingress `dex.localtest.me` | 276-373 |

`dev/kind/values.yaml` pairs with it: image tag `dev`, `workersScheme: ws` and
`workersPort: 30080`, one plane replica with `distribution: none`, `baseUrl`
`http://plane.localtest.me:30080`, Dex as the OIDC provider with `secretName: ""`,
`bao.tokenSecretName: troupe-bao-token`, and a policy allowing
`ghcr.io/objective-mj/troupe-worker`, two replicas, four sessions per pod, egress to
`llm-gw.itmindsinternal.dk`, `github.com`, `*.github.com` and `*.anthropic.com` (the last
so the operator's cluster suite and `remote-up` can share a cluster, `:73-76`), storage
class `standard`, `workersDomain: workers.localtest.me`.

## 6. The local client configuration (`config.yaml`)

`Troupe.Config` (`apps/troupe_core/lib/troupe/config.ex`) layers, lowest to highest:
built-in defaults, `<config_dir>/config.yaml`, `<workspace>/.troupe/config.yaml`,
environment variables, then explicit overrides from the CLI or the client API
(`config.ex:2-8,75-81`). Merging is key-wise. `<config_dir>` is `TROUPE_CONFIG_HOME`,
else `$XDG_CONFIG_HOME/troupe`, else `%APPDATA%\troupe` on Windows, else `~/.config/troupe`
(`apps/troupe_core/lib/troupe/paths.ex:13-20,81-86`).

Any string value may contain `{env:VAR}`; an unset variable interpolates to the empty
string "so a missing key fails as a missing key instead of being sent upstream"
(`config.ex:10-17,113-124`). Unknown keys land in `extra` rather than failing the load
(`config.ex:163-172`).

Defaults from the struct at `config.ex:19-65`:

| Key | Default | Meaning (from the comments where there is one) |
|---|---|---|
| `provider` | `"anthropic"` | `anthropic`, `openai` or `fake` |
| `model` | `"claude-sonnet-5"` | |
| `small_model` | `nil` | used for compaction summaries when set |
| `base_url` | `nil` | provider endpoint; `/v1` may be present or absent (`README.md:129-131`) |
| `api_key` | `nil` | |
| `max_tokens` | `8192` | |
| `context_window` | `200_000` | |
| `compact_at` | `0.75` | fraction of the context window; `compact_threshold/1` at `:94-98` |
| `max_turns` | `40` | per agent budget |
| `max_input_tokens` | `2_000_000` | |
| `max_output_tokens` | `400_000` | |
| `wall_clock_ms` | `1_800_000` (30 min) | |
| `max_depth` | `3` | delegation depth cap |
| `shell_timeout_ms` | `120_000` | |
| `tool_output_limit` | `60_000` | |
| `watch` | `false` | watch mode |
| `watch_debounce_ms` | `300` | |
| `watch_poll_interval_ms` | `1_000` | |
| `fs_events` | `false` | durable `fs_changed` events; "Off locally … on in a pod" (`:37-40`) |
| `fs_debounce_ms` | `100` | |
| `attribution` | `%{}` | `%{owner:, team:}` the gateway bills against; set by the worker (`:42-45`) |
| `auto_approve` | `false` | |
| `approvals` | `:wait` | `wait` or `deny`; "There is deliberately no `:auto` here" (`:46-52`); any value other than `"deny"` coerces to `:wait` (`:190-191`) |
| `resume_on_restart` | `false` | a restarted tree comes back interrupted unless true (`:53-57`) |
| `default_agent` | `"build"` | |
| `state_dir` | `nil` | `nil` means the platform state directory (`:59-61`) |
| `fake_script` | `nil` | only with `provider: "fake"` (`:62-64`) |

Environment variables read into the same struct, winning over both files
(`config.ex:139-146`): `TROUPE_PROVIDER`, `TROUPE_BASE_URL`, `TROUPE_API_KEY`,
`TROUPE_MODEL`, `TROUPE_FAKE_SCRIPT`. An empty string is treated as unset (`:148-154`).
`apps/troupe_core/priv/examples/config.gateway.yaml` is a ready-made gateway
configuration; `README.md:149` cites it without the `apps/troupe_core/` prefix
(Discrepancy).

## 7. Development environment variables

Everything a developer, a script or a test reads. Runtime variables for a deployment are
in [../admin/configuration.md](../admin/configuration.md).

| Variable | Read by | Effect |
|---|---|---|
| `MIX_ENV` | Mix | `test` for the suite; `prod` for `mix release` (`docker/Dockerfile`). Only `prod` evaluates `config/runtime.exs` (`:94`) |
| `TROUPE_SKIP_BUILD` | `scripts/remote-up:81,151` | `1` skips `scripts/build-images` and the plane/operator rollout restart |
| `TROUPE_PROFILE_NAME` | `scripts/remote-up:20` | the dev `WorkerProfile` name; default `dev` |
| `TROUPE_GATEWAY_URL` | `scripts/remote-up:181` | `llm.endpoint` of the dev profile; default `https://llm-gw.itmindsinternal.dk/v1` |
| `TROUPE_GATEWAY_MODEL` | `scripts/remote-up:183` | `llm.model`; default `code-default` |
| `TROUPE_GATEWAY_SMALL_MODEL` | `scripts/remote-up:184` | `llm.smallModel`; default `chat-fast`. Caveat: nothing under `apps/*/lib` reads the resulting `TROUPE_SMALL_MODEL` ([../history/AUDIT.md](../history/AUDIT.md) §3.3) |
| `ITM_LLM_GW_KEY` | `scripts/remote-up:103-111,200-205` | written into secret `llm-credentials` (`api-key`) in `troupe-system` and `troupe-w-<profile>`; "the one secret that is never written to a file in this repository" |
| `TROUPE_KIND_CLUSTER` | `scripts/kind-up:8`, `kind-down:4`, `remote-up:17`, `build-images:21` | kind cluster name; default `troupe-dev` |
| `TROUPE_REGISTRY` | `scripts/build-images:19` | image prefix; default `ghcr.io/objective-mj` |
| `TROUPE_IMAGE_TAG` | `scripts/build-images:20` | image tag; default `dev` |
| `TROUPE_PUSH` | `scripts/build-images:22,34-36` | `true` pushes; anything else loads into kind if the cluster exists |
| `TROUPE_PG_CONTAINER` | `scripts/pitr-drill:24` | compose container name; default `troupe-dev-postgres-1` |
| `TROUPE_PITR_DB` | `scripts/pitr-drill:25` | database the drill runs against; default `troupe_plane_test` |
| `TROUPE_REAPER_TARGETS` | `apps/troupe_core/lib/mix/tasks/compile.reaper.ex` | a comma-separated list of triples, or `all`; the default is the host triple. `Troupe.Release.build_reapers/1` sets the two Linux triples when it packs a release (`releasild-local:62`, `ci.yml:289`); unset builds the host triple; a comma-separated list builds those |
| `ZIG_LOCAL_CACHE_DIR`, `ZIG_GLOBAL_CACHE_DIR` | Zig | worth pointing at a plain local filesystem: Zig 0.16's `renameat2` flags fail with `EINVAL` on ecryptfs and some network mounts, and Zig treats that as a programmer bug and aborts |
| `TROUPE_PROVIDER` | `apps/troupe_core/lib/troupe/config.ex:141` | `anthropic`, `openai`, `fake` |
| `TROUPE_BASE_URL`, `TROUPE_API_KEY`, `TROUPE_MODEL` | `config.ex:142-144` | provider endpoint, key, model. `TROUPE_BASE_URL` means the LLM endpoint here and the plane's public URL on a plane ([../history/AUDIT.md](../history/AUDIT.md) §3.4) |
| `TROUPE_FAKE_SCRIPT` | `config.ex:145`; `apps/troupe_core/lib/troupe/session.ex:114-122` | path to a JSON script for the fake provider; raises if the file is missing. Used by the CI smoke tests (`ci.yml:333-334`) |
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` | `apps/troupe_core/lib/troupe/llm/providers/anthropic.ex:264`, `openai.ex:312` | fallback when `api_key` is unset |
| `TROUPE_STATE_HOME` | `apps/troupe_core/lib/troupe/paths.ex:33-38` | overrides the state directory (`sessions/`); test helpers delete it and case templates pass `state_dir` through config instead (`apps/troupe_core/test/test_helper.exs:9`, `test/support/session_case.ex:35-38`) |
| `TROUPE_CONFIG_HOME` | `paths.ex:16` | overrides the config directory; the core's test helper points it at a fresh temp dir (`apps/troupe_core/test/test_helper.exs:4-8`) |
| `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `XDG_RUNTIME_DIR`, `APPDATA`, `LOCALAPPDATA` | `paths.ex:81-93`; `apps/troupe_protocol/lib/troupe/protocol/endpoint.ex` | platform defaults behind the two above and the daemon socket path |
| `TROUPE_DAEMON_SOCKET` | `apps/troupe_protocol/lib/troupe/protocol/endpoint.ex:27-33` | `tcp` forces loopback TCP; any other value is a Unix socket path |
| `TROUPE_DAEMON_COMMAND` | `apps/troupe_protocol/lib/troupe/protocol/daemon.ex` | the command a client spawns to start a local daemon. It is now the only answer: the packaged-binary fallback went with the binary, and a caller that does not set it gets `:no_daemon_command`. Unused in this repository's own own path |
| `KUBECONFIG` | `apps/troupe_operator/lib/troupe/operator/conn.ex:57`; `apps/troupe_plane/lib/troupe/plane/enrolment.ex:183` | kubeconfig for the operator outside a pod and for the cluster suites; default `~/.kube/config` |
| `TROUPE_KUBE_CONTEXT` | `conn.ex:49`; `enrolment.ex:175` | context within that kubeconfig |

Chart-only variables such as `TROUPE_SCHEDULERS` (downward API into `ERL_FLAGS`,
`charts/troupe/templates/plane-deployment.yaml:195-206`) are not developer inputs and
are listed in the admin track.

## 8. Windows

No Elixir is installed on the Windows host this audit was done from. The route that works
is the same image the build uses: `hexpm/elixir:1.20.4-erlang-28.5.0.5-debian-bookworm-20260824-slim`
(`docker/Dockerfile:11`) with the repository mounted, running `mix deps.get`, `mix check`
and the rest inside it against `scripts/dev-up`'s ports on the host. This is not in the
repository's scripts (not in repo scripts). Two things to know: the local git checkout
uses `core.autocrlf=true` on this machine, which is a local setting and not a repository
one (there is no `.gitattributes`); and Credo's `Consistency.LineEndings` check is
enabled (`.credo.exs:73`), so a file with mixed endings fails `mix check`.
