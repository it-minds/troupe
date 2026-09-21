> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).

# Developer track

Documentation for someone changing this repository: the graphical client for Troupe,
a pnpm workspace of `packages/client` (the protocol in TypeScript), `packages/bench`
(a throughput test) and `apps/desktop` (the Vite + React GUI). The server it talks to
is a separate repository, `troupe-remote`, documented at
[../../../../docs/](../../../../docs/AUDIT.md); protocol semantics
live in its [PROTOCOL.md](../../../../PROTOCOL.md) and are not restated here.

Read [../AUDIT.md](../AUDIT.md) first if you have not: `HEAD` (`783e660`) does not
contain most of what these pages describe — the stage-1 work is one large uncommitted
change ([repo-structure.md](repo-structure.md) lists what is tracked and what is not).

## Pages

| Page | What it covers |
|---|---|
| [architecture.md](architecture.md) | The three packages and the boundary rule; every module in `packages/client/src` and `apps/desktop/src` with its protocol calls; the two sign-in flows and where tokens live; the attachment lifecycle; the fold; the fleet store |
| [tech-stack.md](tech-stack.md) | Node 24, pnpm 10.15, TypeScript 5.9 and its strict flags, Vite 7, React 19, Plex fonts, `node --test`, `tsx`, `ws`, nginx-unprivileged, Helm — each with the line that declares it |
| [repo-structure.md](repo-structure.md) | Annotated tree; what is generated; committed versus uncommitted; the `.local/` directory |
| [local-setup.md](local-setup.md) | Prerequisites, the root scripts, `pnpm fake`, running against a real plane, the bench, `first-token`, tokens, and every development variable |
| [testing.md](testing.md) | The 33 tests by file and what each proves; the fake deployment; typechecking tests; what is not tested |
| [build.md](build.md) | `pnpm build` per package, the base path, the Dockerfile stage by stage, `nginx.conf`, `.dockerignore` |
| [ci-cd.md](ci-cd.md) | Every job and step of the untracked, never-run workflow; secrets; tags; the ordering risk; no deploy job |
| [deployment.md](deployment.md) | The chart, `scripts/deploy`, the base-path contract, the recorded live deployment, rollback, no staging |
| [conventions.md](conventions.md) | Strictness, open types, no framework in the client, generated tokens, design rules, `DECISIONS.md`/`REPORT.md`, commits, LF, adding a method or a view |

Other tracks: [../user/README.md](../user/README.md) and
[../user/features.md](../user/features.md) for what a person sees;
[../admin/README.md](../admin/README.md) for operating it; [../whitepaper.md](../whitepaper.md)
for diagrams and rationale.

## Self-check: CI

`.github/workflows/ci.yml` is untracked and has never run (AUDIT §1.5). Every job and
step in it, and where it is documented:

| Job | Step | Line | Documented in |
|---|---|---|---|
| `check` | `actions/checkout@v4` | `ci.yml:29` | [ci-cd.md](ci-cd.md) |
| `check` | `pnpm/action-setup@v4` | `:31` | [tech-stack.md](tech-stack.md) "Runtime and package manager" |
| `check` | `actions/setup-node@v4` (Node 24, pnpm cache) | `:33-36` | [tech-stack.md](tech-stack.md) |
| `check` | `pnpm install --frozen-lockfile` | `:38` | [local-setup.md](local-setup.md) "Install" |
| `check` | `pnpm tokens:check` | `:42-43` | [local-setup.md](local-setup.md) "pnpm tokens", [conventions.md](conventions.md) "The generated stylesheet" |
| `check` | `pnpm typecheck` | `:45` | [local-setup.md](local-setup.md) "The root scripts"; ordering risk in [ci-cd.md](ci-cd.md) |
| `check` | `pnpm build` | `:49` | [build.md](build.md) "pnpm build" |
| `check` | `pnpm test` | `:51` | [testing.md](testing.md) |
| `image` | `actions/checkout@v4` | `:64` | [ci-cd.md](ci-cd.md) |
| `image` | Resolve the registry and the tags | `:71-92` | [ci-cd.md](ci-cd.md) "Job image", "Tags" |
| `image` | `docker/setup-buildx-action@v3` | `:94` | [ci-cd.md](ci-cd.md) |
| `image` | `docker/login-action@v3` | `:96-100` | [ci-cd.md](ci-cd.md) "Secrets and variables" |
| `image` | `docker/build-push-action@v6` | `:105-114` | [ci-cd.md](ci-cd.md); the Dockerfile in [build.md](build.md) |
| `chart` | `actions/checkout@v4`, `azure/setup-helm@v4` | `:120-121` | [ci-cd.md](ci-cd.md) "Job chart" |
| `chart` | `helm lint` | `:123` | [ci-cd.md](ci-cd.md) |
| `chart` | `helm template … \| kubeconform` | `:128-134` | [ci-cd.md](ci-cd.md); the chart in [deployment.md](deployment.md) |

## Self-check: development, build and deploy variables

There is no `.env`, no `.env.example`, and no `VITE_*` variable (AUDIT §1.4).

| Variable | Read at | Documented in |
|---|---|---|
| `TROUPE_GUI_BASE` | `apps/desktop/vite.config.ts:16`; `Dockerfile:38-39`; `ci.yml:109` | [build.md](build.md) "The base path"; [deployment.md](deployment.md) "The base-path contract"; [local-setup.md](local-setup.md) table |
| `import.meta.env.BASE_URL` (derived) | `apps/desktop/src/shell.ts:93, 107` | [architecture.md](architecture.md) §3 `shell.ts`; [build.md](build.md) |
| `ORIGINS` | `scripts/fake-deployment.ts:14` | [local-setup.md](local-setup.md) "pnpm fake" |
| `RUNS` | `scripts/first-token.ts:15` | [local-setup.md](local-setup.md) "pnpm first-token" |
| `BENCH_MODE`, `BENCH_CLIENTS`, `BENCH_PROMPTS`, `BENCH_WORKSPACE`, `BENCH_OUT` | `packages/bench/src/main.ts:27-31` | [local-setup.md](local-setup.md) "Every development variable" |
| `BENCH_SIGNING_KEY`, `BENCH_POD_ID`, `BENCH_WS` | `main.ts:42-44`; `trace.ts:13-15` | [local-setup.md](local-setup.md) |
| `BENCH_PLANE`, `BENCH_PLANE_TOKEN`, `BENCH_PROFILE` | `main.ts:63-65` | [local-setup.md](local-setup.md) |
| `BENCH_AGENT`, `TRACE_SECONDS` | `trace.ts:26`, `:16` | [local-setup.md](local-setup.md) |
| `KUBECONFIG_FILE`, `VALUES`, `NAMESPACE`, `RELEASE`, `TAG` | `scripts/deploy:23-26, 39` | [deployment.md](deployment.md) "scripts/deploy" |
| CI secrets `REGISTRY`, `REGISTRY_NAMESPACE`, `REGISTRY_USERNAME`, `REGISTRY_PASSWORD`; variable `GUI_BASE`; env `NODE_VERSION` | `ci.yml:74-75, 99-100, 109, 22` | [ci-cd.md](ci-cd.md) "Secrets and variables" |

Browser storage keys (`troupe.auth.refresh:<planeUrl>`, `troupe.auth.pending`,
`troupe.pref.planeUrl`, `troupe.pref.theme`) and the Helm values are inventoried in the
admin track: [../admin/README.md](../admin/README.md).

## Findings a developer should know before starting

From [../AUDIT.md](../AUDIT.md), the ones that change how you work:

- `README.md:85` says 20 tests; there are 33 ([testing.md](testing.md)).
- `.dockerignore` does not exclude `.local/` ([build.md](build.md)).
- CI typechecks before it builds, and the bench resolves the client through `dist/`
  ([ci-cd.md](ci-cd.md)).
- `hooks.ts` polls every 4 s while `FleetStore.poll` defaults to 5 s
  ([architecture.md](architecture.md) §7).
- Opening a session from the list uses `activate`; the banner says reading does not
  wake it ([architecture.md](architecture.md) §5).
- Browser sign-in against `pnpm fake` may not complete now that browsers use the
  redirect flow — flagged, unexecuted, in [local-setup.md](local-setup.md).
