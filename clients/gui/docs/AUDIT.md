# Documentation audit — troupe-gui

Audited against commit `783e660` on branch `master`, **plus the uncommitted working tree**,
which is effectively one large stage-1 change on top of that commit: 16 modified files
(`git diff --stat`: +1828/−653) and roughly 40 untracked files including every view under
`apps/desktop/src/views/`, five client modules, the test suite, the Dockerfile, the Helm chart,
the CI workflow, `DECISIONS.md`, `REPORT.md` and the design system. Audit date: 2026-09-13.
`pnpm --filter @troupe/client test` (33 tests) and `pnpm typecheck` pass on the working tree.

> A record of the GUI as a repository of its own on that date, not revised since. It now
> lives at `clients/gui` in the Troupe repository (root Decision 666; Decision 45), and the
> Helm chart, `scripts/deploy` and CI workflow inventoried below were removed with the
> move: the GUI is deployed as the `gui:` block of the root `charts/troupe`, and the root
> workflows build, test, release and deploy it (root Decisions 669 and 670). The SHAs
> quoted here are mapped in [docs/history](../../../docs/history/README.md).

This is the Phase 1 output for the GUI repository. The server it talks to is documented in
the repository root's `docs/` ([../../../docs/](../../../docs/README.md)); these docs link
there rather than restating protocol semantics.

---

## 1. Inventory

### 1.1 Workspace

pnpm workspace (`pnpm-workspace.yaml`: `packages/*`, `apps/*`), `packageManager: pnpm@10.15.0`,
TypeScript 5.9, ES2022, strict with `noUncheckedIndexedAccess` and `exactOptionalPropertyTypes`
(`tsconfig.base.json`).

| Package | Name | What it is | Runtime deps |
|---|---|---|---|
| `packages/client` | `@troupe/client` 0.1.0 | The protocol in TypeScript: WebSocket connection, plane HTTP client, auth session (device grant and PKCE), session view and attachment, transcript fold, fleet store | none |
| `packages/bench` | `@troupe/bench` 0.1.0 | Throughput test: N clients × K prompts against a worker or a plane | `@troupe/client` |
| `apps/desktop` | `@troupe/desktop` 0.1.0 | The GUI: Vite + React 19, plain web bundle; a desktop shell is an interface (`src/shell.ts`) with no implementation in this repo | `react`, `react-dom`, `@fontsource/ibm-plex-*`, `@troupe/client` |

Root scripts (`package.json:6-16`): `build`, `test`, `typecheck`, `bench`, `dev`, `fake`,
`tokens`, `tokens:check`, `first-token`. Scripts under `scripts/`: `fake-deployment.ts`
(fake IdP + plane + worker on loopback), `first-token.ts` (sign-in-to-first-token timing),
`tokens.ts` (design tokens → `apps/desktop/src/tokens.css`), `deploy` (Helm upgrade with
digest print).

### 1.2 What the GUI does (stage 1 of four)

Confirmed from `apps/desktop/src/views/*`: sign in to a plane (PKCE redirect in a browser,
device code elsewhere), stay signed in across reloads, sign out; one polled list of the
team sessions the person may see with search, state and profile filters; start a session
(profile, agent, title, first prompt); open a session and read its transcript live; send
prompts, stop a turn, switch profile; answer approvals in the session or from a global
inbox; expand tool output and fetch large results on demand; browse and read workspace
files; see tasks, sub-agent states, presence, cost and bundle version; pick one of three
themes on first sign-in and change it, with light, dark or follow-the-system, in
Appearance.

Not in the GUI today (spec stages 2–4 and known gaps in `REPORT.md`): local or private
sessions, a desktop shell, direct worker connection, pin/grant/review/erase/todo edit, file
upload, admin or review screens, a settings screen beyond Appearance. The theme is kept in
the browser rather than on the user record, so it does not follow a person to another
machine (`DECISIONS.md` #39).

### 1.3 Protocol methods the client uses

HTTP to the plane (`packages/client/src/plane.ts`): `GET /.well-known/troupe`,
`POST /auth/exchange`, `POST /rpc` with `me`, `teams.list`, `profiles.list`, `sessions.list`,
`session.get`, `session.create`, `session.open`, `token.mint`, `session.review`,
`session.grant`, `session.pin`/`session.unpin`, `session.erase` (the last five have no
screen). Identity provider: device authorization, token endpoint, refresh, authorization
code with PKCE (`pkce.ts`). WebSocket to a pod (`connection.ts`, `session.ts`): `initialize`,
`subscribe`, `unsubscribe`, `input.send`, `approval.respond`, `turn.cancel`,
`profile.switch`, `todo.edit`, `presence.set`, `fs.list`, `fs.read`, `blob.get`,
`auth.refresh`; answers `tool.invoke` with `method_not_found`; handles `event`,
`resync_required`, `auth.expiring`.

### 1.4 Configuration inputs

No `.env`, no `.env.example`, no `VITE_*` variables (`grep import.meta.env` finds only
`BASE_URL`). Inputs are:

| Input | Where read | Meaning |
|---|---|---|
| `TROUPE_GUI_BASE` (build time) | `apps/desktop/vite.config.ts:16`, `Dockerfile:38-39`, `.github/workflows/ci.yml` | Vite `base`; baked into the bundle; must equal the chart's `basePath` |
| `import.meta.env.BASE_URL` | `apps/desktop/src/shell.ts:93, 107` | redirect URI and plane-URL prefill |
| plane URL | typed by the user; `localStorage` `troupe.pref.planeUrl` | which plane to talk to; client id and IdP endpoints come from the plane's discovery document |
| `localStorage` `troupe.auth.refresh:<planeUrl>` | `packages/client/src/auth.ts:40, 167` | the only persisted secret (IdP refresh token) |
| `sessionStorage` `troupe.auth.pending` | `packages/client/src/pkce.ts:115` | PKCE verifier and state during a redirect |
| `localStorage` `troupe.pref.theme`, `troupe.pref.mode` | `apps/desktop/src/theme.ts` | which theme, and light/dark/follow-the-system |
| `localStorage` `troupe.pref.appearance.chosen.<subject>` | `apps/desktop/src/theme.ts` | whether this person has been through the theme screen |
| `ORIGINS`, `RUNS`, `BENCH_*`, `TRACE_SECONDS` | `scripts/*.ts`, `packages/bench/src/*` | development tools only |
| `KUBECONFIG_FILE`, `VALUES`, `NAMESPACE`, `RELEASE`, `TAG` | `scripts/deploy` | deploy inputs |
| CI secrets `REGISTRY`, `REGISTRY_NAMESPACE`, `REGISTRY_USERNAME`, `REGISTRY_PASSWORD`; variable `GUI_BASE` | `.github/workflows/ci.yml` | image push |

Helm values (`charts/troupe-gui/values.yaml`): `image.{repository,tag,pullPolicy}`,
`replicas`, `resources`, `basePath`, `ingress.{enabled,className,host,tlsSecretName,certIssuer,annotations}`,
`podAnnotations`, `nodeSelector`, `tolerations`, `affinity`. The container receives no
environment variables.

Server-side settings the GUI depends on but does not own: the plane's `TROUPE_CORS_ORIGINS`
must include the GUI's origin, and the identity provider must register the GUI's origin as a
single-page-application redirect URI (`apps/desktop/src/views/SignIn.tsx`, `DECISIONS.md` #20–#29).

### 1.5 Build, CI, deployment

`Dockerfile`: Node 24 build stage runs `pnpm install --frozen-lockfile`, builds and **tests**
the client, builds the desktop bundle; runtime is `nginxinc/nginx-unprivileged:1.29-alpine`
on port 8080 with `docker/nginx.conf` (SPA fallback, `/healthz`, immutable hashed assets).
`.github/workflows/ci.yml` (untracked, never run): `check` (tokens:check, typecheck, build,
test), `image` (push only, `sha-<7>` and version tags, `TROUPE_GUI_BASE` from `vars.GUI_BASE`
or `app`), `chart` (helm lint + kubeconform). **No deploy job**; `scripts/deploy` is run by a
person. `REPORT.md:805-836` records a deployment at `https://troupe.itmindsinternal.dk/app`
from image tag `0.1.1`; the values for it are gitignored under `.local/`.

### 1.6 Tests

33 tests under `packages/client/test/`, run with Node's built-in runner: `stage1.test.ts`
(one block per spec done item 1–6), `pkce.test.ts`, `transcript.test.ts`, `fleet.test.ts`.
`test/support/` is a fake deployment that implements the protocol (real WebSocket,
hash-chained log, device grant with `slow_down`, token expiry and refresh, blob range caps,
first-answer-wins approvals, a same-origin-enforcing `fetch`). No browser tests; Playwright is
planned (`spec.md:62`).

---

## 2. Where prose contradicts code

| Claim | Where | Code says |
|---|---|---|
| `pnpm test` runs "20 tests" | `README.md:178`, `REPORT.md:609-611` | 33 (`grep -c 'it('` and the run) |
| "no CI configuration in this repository yet" | `REPORT.md:859-860` | `.github/workflows/ci.yml` exists (untracked) and `README.md:206-212` describes it |
| Reading a dormant session does not wake it | `apps/desktop/src/views/Session.tsx:175` | opening from the list uses `session.open` with `mode: "activate"` (`hooks.ts:172` default); only the inbox uses `read` (`Approvals.tsx:69`) |
| Composer holds what you type offline and sends on reconnect | `Session.tsx:186-187, 576`, `docs/design/DESIGN.md` §5 | the view is unbound while reconnecting (`attach.ts:141`) and `send` throws; the draft is restored with an error (`Session.tsx:534-536`) |
| Sessions list filters by state, profile **and status** | `spec.md:31` | state and profile only (`Sessions.tsx`) |
| Sign-in is the device grant | `spec.md:30` | browsers use authorization code + PKCE (`auth.ts:193-196`, `DECISIONS.md` #20–21); device grant remains for hosts without `crypto.subtle` |
| A "Plane tab" and a direct worker mode | `spec.md:30`, `README.md` at `HEAD` | the working tree is plane-only; the direct worker path survives in `createLocalSession` and the bench |
| Fleet poll every 4 s | `hooks.ts:114`, `DECISIONS.md` #4 | `FleetStore.poll` default is 5 s (`fleet.ts:190`); the app passes 4 |
| Client has "no dependencies" | `README.md:107` | true at runtime; `ws` is a dev dependency for the fake worker |
| Design surfaces: diff rendering, ownership picker, "Try now", "Follow the work" | `docs/design/DESIGN.md` §5–6 | not built; `REPORT.md:868-871` acknowledges markdown/diff only |
| Branch `main` | (session assumption) | the repository's branch is `master` (`git branch --show-current`) |

---

## 3. Findings the docs carry as caveats

1. `.dockerignore` does not exclude `.local/`, and the Dockerfile copies the whole tree into
   the build stage, so a local `docker build` copies the cluster kubeconfig into an
   intermediate layer. The runtime image copies only `dist/`.
2. No hash-chain verification exists in `packages/client/src`; only the test fake verifies
   (`test/support/log.ts`). The spec defers it to stage 3.
3. `packages/bench/tsconfig.json` resolves `@troupe/client` through the package's `dist`, and
   the CI `check` job runs `typecheck` before `build`; in a clean checkout that order may
   fail. Untested because the workflow has never run.
4. The desktop shell contract in `shell.ts` picks the PKCE redirect flow whenever `location`
   and `crypto.subtle` exist, which a Tauri or Electron shell would also have; the redirect
   story for a shell is unresolved (`REPORT.md:680`).
5. Chart `appVersion` is `0.1.0`, package versions are `0.1.0`, and the recorded deployment ran
   `0.1.1`; there is no tagging rule in the repo.

---

## 4. Open questions

1. Does the live sign-in work end to end? `REPORT.md:833-850` says the SPA redirect URI still
   had to be registered in Entra and everything after `/auth/exchange` was unproven against a
   real plane.
2. Which real-server behaviours do the fakes assume correctly: closed replay boundary on
   `subscribe`, `auth.expiring` two minutes ahead, the 64 KiB `blob.get` cap, `approval_resolved`
   shape, `presence` ephemerals, `session.get` over the worker socket? `REPORT.md:851-856`
   calls this the largest gap.
3. Should opening a session from the list use `read` until the person types (finding in §2)?
4. Is `fs.upload` meant to be exposed (`DECISIONS.md` #16 vs `Files.tsx:104`)?
5. Which is the intended fleet poll interval, 4 s or 5 s?
6. Framework for the desktop shell (Tauri vs Electron) is undecided (`REPORT.md:689-694`).
7. Whether the CI workflow should be committed and which jobs gate a merge.

---

## 5. Method

One read-only pass over every source file outside `node_modules`, plus `git status`,
`git diff --stat`, `git ls-files --others`, a test run and a typecheck. Server behaviour was
cross-checked against the troupe-remote audit (`../../docs/AUDIT.md`), not
against a running plane.
