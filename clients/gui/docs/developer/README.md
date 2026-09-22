> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).
> The GUI now lives at `clients/gui` in the Troupe repository; CI, release and deployment are the root's (root Decisions 666, 669, 670).

# Developer track

Documentation for someone changing the GUI: the graphical client for Troupe, at
`clients/gui` in the Troupe repository, a pnpm workspace of `packages/client` (the
protocol in TypeScript), `packages/bench` (a throughput test) and `apps/desktop` (the
Vite + React GUI). The server it talks to is in the same repository, documented at
[../../../../docs/](../../../../docs/README.md); protocol semantics live in the root
[PROTOCOL.md](../../../../PROTOCOL.md) and are not restated here.

Read [../AUDIT.md](../AUDIT.md) first if you have not: at audit time `HEAD` (`783e660`)
did not contain most of what these pages describe — the stage-1 work was one large
uncommitted change ([repo-structure.md](repo-structure.md) lists what was tracked and what
was not).

## Pages

| Page | What it covers |
|---|---|
| [architecture.md](architecture.md) | The three packages and the boundary rule; every module in `packages/client/src` and `apps/desktop/src` with its protocol calls; the two sign-in flows and where tokens live; the attachment lifecycle; the fold; the fleet store |
| [tech-stack.md](tech-stack.md) | Node 24, pnpm 10.15, TypeScript 5.9 and its strict flags, Vite 7, React 19, Plex fonts, `node --test`, `tsx`, `ws`, nginx-unprivileged, Helm — each with the line that declares it |
| [repo-structure.md](repo-structure.md) | Annotated tree; what is generated; committed versus uncommitted; the `.local/` directory |
| [local-setup.md](local-setup.md) | Prerequisites, the root scripts, `pnpm fake`, running against a real plane, the bench, `first-token`, tokens, and every development variable |
| [testing.md](testing.md) | The 33 tests by file and what each proves; the fake deployment; typechecking tests; what is not tested |
| [build.md](build.md) | `pnpm build` per package, the base path, the Dockerfile stage by stage, `nginx.conf`, `.dockerignore` |
| [ci-cd.md](ci-cd.md) | The root workflows' GUI jobs: tests, the end-to-end suite, the image, the desktop installers; secrets; tags; how a release ships and deploys it |
| [deployment.md](deployment.md) | The `gui:` block of the platform's chart, the root `scripts/deploy`, the base-path contract, the recorded live deployment, rollback, staging |
| [conventions.md](conventions.md) | Strictness, open types, no framework in the client, generated tokens, design rules, `DECISIONS.md`/`REPORT.md`, commits, LF, adding a method or a view |

Other tracks: [../user/README.md](../user/README.md) and
[../user/features.md](../user/features.md) for what a person sees;
[../admin/README.md](../admin/README.md) for operating it; [../whitepaper.md](../whitepaper.md)
for diagrams and rationale.

## Self-check: CI

The GUI has no workflow of its own. Its jobs are in the root
[`ci.yml`](../../../../.github/workflows/ci.yml) and
[`release.yml`](../../../../.github/workflows/release.yml); each one that builds, tests or
ships it, and where it is documented:

| Workflow | Job | What it does for the GUI | Documented in |
|---|---|---|---|
| `ci.yml` | `changes` | Decides what a pull request runs: `gui` for any change under `clients/gui/`, `gui-e2e` for the client package, `dev/` or the plane's side of the protocol | [ci-cd.md](ci-cd.md) |
| `ci.yml` | `gui` | In `clients/gui`: `pnpm install --frozen-lockfile`, `pnpm tokens:check`, `pnpm typecheck`, `pnpm build`, `pnpm test` | [ci-cd.md](ci-cd.md) "`gui`"; [local-setup.md](local-setup.md) "The root scripts"; [testing.md](testing.md) |
| `ci.yml` | `gui-e2e` | `dev/plane-stack.yml` with the plane built from the same commit, then `test/e2e.plane.test.ts` against it | [ci-cd.md](ci-cd.md) "`gui-e2e`"; [../e2e.md](../e2e.md) |
| `ci.yml` | `chart` | `helm lint` and `kubeconform` on the platform's chart with the GUI on and off; `gui.basePath: /` must be refused | [ci-cd.md](ci-cd.md) "`chart`"; [deployment.md](deployment.md) |
| `ci.yml` | `images` | Builds `troupe-gui` from `clients/gui` with `TROUPE_GUI_BASE` and pushes `sha-<short>` | [ci-cd.md](ci-cd.md) "The image"; [build.md](build.md) |
| `ci.yml` | `versions` | `scripts/version.exs check`: the GUI's package, Tauri and Cargo versions agree with `VERSION` | [ci-cd.md](ci-cd.md) "`versions`" |
| `ci.yml` | `release`, `publish`, `deploy` | Promote `troupe-gui` to the release's version, attach the installers, roll the chart onto production | [ci-cd.md](ci-cd.md) "Releasing and deploying"; [deployment.md](deployment.md) |
| `release.yml` | `desktop` | The installers for macOS, Windows and Linux | [ci-cd.md](ci-cd.md) "`desktop`"; [../install.md](../install.md) |

## Self-check: development, build and deploy variables

There is no `.env`, no `.env.example`, and no `VITE_*` variable (AUDIT §1.4).

| Variable | Read at | Documented in |
|---|---|---|
| `TROUPE_GUI_BASE` | `apps/desktop/vite.config.ts:16`; `Dockerfile:38-39`; the root `ci.yml`'s `images` job | [build.md](build.md) "The base path"; [deployment.md](deployment.md) "The base-path contract"; [local-setup.md](local-setup.md) table |
| `import.meta.env.BASE_URL` (derived) | `apps/desktop/src/shell.ts:93, 107` | [architecture.md](architecture.md) §3 `shell.ts`; [build.md](build.md) |
| `ORIGINS` | `scripts/fake-deployment.ts:14` | [local-setup.md](local-setup.md) "pnpm fake" |
| `TROUPE_DEV_HOME`, `TROUPE_DAEMON_BIN`, `VITE_TROUPE_LOCAL_ONLY`, `VITE_TROUPE_DAEMON` | `scripts/dev-local.ts`; `apps/desktop/src/mode.ts`, `shell.ts` | [local-setup.md](local-setup.md) "pnpm dev:local" |
| `RUNS` | `scripts/first-token.ts:15` | [local-setup.md](local-setup.md) "pnpm first-token" |
| `BENCH_MODE`, `BENCH_CLIENTS`, `BENCH_PROMPTS`, `BENCH_WORKSPACE`, `BENCH_OUT` | `packages/bench/src/main.ts:27-31` | [local-setup.md](local-setup.md) "Every development variable" |
| `BENCH_SIGNING_KEY`, `BENCH_POD_ID`, `BENCH_WS` | `main.ts:42-44`; `trace.ts:13-15` | [local-setup.md](local-setup.md) |
| `BENCH_PLANE`, `BENCH_PLANE_TOKEN`, `BENCH_PROFILE` | `main.ts:63-65` | [local-setup.md](local-setup.md) |
| `BENCH_AGENT`, `TRACE_SECONDS` | `trace.ts:26`, `:16` | [local-setup.md](local-setup.md) |
| `KUBECONFIG_FILE`, `VALUES`, `NAMESPACE`, `RELEASE`, `PLANE_URL`, `EXPECT_COMMIT` | the root `scripts/deploy` | [deployment.md](deployment.md) "The root `scripts/deploy`" |
| CI secrets `REGISTRY`, `REGISTRY_NAMESPACE`, `REGISTRY_USERNAME`, `REGISTRY_PASSWORD`; variable `GUI_BASE`; the `production` environment's `KUBECONFIG`, `DEPLOY_VALUES` and `PLANE_URL` | the root `ci.yml` and `deploy.yml` | [ci-cd.md](ci-cd.md) "The image", "Releasing and deploying" |
| Node's version | the root `.tool-versions`, which CI reads | [tech-stack.md](tech-stack.md) |

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
