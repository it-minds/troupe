> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).
> The GUI now lives at `clients/gui` in the Troupe repository; run everything below from that directory (root Decision 666).

# Local setup

Getting the workspace running on a developer machine, against the fake deployment or a
real plane, and every development variable the scripts read.

## Prerequisites

| Requirement | Why | Where declared |
|---|---|---|
| Node 24 | The tests use Node's built-in runner; the image and CI use 24 | `Dockerfile:20`, the root `.tool-versions` (which CI reads), `@types/node ^24.3.0` (`packages/client/package.json:23`) |
| pnpm 10.15.0 | `packageManager` pin; `corepack enable` gives it to you | `package.json:5` |
| Git with LF checkout | `.gitattributes:1` normalises to LF; `pnpm tokens:check` diffs a generated file and CRLF would fail it | `.gitattributes:1`, `package.json:14` |
| Docker (optional) | Only for `docker build` and the bench's worker container | `Dockerfile`, `docs/bench.md:33-41` |
| Helm 3, kubectl (optional) | Only for the root `scripts/deploy`, which deploys the platform's chart with the GUI in it | [deployment.md](deployment.md) |

No Elixir, no cluster and no browser driver is needed for `pnpm test`.

## Install

```bash
pnpm install
```

The lockfile is `pnpm-lock.yaml`; the image and CI use `--frozen-lockfile`
(`Dockerfile:34`; the root `ci.yml`'s `gui` job).

## The root scripts

`package.json:6-16`:

| Command | Runs | What it does |
|---|---|---|
| `pnpm build` | `pnpm -r build` | `tsc` for the client (`packages/client/package.json:18`); `tsc --noEmit && vite build` for the desktop app (`apps/desktop/package.json:8`). The bench has no `build` script |
| `pnpm test` | `pnpm -r test` | The client: `node --test --import tsx "test/**/*.test.ts"` (`packages/client/package.json:20`). The desktop app: `vitest run`, the app rendered in jsdom against the fake daemon ([testing.md](testing.md) "The app's tests") |
| `pnpm typecheck` | `pnpm -r typecheck` | Client: `tsc --noEmit` on `src` and on `tsconfig.test.json` (`packages/client/package.json:19`); bench: `tsc --noEmit` (`packages/bench/package.json:8`); desktop: `tsc --noEmit` (`apps/desktop/package.json:9`). See the ordering caveat under [ci-cd.md](ci-cd.md): the bench resolves `@troupe/client` through `dist/`, so run `pnpm build` once first in a clean checkout |
| `pnpm dev` | `pnpm --filter @troupe/desktop dev` | Vite on `http://localhost:5173`, `strictPort` (`apps/desktop/vite.config.ts:30`) |
| `pnpm dev:local` | `tsx scripts/dev-local.ts` | A daemon of its own with the scripted `fake` model, and Vite in local-only mode against it; see below |
| `pnpm fake` | `tsx scripts/fake-deployment.ts` | A fake IdP, plane and worker on loopback; see below |
| `pnpm bench` | `pnpm --filter @troupe/bench start` | `tsx src/main.ts` (`packages/bench/package.json:7`) |
| `pnpm tokens` | `tsx scripts/tokens.ts` | Regenerates `apps/desktop/src/tokens.css` |
| `pnpm tokens:check` | `tsx scripts/tokens.ts && git diff --exit-code apps/desktop/src/tokens.css` | Fails if the committed file is stale |
| `pnpm first-token` | `tsx scripts/first-token.ts` | Sign-in-to-first-delta timing against the fakes |

Run one:

```bash
pnpm dev
```

```bash
pnpm test
```

```bash
pnpm typecheck
```

## `pnpm dev:local` — this computer alone

The default way to develop the GUI: no plane, no identity provider, no key
(`DECISIONS.md` #46). `scripts/dev-local.ts` finds `troupe-daemon` the way the desktop
shell does (`TROUPE_DAEMON_BIN`, the `PATH`, the installers' directories), starts it with
`TROUPE_PROVIDER=fake` and a `script.json`, and gives it its own state, config and
`daemon.json` under `TROUPE_DEV_HOME` — by default `troupe-dev-local` in the system's temp
directory — so it is a second daemon beside yours. A development daemon that is already
answering there is reused. Then it runs `pnpm dev` with `VITE_TROUPE_DAEMON` set to that
daemon's WebSocket and `VITE_TROUPE_LOCAL_ONLY=1`, so the app opens on the session list;
anything after `pnpm dev:local` goes to Vite (`--port 5185 --strictPort`).

| Variable | Read at | Meaning |
|---|---|---|
| `TROUPE_DEV_HOME` | `scripts/dev-local.ts` | Where the development daemon keeps its state, config, `daemon.json`, `script.json` and the `demo` workspace |
| `TROUPE_DAEMON_BIN` | `scripts/dev-local.ts` | The daemon to start, instead of the one on the `PATH` |
| `VITE_TROUPE_LOCAL_ONLY` | `apps/desktop/src/mode.ts` | `1`: local-only is the mode a browser that has not chosen starts in |
| `VITE_TROUPE_DAEMON` | `apps/desktop/src/shell.ts` | `<port>:<token>` of a daemon's WebSocket, for a browser build (`DECISIONS.md` #41) |

## `pnpm fake` — the fake deployment

`scripts/fake-deployment.ts` starts the same three fakes the test suite uses
(`:10-12`; `DECISIONS.md` #18):

| What | Detail | Citation |
|---|---|---|
| Fake identity provider | Device grant only; `slow_down` and rotating refresh tokens | `packages/client/test/support/idp.ts:1-6` |
| Fake worker | Real WebSocket on `/v1/socket`; deltas every 25 ms | `fake-deployment.ts:20`, `worker.ts:103` |
| Fake plane | Discovery, `/auth/exchange`, `/rpc`; pod tokens good for 900 s | `fake-deployment.ts:21` |
| Ports | All three listen on `127.0.0.1` port 0 (ephemeral) and print their URLs at start; the dev server is fixed at 5173 | `idp.ts:49`, `plane.ts:58`, `worker.ts:109`, `fake-deployment.ts:45-49` |
| CORS allowlist | `ORIGINS` env, comma-separated; default `http://localhost:5173,http://127.0.0.1:5173`; applied to both the IdP and the plane | `fake-deployment.ts:14, 19, 21` |
| Seeded sessions | Three: "Rewrite the placement loop" (alice, dev), "Nightly dependency sweep" (alice, ux, trigger origin), "Migrate the ledger table" (bob, dev) | `fake-deployment.ts:24-26` |
| Seeded approval | The third session is stopped on a `shell` approval for `psql -c 'drop index ledger_old'`, so the inbox has one entry | `fake-deployment.ts:29-40` |
| Auto-approval | Every 500 ms the IdP approves any pending device grant as `alice@example.com` | `fake-deployment.ts:43` |
| Prompt prefixes | `approve: <cmd>` asks for an approval; `big: <label>` returns a tool result over 16 KiB (a 240 KB blob with a 4 KiB preview); `quiet: …` answers without streaming | `worker.ts:453-455`, `:479-486`, `:506-521` |

Start it, then the dev server in a second terminal, and sign in to the plane URL it
printed:

```bash
pnpm fake
```

```bash
pnpm dev
```

Discrepancy (unexecuted): `README.md:55-58` and the script's own banner
(`fake-deployment.ts:52`) describe signing in from the browser with the device code. The
browser build now picks the redirect flow whenever `location` and `crypto.subtle` exist
(`packages/client/src/auth.ts:193-196`, `apps/desktop/src/views/SignIn.tsx:81`), which
`http://localhost:5173` satisfies. That flow fetches
`<issuer>/.well-known/openid-configuration` from the provider
(`packages/client/src/pkce.ts:83-86`), and `FakeIdp` answers anything but
`/device/code` and `/token` with 404 (`idp.ts:150`). The fake discovery publishes no
`authorization_endpoint` (`plane.ts:120-129`). The tests are unaffected because the
harness calls `auth.signIn()` — the device grant — directly (`harness.ts:44`). This was
not run in a browser for the audit and is not listed in AUDIT.md; treat browser sign-in
against `pnpm fake` as unverified.

## Against a real plane

Two things outside the GUI have to allow the development origin
(`README.md:69-76`; `DECISIONS.md` #10):

1. The plane's `TROUPE_CORS_ORIGINS` must include `http://localhost:5173`. When it does
   not, the GUI shows the message built at `packages/client/src/auth.ts:87-90`, which
   names the origin and the variable. On the server this is `plane.corsOrigins` in the
   chart (`../../charts/troupe/values.yaml:82`) → `TROUPE_CORS_ORIGINS`
   (`../../config/runtime.exs:266`). The worker's WebSocket upgrade has its
   own allowlist, `TROUPE_WORKER_ALLOWED_ORIGINS` (`runtime.exs:130`;
   `REPORT.md:142-150`).
2. The identity provider must register `http://localhost:5173` as a single-page
   application redirect URI on the plane's client id (`SignIn.tsx:172-175`;
   `REPORT.md:182-184`). The redirect URI the dev build sends is `redirectUri()` =
   `location.origin` because `BASE_URL` is `/` in development (`apps/desktop/src/shell.ts:91-95`).

The plane URL is typed into the sign-in screen and remembered in `localStorage`
`troupe.pref.planeUrl` (`SignIn.tsx:26, 75`; `shell.ts:112-127`). Everything else —
client id, issuer, endpoints, scopes — comes from the plane's `/.well-known/troupe`
(`packages/client/src/plane.ts:9-17`). See
[../admin/identity-provider.md](../admin/identity-provider.md) for the full list of what
the provider must allow.

Unconfirmed: whether the end-to-end sign-in against a real plane completes
(`REPORT.md:264-267`, `:278-281`; AUDIT §4.1).

## The bench

`docs/bench.md` is the recipe. In `worker` mode the bench dials a standalone worker
container with tokens it mints itself from an ES256 key you generate (`docs/bench.md:8-28`);
the worker verifies them against a JWKS you mount (`docs/bench.md:33-41`).
`packages/bench/src/devToken.ts` mints them: `kid` is the RFC 7638 thumbprint
(`devToken.ts:18-19`), `aud` is the pod id, lifetime is capped at 900 s
(`devToken.ts:39`). This is for measuring, never for a deployment (`docs/bench.md:6`).

The worker container environment in `docs/bench.md:33-41` is the *server's* — its
variables (`TROUPE_JWKS_PATH`, `TROUPE_PROVIDER=fake`, `TROUPE_STATE_HOME`, …) are
documented with the platform, in the repository root's `docs/`, not here. `TROUPE_POD_ORDINAL` is the
token audience (`docs/bench.md:47-48`), so `BENCH_POD_ID` must equal it.

```bash
BENCH_SIGNING_KEY=keys/signing-key.json BENCH_POD_ID=bench-0 BENCH_CLIENTS=20 BENCH_PROMPTS=10 pnpm bench
```

Results are printed and written as JSON to `BENCH_OUT` (`packages/bench/src/main.ts:161-165`).
`packages/bench/src/trace.ts` connects once, sends one prompt and prints every frame
(`trace.ts:1-2`); run it with `tsx packages/bench/src/trace.ts` and the same
`BENCH_*` variables. `BENCH_MODE=plane` has never been measured (`README.md:198-200`).

## `pnpm first-token`

`scripts/first-token.ts` starts a harness with zero delta delay (`:19`), then `RUNS`
times (default 20, `:15`): device-grant sign-in with a memory store, `sessions.list`,
`profiles.list`, `session.create` on `dev`/`build`, attach, prompt, and records each
milestone (`:21-51`). Prints median and p95 (`:55-61`). `REPORT.md:77-103` records a
run; read it as the client's share only.

```bash
RUNS=50 pnpm first-token
```

## `pnpm tokens` and `pnpm tokens:check`

```bash
pnpm tokens
```

```bash
pnpm tokens:check
```

`scripts/tokens.ts` reads every `docs/design/themes/*.tokens.json`, checks that they
expose identical token names, and for each theme emits dark values on
`[data-theme="<id>"]`, light values on `[data-theme="<id>"][data-mode="light"]`, and
light again under `@media (prefers-color-scheme: light)` for
`[data-theme="<id>"]:not([data-mode="dark"])` — the last is what "follow my system"
resolves to, and it is why the mode attribute is absent rather than set. It writes
`apps/desktop/src/tokens.css` and `apps/desktop/src/mark.ts`. Never edit the output.

## `.claude/launch.json`

One configuration named `desktop`: `pnpm --filter @troupe/desktop dev` on port 5173
(`.claude/launch.json:4-9`). It is for the Claude Code browser pane and is equivalent to
`pnpm dev`.

## Every development variable

There is no `.env`, no `.env.example` and no `VITE_*` variable; `.gitignore:4-5`
ignores `.env` and `.env.*` but nothing reads them (AUDIT §1.4). The only value the
*bundle* reads is `import.meta.env.BASE_URL` (`apps/desktop/src/shell.ts:93, 107`),
which Vite sets from `TROUPE_GUI_BASE`.

| Variable | Read at | Default | Meaning |
|---|---|---|---|
| `TROUPE_GUI_BASE` | `apps/desktop/vite.config.ts:16` (build time); `Dockerfile:38-39`; the root `ci.yml`'s `images` job | `/` | Vite `base`. Normalised: `""` or `/` → `/`; anything else → `/<trimmed>/` (`vite.config.ts:17`). Baked into asset URLs; must equal the chart's `gui.basePath` |
| `ORIGINS` | `scripts/fake-deployment.ts:14` | `http://localhost:5173,http://127.0.0.1:5173` | Comma-separated CORS allowlist for the fake IdP and plane |
| `RUNS` | `scripts/first-token.ts:15` | `20` | Iterations of the first-token measurement |
| `BENCH_MODE` | `packages/bench/src/main.ts:27` | `worker` | `worker` dials `BENCH_WS` with self-minted tokens; `plane` goes through `BENCH_PLANE` |
| `BENCH_CLIENTS` | `main.ts:28` | `5` | Concurrent clients, one session each |
| `BENCH_PROMPTS` | `main.ts:29` | `20` | Prompts per client, one in flight at a time |
| `BENCH_WORKSPACE` | `main.ts:30`, `trace.ts:29` | `/workspace` | Sessions are created under `<workspace>/c<n>` (`main.ts:55`) |
| `BENCH_OUT` | `main.ts:31` | `bench-results` | Directory for the JSON result |
| `BENCH_SIGNING_KEY` | `main.ts:42`, `trace.ts:13` | required in `worker` mode | Path to the private JWK from `docs/bench.md:12-23` |
| `BENCH_POD_ID` | `main.ts:43`, `trace.ts:14` | required in `worker` mode | Token audience; must equal the worker's `TROUPE_POD_ORDINAL` |
| `BENCH_WS` | `main.ts:44`, `trace.ts:15` | `ws://localhost:4000/v1/socket` | The worker socket, passed through `normalizeEndpoint` |
| `BENCH_PLANE` | `main.ts:63` | required in `plane` mode | Plane base URL |
| `BENCH_PLANE_TOKEN` | `main.ts:64` | required in `plane` mode | A plane token obtained elsewhere; the bench does not sign in |
| `BENCH_PROFILE` | `main.ts:65` | required in `plane` mode | Profile for `session.create` |
| `BENCH_AGENT` | `trace.ts:26` | unset | Passed as `profile` to `createLocalSession` (`trace.ts:27-31`). Discrepancy: the variable is named "agent" but the field it sets is `profile`; `main.ts` does not read it |
| `TRACE_SECONDS` | `trace.ts:16` | `10` | How long `trace.ts` listens before `session.get` and exit |

Deploy-time variables (`KUBECONFIG_FILE`, `VALUES`, `NAMESPACE`, `RELEASE`, `PLANE_URL`,
`EXPECT_COMMIT`, all read by the root `scripts/deploy`) are in
[deployment.md](deployment.md); CI secrets and variables are in [ci-cd.md](ci-cd.md).

Discrepancy: `docs/bench.md:61-68` lists six of the `BENCH_*` variables; the table
above is the full set read by `main.ts` and `trace.ts`.

## Related

- [testing.md](testing.md) — what the suite runs.
- [build.md](build.md) — producing the bundle and the image.
- [../user/README.md](../user/README.md) — what a person sees once it is running.
