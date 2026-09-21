> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).
> The GUI now lives at `clients/gui` in the Troupe repository; its chart and CI are the root's (root Decisions 666, 670).

# Tech stack

Every tool the repository depends on, with the line that declares it and the decision
that justifies it where one is recorded. Resolved versions come from `pnpm-lock.yaml`
(`lockfileVersion: '9.0'`, `pnpm-lock.yaml:1`) and from the tools on the audit machine.

## Runtime and package manager

| Tool | Declared | Resolved / observed | Why |
|---|---|---|---|
| Node 24 | `Dockerfile:20` (`node:24-bookworm-slim`), the root `.tool-versions` (`nodejs 24.19.0`, which CI's `setup-node` reads), `@types/node ^24.3.0` (`packages/client/package.json:23`) | `node --version` → v24.12.0 on the audit machine | The tests run on Node's built-in runner with `--import tsx`; no `engines` field pins it in any manifest |
| pnpm 10.15.0 | `package.json:5` `"packageManager": "pnpm@10.15.0"` | 10.15.0 on the audit machine; Corepack pins it in the image (`Dockerfile:22-24`) and `pnpm/action-setup` reads it in the root CI's `gui` job | One version for developers, the image and CI |
| pnpm workspace | `pnpm-workspace.yaml:1-3` (`packages/*`, `apps/*`) | — | Three packages, one lockfile |
| `.npmrc` | `strict-peer-dependencies=false` (`.npmrc:1`) | — | No decision recorded |

## Language

| Tool | Declared | Resolved | Why |
|---|---|---|---|
| TypeScript 5.9 | `typescript ^5.9.2` in every manifest (`package.json:19`, `packages/client/package.json:26`, `packages/bench/package.json:16`, `apps/desktop/package.json:23`) | 5.9.3 (`pnpm-lock.yaml:653`) | — |
| `tsx` | `package.json:18` (`^4.23.13`), `packages/client/package.json:25`, `packages/bench/package.json:15` | 4.23.13 (`pnpm-lock.yaml:648`) | Runs `scripts/*.ts`, the bench and the tests without a build step (`package.json:12-15`, `packages/client/package.json:20`, `packages/bench/package.json:7`) |

### Strictness (`tsconfig.base.json`)

| Flag | Line | Effect |
|---|---|---|
| `target: ES2022`, `module: ESNext`, `moduleResolution: Bundler` | `:3-5` | Native ESM everywhere; `"type": "module"` in every manifest |
| `strict: true` | `:6` | The usual set |
| `noUncheckedIndexedAccess: true` | `:7` | Every index read is `T \| undefined`; the code uses `!` deliberately where an index is known (`packages/client/src/session.ts:102`, `fleet.ts:211`) |
| `exactOptionalPropertyTypes: true` | `:8` | An optional property cannot be set to `undefined` explicitly, which is why option objects are spread conditionally (`packages/client/src/pkce.ts:172-173`, `apps/desktop/src/views/Sessions.tsx:191-193`) and several option types say `\| undefined` explicitly (`packages/client/src/connection.ts:43-49`) |
| `isolatedModules`, `declaration`, `sourceMap`, `esModuleInterop`, `skipLibCheck`, `forceConsistentCasingInFileNames` | `:9-14` | `declaration` gives `@troupe/client` its `.d.ts` in `dist/` |

Per-package overrides: the client emits to `dist` from `src` with `lib: ["ES2022",
"DOM"]` and `types: []` (`packages/client/tsconfig.json:4-7`); its tests add `types:
["node"]` and `noEmit` (`packages/client/tsconfig.test.json:4-7`); the bench and the
desktop app are `noEmit` (`packages/bench/tsconfig.json:3`, `apps/desktop/tsconfig.json:4`);
the desktop app adds `jsx: react-jsx`, `DOM.Iterable`, `types: ["vite/client"]` and the
`paths` alias (`apps/desktop/tsconfig.json:5-19`).

Why the alias: `DECISIONS.md` #17 (Vite resolves the client to source so a change
reaches the running app without a separate build) and #26 (`tsc` must resolve the same
way, or a typecheck passes against stale `.d.ts`). The comment at
`apps/desktop/tsconfig.json:14-16` says the same.

## Front end

| Tool | Declared | Resolved | Why |
|---|---|---|---|
| Vite 7 | `vite ^7.1.5` (`apps/desktop/package.json:24`) | 7.3.6 (`pnpm-lock.yaml:667`) | `dev` and `build` scripts (`apps/desktop/package.json:7-8`); `base` from `TROUPE_GUI_BASE`, `target: es2022`, `sourcemap: true`, port 5173 `strictPort` (`apps/desktop/vite.config.ts:16-31`) |
| `@vitejs/plugin-react` | `^5.0.2` (`apps/desktop/package.json:22`) | 5.2.0 (`pnpm-lock.yaml:512`) | `apps/desktop/vite.config.ts:3, 21` |
| React 19 | `react ^19.1.1`, `react-dom ^19.1.1` (`apps/desktop/package.json:16-17`); types `^19.1.12` / `^19.1.9` (`:20-21`) | 19.3.0 (`pnpm-lock.yaml:624`) | `createRoot` under `StrictMode` (`apps/desktop/src/main.tsx:2, 7`). StrictMode's double effect is why code redemption is memoised (`DECISIONS.md` #28) |
| `@fontsource/ibm-plex-sans`, `@fontsource/ibm-plex-mono` | `^5.3.0` (`apps/desktop/package.json:13-14`) | 5.3.0 (`pnpm-lock.yaml:327, 330`) | Imported at `apps/desktop/src/styles.css:16-20`; the typeface choice is `docs/design/DESIGN.md` §1 "Typeface" (`DESIGN.md:31-33`). Self-hosted, so the bundle makes no font request to a third party |
| No router, no state library | — | — | `App.tsx:3-5` "There is no router and no session state" |

## Tests

| Tool | Declared | Why |
|---|---|---|
| `node --test` | `packages/client/package.json:20`: `node --test --import tsx "test/**/*.test.ts"` | Node's built-in runner; no Jest or Vitest. `node:assert/strict` and `node:test` are the only test imports (`packages/client/test/stage1.test.ts:9-10`) |
| `ws` 8 | `ws ^8.21.3`, `@types/ws ^8.18.1` — dev dependencies only (`packages/client/package.json:24, 27`) | The fake worker is a real `WebSocketServer` (`packages/client/test/support/worker.ts:16, 103`). The client itself uses the global `WebSocket` or an injected constructor (`packages/client/src/connection.ts:49, 110`) |
| Playwright | not present | Planned by `spec.md:62`; `REPORT.md:288-291` lists its absence |

Discrepancy: `README.md:12` says the client has "no dependencies". True at runtime; `ws`
is a dev dependency (AUDIT §2).

## Shipping

| Tool | Declared | Why |
|---|---|---|
| Docker, multi-stage | `Dockerfile:20` build stage on `node:24-bookworm-slim`; `Dockerfile:48` runtime on `nginxinc/nginx-unprivileged:1.29-alpine` | The image runs the client tests on the way through (`Dockerfile:43-45`; `DECISIONS.md` #33) |
| nginx (unprivileged) | `docker/nginx.conf`; port 8080, uid 101 (`Dockerfile:50-51`) | SPA fallback, `/healthz`, immutable hashed assets (`docker/nginx.conf:33-50`) |
| Helm 3 chart (`apiVersion: v2`) | The `gui:` block of the root `charts/troupe`, whose version and appVersion are the root `VERSION` | The root `scripts/deploy` runs `helm upgrade --install` for the whole platform, the GUI with it |
| `kubeconform` v0.6.7 | The root CI's `chart` job (`ghcr.io/yannh/kubeconform:v0.6.7`, `-kubernetes-version 1.31.0`) | Validates the rendered chart, with the GUI and without it |
| GitHub Actions | The root `.github/workflows/ci.yml` (`gui`, `gui-e2e`, `images`) and `release.yml` (`desktop`) | `actions/checkout`, `pnpm/action-setup`, `actions/setup-node`, `docker/build-push-action`, `tauri-apps/tauri-action`; see [ci-cd.md](ci-cd.md) |

## Formatting and line endings

| Setting | Where |
|---|---|
| LF, final newline, UTF-8, two-space indent | `.editorconfig:1-8` |
| `* text=auto eol=lf`, `*.png binary` | `.gitattributes:1-2` |
| No linter, no formatter | No ESLint, Prettier or Biome configuration exists in the tree; nothing in `package.json:6-16` runs one |

## Related

- [local-setup.md](local-setup.md) — installing the above.
- [build.md](build.md) — what each tool produces.
- [conventions.md](conventions.md) — how the strict flags shape the code.
