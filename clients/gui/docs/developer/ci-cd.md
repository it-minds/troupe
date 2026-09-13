> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).

# CI and CD

There is one workflow file, `.github/workflows/ci.yml`. **It is untracked — not in any
commit — and has never run** (AUDIT §1.5, §2). Everything below describes what it would
do if committed and pushed to a GitHub repository. There is no deploy job anywhere; a
person runs `scripts/deploy` (`ci.yml:4-6`; `DECISIONS.md` #34).

Discrepancy: `REPORT.md:290-291` says there is no CI configuration; `README.md:113-119`
describes this file as if it were live. Open question AUDIT §4.7: whether to commit it
and which jobs gate a merge.

## Triggers and concurrency

| Setting | Value | Line |
|---|---|---|
| `name` | `ci` | `ci.yml:8` |
| `on.push.branches` | `["**"]` — every branch | `:12` |
| `on.push.tags` | `["v*"]` | `:13` |
| `on.pull_request` | any | `:14` |
| `concurrency.group` | `${{ github.workflow }}-${{ github.ref }}` | `:18` |
| `concurrency.cancel-in-progress` | `true` — a newer push cancels the older run | `:19` |
| `env.NODE_VERSION` | `"24"` | `:22` |

## Job `check` — "typecheck, test, build"

`ci.yml:25-51`, `ubuntu-latest`, no `needs`.

| Step | Line | Covered in |
|---|---|---|
| `actions/checkout@v4` | `:29` | — |
| `pnpm/action-setup@v4` (reads `packageManager`) | `:31` | [tech-stack.md](tech-stack.md) |
| `actions/setup-node@v4` with `node-version: 24`, `cache: pnpm` | `:33-36` | [tech-stack.md](tech-stack.md) |
| `pnpm install --frozen-lockfile` | `:38` | [local-setup.md](local-setup.md) |
| "The committed design tokens match the design file": `pnpm tokens:check` | `:42-43` | [conventions.md](conventions.md), [repo-structure.md](repo-structure.md) |
| `pnpm typecheck` | `:45` | [local-setup.md](local-setup.md) |
| `pnpm build` | `:49` | [build.md](build.md) |
| `pnpm test` | `:51` | [testing.md](testing.md) |

### The ordering risk (AUDIT §3.3)

The comment at `ci.yml:47-48` says "The protocol client has to be built before the app
typechecks against its types in a clean checkout" — and then the file runs `pnpm
typecheck` (`:45`) *before* `pnpm build` (`:49`). The desktop app is unaffected because
its `tsconfig` aliases `@troupe/client` to source (`apps/desktop/tsconfig.json:17-19`).
The bench is not: `packages/bench/tsconfig.json:1-4` has no alias, so `tsc` resolves
`@troupe/client` through the package's `exports` to `./dist/index.d.ts`
(`packages/client/package.json:8-13`), which does not exist until `pnpm build` has run.
On a developer machine that has built once, `dist/` is present and the order is
harmless; on a clean runner `pnpm -r typecheck` may fail in `@troupe/bench`. Untested,
because the workflow has never run. Swapping the two steps, or giving the bench the
same `paths` entry, would remove the doubt.

## Job `image`

`ci.yml:53-114`, `needs: [check]` (`:55`), `if: github.event_name == 'push'` (`:58`) —
so never on a pull request, and never without a credential. Permissions `contents:
read`, `packages: write` (`:60-62`).

| Step | Line | What it does |
|---|---|---|
| `actions/checkout@v4` | `:64` | |
| "Resolve the registry and the tags" | `:71-92` | `registry = ${REGISTRY:-ghcr.io}`; `namespace = ${REGISTRY_NAMESPACE:-$GITHUB_REPOSITORY_OWNER}`; image name lower-cased as `<registry>/<namespace>/troupe-gui` (`:77-79`). Tags: always `sha-<first 7 of GITHUB_SHA>` (`:86`); on a `refs/tags/v*` push also `<version without v>` (`:87-89`). Never a floating tag (`:81-85`) |
| `docker/setup-buildx-action@v3` | `:94` | |
| `docker/login-action@v3` | `:96-100` | `username: secrets.REGISTRY_USERNAME \|\| github.actor`, `password: secrets.REGISTRY_PASSWORD \|\| secrets.GITHUB_TOKEN` |
| `docker/build-push-action@v6` | `:105-114` | `context: .`, `file: Dockerfile`, `build-args: TROUPE_GUI_BASE=${{ vars.GUI_BASE \|\| 'app' }}`, `platforms: linux/amd64`, `push: true`, GHA layer cache (`cache-from`/`cache-to: type=gha,mode=max`) |

### Secrets and variables

| Name | Kind | Default when unset | Line |
|---|---|---|---|
| `REGISTRY` | secret | `ghcr.io` | `:74`, `:77` |
| `REGISTRY_NAMESPACE` | secret | the repository owner | `:75`, `:78` |
| `REGISTRY_USERNAME` | secret | `github.actor` | `:99` |
| `REGISTRY_PASSWORD` | secret | `GITHUB_TOKEN` | `:100` |
| `GUI_BASE` | repository variable | `app` | `:109` |

The four secrets are named to match the server's workflow so one set configures both
repositories (`:66-70`; `README.md:115-117`). Unconfirmed: which registry the recorded
deployment's image (`rg.fr-par.scw.cloud/troupe/troupe-gui:0.1.1`, `REPORT.md:247`) was
pushed to by what; the chart's default repository is `ghcr.io/objective-mj/troupe-gui`
(`charts/troupe-gui/values.yaml:6`) and the tag `0.1.1` matches neither `sha-…` nor any
`v*` tag in the history (AUDIT §3.5).

### Tags

| Event | Tags pushed |
|---|---|
| Push to any branch | `<image>:sha-<7>` |
| Push of tag `v1.2.3` | `<image>:sha-<7>` and `<image>:1.2.3` |
| Pull request | none — the job does not run |

## Job `chart`

`ci.yml:116-134`, `ubuntu-latest`, no `needs` — runs in parallel with `check`.

| Step | Line | What it does |
|---|---|---|
| `actions/checkout@v4`, `azure/setup-helm@v4` | `:120-121` | |
| `helm lint charts/troupe-gui --set ingress.host=example.test` | `:123` | `ingress.host` is required when the ingress is enabled (`templates/ingress.yaml:3-5`) |
| "The rendered manifests are valid Kubernetes" | `:128-134` | `helm template … --set ingress.host=example.test --set ingress.tlsSecretName=example-tls \| docker run ghcr.io/yannh/kubeconform:v0.6.7 -strict -summary -kubernetes-version 1.31.0 -` |

Nothing tests the chart with `basePath: /` (the `Prefix` branch of the ingress,
`templates/ingress.yaml:43-46`).

## What is missing

- **No deploy job**, by decision (`ci.yml:4-6`; `DECISIONS.md` #34). Deployment is
  [deployment.md](deployment.md).
- **No browser tests** (`REPORT.md:288`).
- **No `pnpm typecheck` after `pnpm build`**, see above.
- **No cache for the Docker layer on a fresh runner** beyond `type=gha`.
- **No branch protection or required check** can exist for a workflow that has not run.

## Related

- [build.md](build.md) — what the `image` job builds.
- [deployment.md](deployment.md) — the human half.
- [testing.md](testing.md) — what `pnpm test` covers.
