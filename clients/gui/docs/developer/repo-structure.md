> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).

# Repository structure

An annotated tree of what is in the working directory, what is generated, and — because
`HEAD` does not match what these documents describe — what is committed and what is not.

## The tree

Line counts are `wc -l` on 2026-09-13. `node_modules/`, `dist/` and `bench-results/`
are ignored and omitted.

```
troupe-gui/
├── package.json                  workspace root: scripts, tsx, typescript
├── pnpm-workspace.yaml           packages/*, apps/*
├── pnpm-lock.yaml
├── tsconfig.base.json            strict flags shared by every package
├── .npmrc                        strict-peer-dependencies=false
├── .editorconfig                 LF, 2 spaces
├── .gitattributes                * text=auto eol=lf
├── .gitignore                    node_modules, dist, *.tsbuildinfo, .env, .env.*, bench-results, .local
├── .dockerignore                 what the image build does not copy (see build.md)
├── Dockerfile                    build stage (Node 24) + runtime (nginx-unprivileged)
├── README.md                     226 lines; overview, run, ship, design rules
├── DECISIONS.md                  35 numbered judgment calls
├── REPORT.md                     stage-1 report and the live-deployment log
├── spec.md                       the four-stage brief this repository builds against
├── .claude/launch.json           dev server definition for the Claude Code browser pane
├── .github/workflows/ci.yml      check / image / chart jobs — untracked, never run
├── .local/                       ignored; cluster credentials and values (names below)
├── docker/
│   └── nginx.conf                the runtime server config
├── charts/troupe-gui/            Helm chart, version 0.1.0
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/                _helpers.tpl, deployment.yaml, ingress.yaml, service.yaml
├── scripts/
│   ├── deploy                    bash: helm upgrade --install, then print pod digests
│   ├── fake-deployment.ts        pnpm fake: IdP + plane + worker on loopback
│   ├── first-token.ts            pnpm first-token: sign-in to first delta, timed
│   └── tokens.ts                 pnpm tokens: tokens.json → tokens.css
├── docs/
│   ├── AUDIT.md                  the audit these documents cite
│   ├── bench.md                  the throughput-test recipe
│   ├── design/
│   │   ├── DESIGN.md             the design system, 341 lines
│   │   ├── tokens.json           the design system as data — source of truth
│   │   └── example.dc.html       every surface in one static file
│   ├── plans/
│   │   └── local-and-private-sessions.md   stage 2/3 design
│   ├── developer/                this track
│   ├── admin/                    the operator track
│   └── user/                     the person's track (../user/README.md)
├── packages/
│   ├── client/                   @troupe/client 0.1.0
│   │   ├── package.json          build = tsc; typecheck = src + tests; test = node --test
│   │   ├── tsconfig.json         emits dist/ from src/
│   │   ├── tsconfig.test.json    typechecks src + test with Node types, no emit
│   │   ├── src/
│   │   │   ├── index.ts          (30)  the public surface
│   │   │   ├── types.ts          (206) protocol shapes
│   │   │   ├── connection.ts     (322) TroupeConnection
│   │   │   ├── plane.ts          (386) PlaneClient
│   │   │   ├── auth.ts           (306) AuthSession, token stores
│   │   │   ├── pkce.ts           (300) authorization code + PKCE
│   │   │   ├── session.ts        (387) SessionView, createLocalSession
│   │   │   ├── attach.ts         (164) SessionAttachment
│   │   │   ├── transcript.ts     (433) the fold
│   │   │   └── fleet.ts          (270) FleetStore, PlaneSource
│   │   └── test/
│   │       ├── stage1.test.ts    (424) one describe per spec done item
│   │       ├── pkce.test.ts      (268)
│   │       ├── transcript.test.ts (133)
│   │       ├── fleet.test.ts     (151)
│   │       └── support/          harness.ts, idp.ts, log.ts, plane.ts, worker.ts
│   └── bench/                    @troupe/bench 0.1.0
│       ├── package.json          start = tsx src/main.ts
│       ├── tsconfig.json         no paths alias — resolves @troupe/client via dist
│       └── src/                  main.ts (172), devToken.ts (46), trace.ts (37)
└── apps/
    └── desktop/                  @troupe/desktop 0.1.0
        ├── package.json          dev = vite; build = tsc --noEmit && vite build
        ├── tsconfig.json         paths: @troupe/client → ../../packages/client/src/index.ts
        ├── vite.config.ts        base from TROUPE_GUI_BASE; alias to client source; port 5173
        ├── index.html            <div id="root">, /src/main.tsx
        └── src/
            ├── main.tsx          (10)   createRoot + StrictMode
            ├── App.tsx           (96)   rail and screen switch
            ├── hooks.ts          (152)  useFleet, useProfiles, useSessionView
            ├── shell.ts          (127)  the desktop-shell contract; redirectUri, likelyPlaneUrl, prefs
            ├── styles.css        (1237) the stylesheet
            ├── tokens.css        (316)  GENERATED — do not edit
            └── views/            SignIn, Sessions, Session, Approval, Approvals, Files, bits
```

## What is generated

`apps/desktop/src/tokens.css` is written by `scripts/tokens.ts` from
`docs/design/tokens.json` (`scripts/tokens.ts:1-2`, `:21-22`, `:157`). Its header says
so (`tokens.css:1-3`). It is committed so the app builds without a generation step, and
`pnpm tokens:check` regenerates it and fails on any diff (`package.json:14`;
`DECISIONS.md` #14). Edit `tokens.json`, run `pnpm tokens`, commit both.

The variable names are chosen to match `docs/design/example.dc.html` so a screen
prototyped there keeps its colours (`scripts/tokens.ts:10-11`).

Nothing else in the tree is generated. `dist/` directories (client `tsc` output and the
Vite bundle) are build products and ignored (`.gitignore:2`).

## Committed versus uncommitted

`HEAD` is `783e660` on `master` ("spec.md: the GUI, in four stages"). The working tree
carries one large uncommitted change on top of it: 16 modified files
(`git diff --stat`: 1878 insertions, 653 deletions) and every file listed below as
untracked (AUDIT §0). **A reader at `HEAD` will not find most of what these documents
describe.**

| State | Paths |
|---|---|
| Modified, uncommitted | `.gitignore`, `README.md`, `package.json`, `pnpm-lock.yaml`, `apps/desktop/{package.json,tsconfig.json,vite.config.ts}`, `apps/desktop/src/{App.tsx,styles.css}`, `packages/client/package.json`, `packages/client/src/{connection,index,plane,session,types}.ts` |
| Deleted, uncommitted | `apps/desktop/src/useSession.ts` — the fold moved to `packages/client/src/transcript.ts` (`DECISIONS.md` #1) |
| Untracked | `.dockerignore`, `.github/workflows/ci.yml`, `DECISIONS.md`, `Dockerfile`, `REPORT.md`, `docker/nginx.conf`, `charts/troupe-gui/**`, `scripts/{deploy,fake-deployment.ts,first-token.ts,tokens.ts}`, `docs/AUDIT.md`, `docs/design/{DESIGN.md,tokens.json,example.dc.html}`, `apps/desktop/src/{hooks.ts,shell.ts,tokens.css}`, `apps/desktop/src/views/*.tsx`, `packages/client/src/{attach,auth,fleet,pkce,transcript}.ts`, `packages/client/test/**`, `packages/client/tsconfig.test.json` |
| Committed at `HEAD` and unchanged | `pnpm-workspace.yaml`, `tsconfig.base.json`, `.npmrc`, `.editorconfig`, `.gitattributes`, `spec.md`, `docs/bench.md`, `docs/plans/local-and-private-sessions.md`, `packages/bench/**`, `apps/desktop/index.html`, `apps/desktop/src/main.tsx`, `.claude/launch.json` |

The three commits in the history:

```
783e660 spec.md: the GUI, in four stages
8fcd396 Plan: local sessions, and private sessions that follow you
68a132c Ground work: the protocol client, a throughput bench, and a first GUI shell
```

Discrepancy: `REPORT.md:290-291` says there is "no CI configuration in this repository
yet"; `.github/workflows/ci.yml` exists in the working tree, untracked (AUDIT §2). Open
question AUDIT §4.7: whether it should be committed.

## The `.local/` directory

Ignored by `.gitignore:7` and never committed. On the audit machine it holds three
files; names only, contents deliberately not read for these documents:

| File | What it is for |
|---|---|
| `kubeconfig.yaml` | `scripts/deploy`'s default `KUBECONFIG_FILE` (`scripts/deploy:23`) |
| `values.itminds.yaml` | `scripts/deploy`'s default `VALUES` (`scripts/deploy:24`); the values for the recorded deployment (`REPORT.md:236-251`) |
| `entra-patch.json` | Unconfirmed: not referenced by any script or document in the tree |

`.dockerignore` does not exclude `.local/`, so a local `docker build` copies it into the
build stage (AUDIT §3.1); see [build.md](build.md).

## Related

- [architecture.md](architecture.md) — what each module in the tree does.
- [conventions.md](conventions.md) — where a new file goes.
- [ci-cd.md](ci-cd.md) — the untracked workflow.
