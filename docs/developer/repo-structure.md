# Repository structure

```
.
├── AGENTS.md                notes for coding agents; points at fixing-issues.md
├── ARCHITECTURE.md          the design, and the contract between daemon, plane and clients
├── DECISIONS.md             every judgment call, numbered, newest at the bottom
├── PROTOCOL.md              the normative wire document for client authors
├── README.md                the front door
├── VERSION                  the one version of everything released (Decision 668)
├── .github/                 workflows and CI.md
├── apps/                    the umbrella: eight Mix projects (architecture.md §1)
├── charts/troupe/           the Helm chart (platform and GUI), its CRDs, values.small/scaleway
├── clients/tui/             the terminal client: its own Mix project, the harness by path
├── clients/gui/             the graphical client: a pnpm workspace (client, bench, desktop)
├── config/                  config.exs (compile time) and runtime.exs (prod only)
├── deploy/                  ci-deployer.yaml (the account CI deploys as); scaleway/ values
├── dev/                     docker-compose.yml, kind/ (dependencies, values), toolbox/
├── docker/Dockerfile        the four server images
├── docs/                    the admin, developer and user tracks, design/, plans/
├── fixtures/sample_repo/    a small Mix project the core's workspace tests read
├── install.sh, install.ps1  install troupe and troupe-daemon from a release
├── mix.exs, mix.lock        the umbrella: the check alias, four releases, credo
├── protocol/schema/v1/      GENERATED JSON Schema (commands/, events/, index.json)
├── scripts/                 dev-up, toolbox, remote-up, build-images, release, deploy, pitr-drill, version.exs, locks-agree.exs, doc-links.exs, …
└── test/fixtures/logs/      recorded log fixtures, one directory per released version
```

Gitignored and local: `.local/` (a real deployment's kubeconfig and values, read by
`scripts/deploy`), `/.worktrees/`, `apps/troupe_core/priv/reaper/`.

## Apps

Each has `lib/`, `test/troupe/**/*_test.exs`, `test/support/` (compiled only in test)
and `priv/` where it ships data, and shares the root's `_build`, `deps`, `mix.lock` and
`config/`. Notable locations:

| Where | What |
|---|---|
| `apps/troupe_core/priv/agents/*.md` | the built-in agent definitions |
| `apps/troupe_core/native/reaper/reaper.zig` | the process-tree reaper, one source for every target |
| `apps/troupe_core/lib/mix/tasks/` | `compile.reaper`, `troupe.boundaries`, `troupe.fixtures.record` |
| `apps/troupe_protocol/lib/mix/tasks/` | `troupe.schema.gen`, `troupe.schema.diff`, `troupe.egress`, `troupe.release.check` |
| `apps/troupe_plane/lib/mix/tasks/` | `troupe.admin.assets`, `troupe.admin.tokens`, `troupe.theme`, `troupe.index.rebuild`, `troupe.ledger.reconcile` |
| `apps/troupe_plane/priv/repo/migrations/` | the database |
| `apps/troupe_plane/priv/static/` | the console's and front page's assets, mostly generated |
| `apps/troupe_plane/lib/troupe/plane/admin/api.ex` | the admin method table |
| `apps/troupe_operator/lib/mix/tasks/troupe.e2e.ex` | the cluster suite |
| `apps/troupe_gateway/test/conformance/` | the Python conformance client, a test fixture |
| `apps/troupe_daemon/` | its own `config/runtime.exs`, README and DECISIONS |
| `charts/troupe/crds/` | `WorkerProfile`, `TeamVolume`, `TroupePolicy`, hand-written; the admission policy is a template |
| `docs/design/admin/tokens.json`, `docs/design/themes/*.tokens.json` | the console's and the front page's design tokens |

Generated files and what writes them: [build.md §3](build.md#3-generated-committed-files).

## What the image build sees

`docker/Dockerfile` copies `mix.exs`, `mix.lock`, each `apps/*/mix.exs`, `config/` and
`apps/`. `.dockerignore` removes `clients/`, `_build`, `deps`, `priv/reaper`, every
`test/`, `fixtures`, `docs`, `charts`, `dev`, `scripts` and `*.md` — which is why
`statuses.json` is vendored into the plane rather than read from `docs/`.
