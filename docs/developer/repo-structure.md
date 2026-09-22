# Repository structure

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

593 tracked files (`git ls-files | wc -l` on 2026-09-13). The umbrella root has no `lib/`
of its own: the two things the root `mix.exs` references, `Mix.Tasks.Compile.Reaper` and
`Troupe.Release`, live in `apps/troupe_core/lib/` (`DECISIONS.md:8-16`).

## 1. Top level

```
.
├── .credo.exs               credo config; includes apps/*/lib and apps/*/test (:24-33)
├── .dockerignore            what the image build never needs
├── .formatter.exs           inputs: {mix,.formatter}.exs and {config,lib,test}/** at the ROOT only (:3)
├── .github/workflows/       ci.yml (the gate, images, release, deploy), release.yml (native builds), deploy.yml (rollback)
├── .gitignore               _build, deps, apps/*/priv/reaper, .local/
├── .tool-versions           erlang 28.5.0.5, elixir 1.20.4-otp-28, zig 0.16.0, nodejs 24.19.0
├── ARCHITECTURE.md          prose architecture (stale in places; see architecture.md)
├── DECISIONS.md             every deviation from spec.md, numbered, newest at the bottom (:1-4)
├── PROTOCOL.md              the normative wire document for client authors
├── README.md                what it ships, deploy, the front door, the console, build
├── spec.md                  the specification DECISIONS.md deviates from
├── VERSION                  the one version of everything released (Decision 668)
├── apps/                    eight Mix projects (below)
├── charts/troupe/           the Helm chart — the platform and the GUI — its CRDs and three values files
├── clients/tui/             the terminal client: its own Mix project, the harness by path from apps/
├── clients/gui/             the graphical client: a pnpm workspace (client, bench, desktop)
├── config/                  config.exs (compile time) and runtime.exs (prod only)
├── deploy/                  ci-deployer.yaml (the account CI deploys as); scaleway/ values for Kapsule
├── dev/                     docker-compose.yml; kind/dependencies.yaml and kind/values.yaml
├── docker/Dockerfile        one two-stage Dockerfile for the four server releases
├── docs/                    a2a.md, deploying-on-scaleway.md, design/admin/, plans/, program/, history/ (the stage reports, AUDIT.md, the briefs), and the four tracks
├── fixtures/sample_repo/    a small Elixir project the core's workspace tests read
├── install.sh, install.ps1  install troupe and troupe-daemon from a release
├── mix.exs, mix.lock        the umbrella: aliases (check), releases, umbrella-wide deps
├── native/reaper/reaper.zig the process-tree reaper, one source for every triple
├── protocol/schema/v1/      GENERATED JSON Schema (commands/, events/, index.json)
├── scripts/                 dev-up, dev-down, kind-up, kind-down, build-images, remote-up, pitr-drill, release, deploy, ci-kubeconfig, version.exs, locks-agree.exs, …
└── test/fixtures/logs/      recorded log fixtures per released version (0.2.0/)
```

Not tracked but present locally: `.local/` (kubeconfig, `secrets.env`, values for a real
deployment; gitignored, `.gitignore:10-13`) and `.claude/launch.json` (only
`.claude/settings.local.json` is tracked).

## 2. The apps

Every app follows the same shape: `lib/`, `test/`, `test/support/` (compiled in test via
`elixirc_paths(:test)` in each `mix.exs`), and `priv/` where the app ships data. All
share `../../_build`, `../../deps`, `../../mix.lock` and `../../config/config.exs`
(each `apps/*/mix.exs:8-11`).

### `apps/troupe_protocol` — the wire

```
lib/mix/tasks/troupe.schema.gen.ex      writes protocol/schema/v1
lib/mix/tasks/troupe.schema.diff.ex     fails on a breaking change
lib/troupe/protocol.ex                  version "1"
lib/troupe/protocol/{agent_definition,bundle,canonical,client,client/transport,daemon,endpoint,error,event,json_rpc,schema,token}.ex
lib/troupe/kms.ex, kms/{open_bao,policy}.ex      OpenBao KV v2 client and the policies it expects
lib/troupe/mcp/{client,server}.ex               MCP streamable-HTTP client, server config
lib/troupe/object_store.ex                      SigV4 S3 client
lib/troupe/sessions/{cipher,snapshot,storage}.ex AES-256-GCM, snapshots, the S3 layout
lib/troupe/policy.ex, worker_profile.ex          TroupePolicy / WorkerProfile parsing
test/support/object_store_case.ex               skips without MinIO
test/troupe/**                                  8 files
```

### `apps/troupe_core` — sessions

```
lib/mix/tasks/compile.reaper.ex         the :reaper compiler (mix.exs:15)
lib/mix/tasks/troupe.boundaries.ex      the coupling check
lib/mix/tasks/troupe.fixtures.record.ex records test/fixtures/logs/<version>/
lib/troupe.ex                           the embedding API (start_session, send_input, ...)
lib/troupe/{application,config,paths,registry,events,release,reaper,sandbox,workspace,gitignore,mounts,skills,mcp,mcp/tool,budget,todo,tool,tools}.ex
lib/troupe/agent/{definition,definitions,node,server,state}.ex
lib/troupe/llm/{endpoint,message,provider,request,sse}.ex, llm/providers/{anthropic,openai,fake}.ex
lib/troupe/log/{fold,upcast}.ex
lib/troupe/session.ex, session/{approvals,blobs,client_tools,files,log,summary,usage,watcher}.ex
lib/troupe/sessions/index.ex
lib/troupe/tools/{delegate,edit_file,grep,import,list_files,output,publish,read_file,shell,todo,write_file}.ex
lib/troupe/watch.ex, watch/{file_system_backend,marker,poll_backend}.ex
priv/agents/{build,plan,general,explore}.md     built-in agent definitions
priv/examples/config.gateway.yaml               (README.md:149 cites the path without apps/troupe_core/)
priv/reaper/<triple>/reaper                     GENERATED, gitignored
test/support/{fake_transport,misbehaving_tools,session_case}.ex
test/troupe/**                                  29 files
```

### `apps/troupe_gateway` — the daemon

```
lib/troupe/gateway/{application,daemon,listener,connection,commands,dispatch,idle,presence,session,transport,writer,worktrees,client_tool,web,web/socket}.ex
test/support/harness_case.ex            several clients as distinct principals over a :remote endpoint
test/troupe/gateway/**                  11 files, including python_client_test.exs
```

### The clients are not umbrella apps

`apps/troupe_tui` and `apps/troupe_ctl` were deleted on 2026-09-14
(`git show 20fe871:apps/troupe_ctl` has them). The clients came back on 2026-09-21 outside
the umbrella (Decision 666): `clients/tui` is a Mix project of its own that depends on the
three harness apps by path, and `clients/gui` is a pnpm workspace that depends on nothing
here but the protocol. Neither is compiled by `mix check` at the root; each has its own
gate, and CI runs both.

### `apps/troupe_daemon` — the harness on a laptop

The harness and a command line, released as `troupe-daemon` from this directory
(`MIX_ENV=prod mix release`), so a runner compiles the harness and nothing else of the
umbrella (Decision 667). `mix troupe.boundaries` holds it to `troupe_protocol`,
`troupe_core` and `troupe_gateway`. Its release's runtime configuration is its own
`config/runtime.exs`.

### `apps/troupe_worker` — a pod

```
lib/troupe/worker/{application,auth,bundles,cache,disk,disk/watch,drain,harness,mcp,sessions,usage}.ex
lib/troupe/worker/plane/{commands,link}.ex
lib/troupe/worker/session/{context,manager,reader,restore,sealer,workspace}.ex
test/support/{recording_proxy,service,session_case}.ex   session_case skips without MinIO and OpenBao
test/troupe/worker/**                                    21 files
```

### `apps/troupe_plane` — the control plane

```
lib/mix/tasks/troupe.admin.assets.ex     writes priv/static/app.js
lib/mix/tasks/troupe.admin.tokens.ex     writes priv/static/tokens.css and priv/design/statuses.json
lib/mix/tasks/troupe.theme.ex            writes priv/static/theme.css from a themes kit
lib/mix/tasks/troupe.index.rebuild.ex    rebuild the session index from object storage
lib/mix/tasks/troupe.ledger.reconcile.ex compare the ledger with the gateway
lib/troupe/plane/{application,repo,release,settings,singleton,log_formatter}.ex
lib/troupe/plane/{admin,admin/api,admin/api/argument,admin/api/method,admin/mcp}.ex
lib/troupe/plane/{harness,fleet,placement,team_budget,ledger,ledger/*,identity,identity/*,sessions,sessions/*,index,erasure,drain,provision,cluster_policy,bundles,enrolment,oidc,login,principals,tokens,tokens/credential,breakglass,scim,audit,audit/event,reconcile}.ex
lib/troupe/plane/control/{connection,listener,router}.ex
lib/troupe/plane/triggers.ex, triggers/{cron,run,scheduler,template,trigger}.ex
lib/troupe/plane/web/{endpoint,router,admin_router,admin_auth,cors,error_html}.ex
lib/troupe/plane/web/live/{auth,root,layout,status,overview,workers,teams,sessions,bundles,triggers,audit,settings,profile_editor}.ex
priv/repo/migrations/                    11 migrations, 20260101000001 .. 20260913000011
priv/static/app.js                       GENERATED by mix troupe.admin.assets
priv/static/tokens.css                   GENERATED by mix troupe.admin.tokens
priv/static/console.css                  hand-written
priv/static/theme.css                    GENERATED by mix troupe.theme (Signal)
priv/static/brand/{mark,favicon}.svg     the mask, drawn from the token geometry
priv/static/brand/favicon.ico            GENERATED by python scripts/brand-icons.py
priv/static/brand/apple-touch-icon.png   GENERATED by python scripts/brand-icons.py
priv/static/brand/mask.png               the photograph, resized from docs/mask.png
priv/design/statuses.json                GENERATED by mix troupe.admin.tokens
test/support/{data_case,enrolment_stub,fake_pod,panel_case,replica}.ex
test/troupe/plane/**                     27 files, including admin_parity_test.exs
```

### `apps/troupe_operator` — the reconciler

```
lib/troupe/operator/{application,supervisor,conn,watch,reconcilers,reconciler,resources,descendants,names,settings,status}.ex
lib/troupe/operator/controller/{worker_profile,team_volume}.ex
test/support/{cluster_case,fixtures}.ex   cluster_case skips without a kubeconfig; fixtures is also imported by troupe_protocol's policy_test
test/troupe/operator/{resources_test,cluster_test,admin_cluster_test,latency_cluster_test}.exs
```

The CRDs themselves are not in this app; they are hand-written under
`charts/troupe/crds/` (`config/config.exs:23-26`).

### `apps/troupe_a2a` — the facade

```
lib/troupe/a2a.ex
lib/troupe/a2a/{application,router,http,auth,card,tasks,stream,streams,events,artifacts,error,plane,plane/cache,worker}.ex
test/support/{case,fake_worker,stub_plane}.ex
test/troupe/a2a/**                        5 files
```

## 3. Where tests, fixtures and schemas live

| What | Path |
|---|---|
| Unit and integration tests | `apps/<app>/test/troupe/**/*_test.exs` |
| Case templates and stubs | `apps/<app>/test/support/*.ex` |
| Recorded log fixtures | `test/fixtures/logs/0.2.0/{approval,error_and_recovery,metered_turn,simple_turn,subagents,tool_use}.jsonl` and `hashes.json`; read by `apps/troupe_core/test/troupe/log/fold_test.exs:20` |
| A sample Elixir project | `fixtures/sample_repo/` (with a committed `_build/test`) |
| Protocol JSON Schema | `protocol/schema/v1/commands/*.json`, `events/*.json`, `index.json` (`{"version": "1", "documents": [...]}`) |
| Database migrations | `apps/troupe_plane/priv/repo/migrations/` |
| CRDs | `charts/troupe/crds/{workerprofile,teamvolume,troupepolicy}.yaml`; the admission policy is a template, `charts/troupe/templates/admission-policy.yaml` |
| Design tokens | `docs/design/admin/tokens.json` (with `DESIGN.md`, `example.dc.html`, `support.js`) |
| Python conformance fixture | `apps/troupe_gateway/test/conformance/troupe.py` and `conformance.py` — a test fixture under the suite that runs it, not a client this repository publishes |

## 4. Generated files and the task that writes each

| Generated | Task | Checked how |
|---|---|---|
| `protocol/schema/v1/**` | `mix troupe.schema.gen` (`apps/troupe_protocol/lib/mix/tasks/troupe.schema.gen.ex`) from `Troupe.Protocol.Schema.documents/0` | CI runs `mix troupe.schema.diff` and then `mix troupe.schema.gen && git diff --exit-code protocol/schema/v1` (`.github/workflows/ci.yml:229-236`) |
| `apps/troupe_plane/priv/static/app.js` | `mix troupe.admin.assets` (`troupe.admin.assets.ex:34-42`) from the `phoenix`, `phoenix_html`, `phoenix_live_view` UMD bundles in `deps/` | `mix troupe.admin.assets --check`; the moduledoc says CI runs it (`:28-29`), but `ci.yml` contains no such step. Discrepancy: not in CI. `apps/troupe_plane/test/troupe/plane/console_assets_test.exs` checks the document's assets exist on disk |
| `apps/troupe_plane/priv/static/tokens.css` and `apps/troupe_plane/priv/design/statuses.json` | `mix troupe.admin.tokens` (`troupe.admin.tokens.ex:35-43`) from `docs/design/admin/tokens.json` | `mix troupe.admin.tokens --check`; same caveat, not in `ci.yml` |
| `apps/troupe_plane/priv/static/theme.css` | `mix troupe.theme` (`troupe.theme.ex:45-64`) from `docs/design/themes/signal.tokens.json`, through the same renderer as the console's tokens | `mix troupe.theme --check`; same caveat, not in `ci.yml`. `apps/troupe_plane/test/troupe/plane/front_page_assets_test.exs` checks the front page's assets exist, are allowlisted and are served |
| `apps/troupe_plane/priv/static/brand/{favicon.ico,apple-touch-icon.png}` | `python scripts/brand-icons.py` — the two icon formats that cannot be SVG, rasterised from the mask geometry with Pillow. Not part of the build | the same suite checks they exist and are non-empty; nothing checks they match the SVGs |
| `apps/troupe_core/priv/reaper/<triple>/reaper` | `mix compile.reaper`, run automatically as a compiler (`apps/troupe_core/mix.exs:15`); host triple by default, all five with `TROUPE_REAPER_TARGETS=all` (`compile.reaper.ex:78-84`) | gitignored (`.gitignore:8`) and excluded from the image context (`.dockerignore:17`) |
| `test/fixtures/logs/<version>/` | `mix troupe.fixtures.record <version>`, once per release, refuses to overwrite (`troupe.fixtures.record.ex:26-37`) | `apps/troupe_core/test/troupe/log/fold_test.exs` replays every version |

## 5. What the image build sees

`docker/Dockerfile:25-43` copies `mix.exs`, `mix.lock`, each `apps/*/mix.exs`, then
`config/`, `apps/` and `native/`, and nothing else. `.dockerignore` removes `clients/`
entirely (the GUI's image is built with `clients/gui` as its own context), `_build`,
`deps`, `apps/*/priv/reaper`, every `test/` directory (which is where the Python
conformance fixture now lives), `fixtures`, `docs`, `charts`, `dev`, `scripts` and
`*.md`. This is why
`priv/design/statuses.json` is vendored into the app instead of read from `docs/`
(`troupe.admin.tokens.ex:38-43`).
