# Repository structure

```
.
├── AGENTS.md                notes for coding agents; points at fixing-issues.md
├── ARCHITECTURE.md          the design, and the contract between daemon, plane and clients
├── PROTOCOL.md              the normative wire document for client authors
├── README.md                the front door
├── VERSION                  the one version of everything released (Decision 668)
├── mkdocs.yml               the documentation site: docs/ and the documents its nav names (Decision 739)
├── .github/                 the workflows (ci.md) and Dependabot
├── apps/                    the umbrella: eight Mix projects (architecture.md §1)
├── charts/troupe/           the Helm chart (platform and GUI), its CRDs, values.small/example
├── clients/tui/             the terminal client: its own Mix project, the harness by path
├── clients/gui/             the graphical client: a pnpm workspace (client, bench, desktop)
├── clients/vscode/          the VS Code extension that opens the TUI in a VS Code terminal: a pnpm project
├── config/                  config.exs (compile time) and runtime.exs (prod only)
├── dev/                     docker-compose.yml, kind/ (dependencies, values), toolbox/
├── docker/Dockerfile        the four server images
├── docs/                    the user, admin and developer tracks, decisions/ (a file per decision), design/, plans/; overrides/ is the site's theme and hooks
├── fixtures/sample_repo/    a small Mix project the core's workspace tests read
├── install.sh, install.ps1  install troupe and troupe-daemon from a release
├── mix.exs, mix.lock        the umbrella: the check alias, four releases, credo
├── protocol/schema/v1/      GENERATED JSON Schema (commands/, events/, index.json)
├── scripts/                 dev-up, toolbox, remote-up, build-images, release, pitr-drill, version.exs, locks-agree.exs, doc-links.exs, check-neutral.exs, console-rig.exs, …
└── test/fixtures/logs/      recorded log fixtures, one directory per released version
```

Gitignored and local: `.local/` (a person's own kubeconfigs and values, never committed),
`/.worktrees/`, `apps/troupe_core/priv/reaper/`, and `site/`, what `mkdocs build` writes.

The root holds what somebody arriving at the repository needs, and what a tool reads from
there; everything else is under a directory (Decision 739). Documents that code, CI or
GitHub read where they are stay where they are, and the site shows them from there: the
nav of `mkdocs.yml` names them by their path from the root, and
`docs/overrides/hooks.py` puts them on the site and points their links at it.

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
| `apps/troupe_daemon/` | its own `config/runtime.exs` and README |
| `charts/troupe/crds/` | `WorkerProfile`, `TeamVolume`, `TroupePolicy`, `Trigger`, hand-written; the admission policy is a template |
| `docs/design/admin/tokens.json` | the console's design tokens |
| `clients/gui/docs/design/themes/*.tokens.json` | the four themes: the GUI's, the front page's (Signal) and the TUI's (Afterglow), one copy |

Generated files and what writes them: [build.md §3](build.md#3-generated-committed-files).

## What the image build sees

`docker/Dockerfile` copies `mix.exs`, `mix.lock`, each `apps/*/mix.exs`, `config/` and
`apps/`. `.dockerignore` removes `clients/`, `_build`, `deps`, `priv/reaper`, every
`test/`, `fixtures`, `docs`, `charts`, `dev`, `scripts` and `*.md` — which is why
`statuses.json` is vendored into the plane rather than read from `docs/`.
