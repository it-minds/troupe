# Tech stack

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).

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

Every runtime, library and external service the repository actually uses, with the
reason the code or its comments give. Locked versions come from `mix.lock`; constraints
from the `mix.exs` that declares the dependency. Where no comment justifies a choice the
table says "no comment".

## 1. Toolchain

| Tool | Version | Pinned in | Why |
|---|---|---|---|
| Erlang/OTP | 28.5.0.5 | `.tool-versions:1`; `docker/Dockerfile:8`; `.github/workflows/ci.yml:17` | runtime for every release |
| Elixir | 1.20.4 (`1.20.4-otp-28`) | `.tool-versions:2`; `docker/Dockerfile:7`; `ci.yml:16`; every `apps/*/mix.exs` requires `~> 1.20` | umbrella language |
| Zig | 0.16.0 | `.tool-versions:3`; `ci.yml` `env.ZIG_VERSION`; `docker/Dockerfile` for the worker image | builds `native/reaper/reaper.zig` — the host triple in a dev loop, the two Linux triples in a release. Without `zig` the reaper compiler is a no-op with a warning, which is why `docker/Dockerfile` installs a pinned Zig for the worker image and then fails the build if the assembled release has no reaper |
| Python | 3.12 in CI | `ci.yml:212-214` | runs `apps/troupe_gateway/test/conformance/conformance.py`, a stdlib-only fixture (`clients/python/troupe.py:1-7`); the test skips without `python3` (`apps/troupe_gateway/test/troupe/gateway/python_client_test.exs:11-12,23-25`) |
| Docker, kind, kubectl, helm | unpinned | `scripts/remote-up:25-28`; `scripts/kind-up:10-11` | the only local path to a running plane and worker |
| Debian base image | `bookworm-20260824-slim` | `docker/Dockerfile:9,48` | runtime stage for the four server images |
| hexpm/elixir image | `1.20.4-erlang-28.5.0.5-debian-bookworm-20260824-slim` | `docker/Dockerfile:11` | build stage |

## 2. Elixir dependencies

Umbrella-wide: `credo ~> 1.7` (dev/test, `runtime: false`),
and nothing else since `burrito` went with the client binary. The comment at `mix.exs:23-24`: "Each app declares
the ones it actually uses; these are the tools that run across all of them."

| Library | Locked | Declared in | Reason given |
|---|---|---|---|
| `phoenix` | 1.8.13 | `apps/troupe_plane/mix.exs:32` | brought in by the stage 3 admin panel; the API itself is `Plug.Router` because it "is a handful of routes" (`:42-44`) |
| `phoenix_live_view` | 1.2.11 | `apps/troupe_plane/mix.exs:37` | "every page here is a view of live cluster state … polling it from a browser would be a second event system beside the one the plane already has" (`:33-36`) |
| `phoenix_html` | 4.3.0 | `apps/troupe_plane/mix.exs:38` | no comment; its `priv/static/phoenix_html.js` is vendored into `priv/static/app.js` by `mix troupe.admin.assets` (`apps/troupe_plane/lib/mix/tasks/troupe.admin.assets.ex:38-42`) |
| `lazy_html` | 0.1.12 | `apps/troupe_plane/mix.exs:40` (test only) | "What `Phoenix.LiveViewTest` parses rendered pages with" (`:39`) |
| `bandit` | 1.12.5 | `apps/troupe_plane/mix.exs:41`; `apps/troupe_gateway/mix.exs:37`; `apps/troupe_a2a/mix.exs:40` | plane: "Bandit rather than Phoenix's default Cowboy: the control listener and the daemon are already plain `:gen_tcp` and Bandit is the one that does not bring a second HTTP implementation into the release for the sake of one endpoint" (`config/config.exs:43-46`); A2A: "the rest of the umbrella already serves HTTP with it" (`apps/troupe_a2a/mix.exs:36-38`) |
| `plug` | 1.20.3 | plane `:44` (`~> 1.16`), gateway `:38` (`~> 1.20`), a2a `:39` (`~> 1.16`) | routers for the API, the pod's health/WebSocket face, and the facade |
| `websock_adapter` | 0.6.0 | `apps/troupe_gateway/mix.exs:39` | "The remote transport. A worker pod is reached through an Ingress, so its clients arrive over HTTP and stay over a WebSocket; the same JSON-RPC either way" (`:35-36`) |
| `mint_web_socket` | 1.0.6 | `apps/troupe_protocol/mix.exs:35` | client side of the same WebSocket; "Mint's is the one already underneath `req`, so this adds a framing layer rather than a second HTTP stack" (`:32-34`) |
| `ecto_sql` / `postgrex` | 3.14.0 / 0.22.4 | `apps/troupe_plane/mix.exs:45-46` | no comment in `mix.exs`; the reason is in `config/runtime.exs:187-188`: "The plane keeps its index, its ledger and its audit trail in PostgreSQL." Never session content (`apps/troupe_plane/lib/troupe/plane/repo.ex:5-8`) |
| `libcluster` | 3.5.0 | `apps/troupe_plane/mix.exs:49` | "Replicas find each other through the Kubernetes API; Erlang distribution between them is confined to plane pods by NetworkPolicy" (`:47-48`). Strategy `Cluster.Strategy.Kubernetes`, `mode: :ip`, `kubernetes_ip_lookup_mode: :pods` — the latter is "load-bearing" (`config/runtime.exs:285-309`) |
| `oidcc` | 3.9.0 | `apps/troupe_plane/mix.exs:50` | no comment; the plane is "a relying party" that verifies provider tokens against the discovery document's JWKS (`apps/troupe_plane/lib/troupe/plane/oidc.ex:2-14`) |
| `k8s` | 2.8.0 | `apps/troupe_operator/mix.exs:36`; `apps/troupe_plane/mix.exs:54` | plane: "For TokenReview at enrolment, and for writing the two custom resources the plane is allowed to write" (`:51-53`). Discrepancy: the plane writes only `WorkerProfile` ([../AUDIT.md](../AUDIT.md) §2) |
| `bonny` | 1.5.0 | `apps/troupe_operator/mix.exs:35` | "Bonny over the k8s client. Spiked on Elixir 1.20 / OTP 28 first, as the spec asks: both compile and run there, so the fallback of hand-written watch-and-reconcile GenServers was not needed" (`:32-34`). Operator name, ServiceAccount and group in `config/config.exs:27-31` |
| `jose` | 1.11.12 | `apps/troupe_protocol/mix.exs:39`; `apps/troupe_plane/mix.exs:57` | protocol: "Session tokens are verified by workers offline and minted by the plane, so the JWT shape … belong[s] where both can see them. The plane signs through OpenBao; nothing here holds a private key" (`:36-38`); plane: "JWTs are signed by OpenBao's transit engine, but the header and payload are assembled here" (`:55-56`) |
| `req` | 0.7.4 | protocol `:43` (`~> 0.7`), core `:34` (`~> 0.7.4`), worker `:39`, plane `:66`, a2a `:43` | protocol: "For the key manager and the object store, which are contracts both the plane and the workers hold" (`:40-42`); a2a: "Req is what `troupe_protocol` already carries for the object store, and the plane's own clients use it for `/rpc`" (`:41-42`) |
| `aws_signature` | 0.4.3 | `apps/troupe_protocol/mix.exs:47` | "SigV4 only. The HTTP is Req's … an S3 client with its own opinions about retries and streaming would be a second HTTP stack to reason about" (`:44-46`) |
| `ezstd` | 1.2.4, it-minds fork (Windows build) | `apps/troupe_protocol/mix.exs:61` | "Segments are zstd JSONL, as the spec says. A NIF rather than gzip because a session log is highly repetitive and the ratio is what keeps the object tier affordable" (`:48-50`) |
| `yaml_elixir` | 2.12.2 | protocol `:55`, core `:38`, operator `:38` | protocol: agent definitions and skills carry YAML frontmatter and bundles are checked by both plane and worker (`:52-54`); ctl: `troupe admin bundle publish <dir>` reads `mcp.yaml` (`:33-34`) |
| `ymlr` | 5.1.6 | `apps/troupe_plane/mix.exs:60` | "GitOps mode commits the same manifest the direct mode applies, and a manifest in a repository is YAML because that is what Flux reads" (`:58-59`) |
| `credo` | 1.7.19 | `mix.exs:27` | `mix credo --strict` is part of `mix check` (`mix.exs:37`); configuration in `.credo.exs` |
| `jason` | 1.4.5 | every app | JSON codec; no comment |
| `telemetry` | 1.4.2 | `apps/troupe_core/mix.exs:36`; `apps/troupe_gateway/mix.exs:34` | core emits `[:troupe, :llm, :start\|:stop]`, `[:troupe, :tool, :stop]`, `[:troupe, :agent, :transition]` (`README.md:293-295`) |
| `file_system` | 1.1.1 | `apps/troupe_core/mix.exs:37` | the native watch backend runs `inotifywait` / `mac_listener` from its `priv` (`apps/troupe_core/lib/troupe/watch/file_system_backend.ex:6,41-48`) |
| `stream_data` | 1.4.0 | core `:39`, gateway `:40` (dev/test) | property tests (`apps/troupe_core/test/troupe/agent/property_test.exs`, `apps/troupe_gateway/test/troupe/gateway/replay_property_test.exs`) |

There is no npm, esbuild or `assets/` directory: the console's JavaScript is the UMD
bundles that ship inside `phoenix`, `phoenix_html` and `phoenix_live_view`, concatenated
by `mix troupe.admin.assets` (`apps/troupe_plane/lib/mix/tasks/troupe.admin.assets.ex:20-29`).

## 3. Native and system binaries

| Binary | Used by | Why | Where it comes from |
|---|---|---|---|
| `reaper` (Zig, `native/reaper/reaper.zig`) | every OS process Troupe starts | a Port-owned helper that kills the command's whole process tree when the Port closes, so "no cleanup code runs on the Elixir side because none can be relied on when the VM is killed outright" (`apps/troupe_core/lib/troupe/reaper.ex:2-10`) | `mix compile.reaper` into `apps/troupe_core/priv/reaper/<triple>/` (`compile.reaper.ex:1-8`) |
| `bubblewrap` (`bwrap`) | the `shell` tool in a pod | "path checks may not be the only enforcement for `shell` … `shell` runs inside a mount namespace built from the same table the file tools resolve against" (`apps/troupe_core/lib/troupe/sandbox.ex:4-9`); mode `:auto` by default (`:38-46`) | worker image only (`docker/Dockerfile:52-60`); tests skip without it (`apps/troupe_core/test/troupe/sandbox_test.exs:10-25`) |
| `git` | worktrees and the worker | `Troupe.Gateway.Worktrees` shells out for `troupe/<slug>` worktrees (`apps/troupe_gateway/lib/troupe/gateway/worktrees.ex:1-11`); "`git` is how [the worker] clones a source" (`docker/Dockerfile:52`) | worker image only (`docker/Dockerfile:60`); build stage (`:16`) |
| `ripgrep` (`rg`) | the `grep` tool | "using ripgrep when it is on PATH and a built-in scan when it is not … a single self-contained binary lands on machines with nothing installed" (`apps/troupe_core/lib/troupe/tools/grep.ex:2-8`) | not installed by the Dockerfile; optional |
| `inotify-tools` | native watch backend on Linux | falls back to polling when absent (`ci.yml:56-57,402-405`) | `ci.yml:58-59` installs it for the `check` job only |

## 4. Services the plane and workers talk to

| Service | Role | Development shape | Production shape in repo |
|---|---|---|---|
| PostgreSQL | plane's index, identity, ledger, audit, settings | `postgres:16-alpine` on 55432 with WAL archiving (`dev/docker-compose.yml:20-53`); `postgres:16` service in CI (`ci.yml:31-43`); `postgres:18.1-bookworm` on kind (`dev/kind/dependencies.yaml:77`) | Scaleway Managed Database, PITR assumed (`docs/deploying-on-scaleway.md:19,149`). Discrepancy: three different major/minor tags across dev, CI and kind |
| S3-compatible object storage | sealed segments, manifests, snapshots, workspace archives | MinIO `RELEASE.2025-04-22T22-12-26Z` on 59000/59001, bucket `troupe-sessions` with versioning (`dev/docker-compose.yml:55-85`; `dev/kind/dependencies.yaml:91-150`) | Scaleway Object Storage `https://s3.fr-par.scw.cloud`, region `fr-par` (`charts/troupe/values.small.yaml:129-133`). Versioning "must be on" (`docs/deploying-on-scaleway.md:71-76`) |
| OpenBao | transit key `troupe-session-tokens` (ecdsa-p256) for plane tokens; KV v2 for per-session data keys; Kubernetes auth with roles `troupe-worker` (audience `troupe-kms`) and `troupe-plane` | `openbao/openbao:2.4.1` dev mode, root token `troupe-dev-root`, on 58200 (`dev/docker-compose.yml:87-119`); `openbao/openbao:2.5.0` on kind with the auth mount and policies (`dev/kind/dependencies.yaml:152-274`) | Helm chart `openbao/openbao` with `deploy/scaleway/openbao.values.yaml`: one Raft replica, Shamir seal, TLS off, 8Gi `sbs-default` (`:11-33,52-73`). Discrepancy: `docs/deploying-on-scaleway.md:41-44` says three replicas and auto-unseal via Scaleway Key Manager; the values file explains why neither is possible (`openbao.values.yaml:20-33`) |
| OIDC identity provider | device grant for `troupe login`, authorization code for the console, `groups` claim | Dex `ghcr.io/dexidp/dex:v2.45.0`, public client `troupe`, user `ada@example.test` / `troupe` in groups `troupe-platform-admins`, `engineering` (`dev/kind/dependencies.yaml:276-343`) | "your existing IdP"; Entra-shaped placeholders in `charts/troupe/values.small.yaml:100-106` |
| Kubernetes | `WorkerProfile`, `TeamVolume`, `TroupePolicy` CRDs (`charts/troupe/crds/`), `TokenReview`, `ValidatingAdmissionPolicy` (GA from 1.30, `charts/troupe/values.yaml:252`) | kind, cluster `troupe-dev`, host ports 30080/30443 (`scripts/kind-up:16-36`) | Kapsule with Cilium (`docs/deploying-on-scaleway.md:18`); CI validates rendered manifests against 1.31.0 schemas (`ci.yml:127`) |
| ingress-nginx | one Ingress per worker pod and one for the plane; namespace must carry `troupe.dev/ingress=true` | `controller-v1.14.1` kind manifest (`scripts/remote-up:53`) | `deploy/scaleway/ingress-nginx.values.yaml` (LB-S, PROXY protocol v2, 3600 s timeouts, 16m body) |
| cert-manager | `ClusterIssuer` for per-host HTTP-01 certificates | none on kind (`workersScheme: ws`, `dev/kind/values.yaml:15`) | `deploy/scaleway/cluster-issuer.yaml` (`letsencrypt`, HTTP-01 only, no wildcard, `:5-16`) |
| LLM gateway (LiteLLM-shaped, OpenAI Chat Completions) | model calls from pods; `x-litellm-call-id` / `x-request-id` and `x-litellm-response-cost` headers feed the ledger; `GET <base_url>/spend/logs` for reconciliation | `scripts/remote-up:181-184` defaults to `https://llm-gw.itmindsinternal.dk/v1`, models `code-default` / `chat-fast` | policy egress `llm-gw.itmindsinternal.dk` (`charts/troupe/values.small.yaml:156-159`); reconciliation in `apps/troupe_plane/lib/troupe/plane/reconcile.ex:1-25`. Unconfirmed: `x-litellm-response-cost` on streamed responses ([../AUDIT.md](../AUDIT.md) §3.17) |
| Cilium | `CiliumNetworkPolicy` with FQDN egress rules per profile | not on kind | `operator.ciliumAvailable: true` in both Scaleway values files |

## 5. CI-only tools

| Tool | Where |
|---|---|
| `erlef/setup-beam@v1`, `mlugg/setup-zig@v1`, `actions/setup-python@v5`, `actions/cache@v4` | `ci.yml:47-67,203-222,265-272` |
| `azure/setup-helm@v4`, `ghcr.io/yannh/kubeconform:v0.6.7` | `ci.yml:98,126` |
| `docker/setup-buildx-action@v3`, `docker/login-action@v3`, `docker/build-push-action@v6` | `ci.yml:175-195` |
| `actions/upload-artifact@v4`, `actions/download-artifact@v4`, `softprops/action-gh-release@v2` | `ci.yml:364,377,429,451,478,490` |

The workflow header notes the marketplace actions are the only github.com-specific
part; "Forgejo Actions also runs" the syntax (`ci.yml:4-6`).
