# CI and delivery

> Rewritten 2026-09-21 for the monorepo (Decisions 666–671). The previous version of this
> page — one workflow, five jobs, delivery ending at images and a chart on a tag, and no
> deploy step — is in git history; [AUDIT.md](../AUDIT.md) still describes the tree it was
> audited against.

Three workflows. `ci.yml` is the gate on every pull request, and on `main` it publishes
images and, when `VERSION` names a new version, cuts a release and deploys it.
`release.yml` is the native builds — the daemon, the TUI and the desktop app on every
platform — called from `ci.yml` and run nightly. `deploy.yml` rolls back to, or renders,
a named release by hand.

Three facts first, because the rest of this page is detail:

- **One required check, `ci-ok`.** A pull request runs the jobs for what it touched — a
  `changes` job decides — and `ci-ok` passes only if every job that ran passed. The
  filters are on jobs, not on the workflow: a workflow skipped by `paths:` leaves a
  required check pending forever, and a job skipped by `if:` reports success. `main`
  should require `ci-ok` and nothing else.
- **A release is a merged change to `VERSION`, and it deploys itself** (Decision 669).
  Nothing is released by pushing a tag, and nothing is deployed from a laptop.
- **Production runs the bytes CI tested.** A release does not rebuild: it adds the version
  tag to the images the same run pushed as `sha-<short>`.

## 1. Triggers

| Workflow | Runs on |
|---|---|
| `ci.yml` | every pull request; every push to `main`. Concurrent runs of a pull request are cancelled; `main`'s are not. |
| `release.yml` | called by `ci.yml` (a pull request that touches a native build, and every release); nightly at 02:17 UTC; `workflow_dispatch` |
| `deploy.yml` | `workflow_dispatch` only, with a version and a dry-run switch |

## 2. What a pull request runs

`changes` (`dorny/paths-filter`) answers five questions, and on a push to `main` every
answer is yes except `native`:

| Output | True when the pull request touches | Jobs it runs |
|---|---|---|
| `server` | `apps/`, `config/`, `mix.exs`, `mix.lock`, `charts/`, `docker/`, `dev/`, `scripts/`, `test/`, `fixtures/` | `check`, `chart`, `protocol` |
| `tui` | `clients/tui/`, the three harness apps, `mix.lock`, `scripts/locks-agree.exs` | `tui` |
| `gui` | `clients/gui/`, `scripts/version.exs` | `gui` |
| `gui_e2e` | the GUI's client package or `dev/`, the plane, the gateway, the protocol app, `config/`, `docker/` | `gui-e2e` |
| `native` | `clients/tui/`, the desktop app, the GUI's client package, `apps/troupe_daemon/`, `release.yml` | `native` (calls `release.yml`) |

`PROTOCOL.md`, `protocol/`, `VERSION`, `.tool-versions` and `ci.yml` itself make every
answer yes: the protocol is the one contract every part of the repository is on one side
of. `versions` runs on every pull request because it is cheap.

| Job | What it does |
|---|---|
| `check` | The umbrella's gate, unchanged: Postgres, MinIO and OpenBao from `scripts/dev-up`; `compile --force --warnings-as-errors`, `format --check-formatted`, `credo --strict`, the generated assets' `--check`, `troupe.boundaries`, migrations, `mix test` — and nine more runs on `main` for the race that shows one time in five. |
| `chart` | `helm lint` with each values file and with the GUI turned off; the chart must refuse unclustered replicas and a GUI mounted at `/`; `helm template` into `kubeconform` for `values.small.yaml`, `values.scaleway.yaml`, and `values.small.yaml` with `gui.enabled=false`. |
| `protocol` | `mix troupe.schema.diff` (additive only), the committed schema is current, and the Python conformance client end to end — the check that the protocol alone is enough to be a client, which is what a client of somebody else's relies on. |
| `tui` | In `clients/tui`: `scripts/locks-agree.exs` from the root, then `mix check` — compile with warnings as errors, format, credo, `troupe.xref`, test. |
| `gui` | In `clients/gui`: `pnpm install --frozen-lockfile`, `tokens:check`, `typecheck`, `build`, `test`. |
| `gui-e2e` | `clients/gui/dev/plane-stack.yml` brought up with `--build` — the plane built from this commit's `docker/Dockerfile`, with Postgres, OpenBao and Dex — then the client's `e2e.plane.test.ts` against it, which drives Dex's device flow headlessly. |
| `versions` | `elixir scripts/version.exs check`: the chart, the GUI's packages and the desktop app carry the same version as `VERSION`. |
| `native` | `release.yml` without a tag: build and smoke-test every native artifact, attach nothing. |
| `ci-ok` | `if: always()`, needs all of the above; fails when any of them failed or was cancelled. |

## 3. What `main` does after that

| Job | Needs | What it does |
|---|---|---|
| `cluster` | `check`, `chart` | `scripts/remote-up` on kind — which builds and loads all five images and installs the chart — then `mix troupe.e2e`. |
| `images` | `check`, `protocol`, `gui` | Five images, `linux/amd64`, pushed as `<registry>/<namespace>/<image>:sha-<short>`: the four servers from `docker/Dockerfile` with `RELEASE`, and `troupe-gui` from `clients/gui` as its whole context. `BUILD_COMMIT` and `BUILD_TIME` are passed, so the plane reports its commit at `/.well-known/troupe` — before this, every CI-built plane said `dev`. `GUI_BASE` (a repository variable, default `app`) is baked into the GUI's asset URLs. |
| `release` | the whole gate, `cluster` and `images` | Does nothing unless `VERSION` names a version with no tag. Then: promotes the five images to the version with `docker buildx imagetools create`, packages the chart at that version, pushes the tag `v<version>`, and opens a draft GitHub release with the chart. |
| `release-native` | `release` | `release.yml` with the tag: builds every native artifact and attaches it to the draft. |
| `publish` | `release-native` | Downloads every asset, writes one `SHA256SUMS`, and publishes — as a prerelease for a version with a `-` in it. |
| `deploy` | `release` | In the `production` environment: `scripts/deploy` with the release's chart. A prerelease renders against the cluster and changes nothing. |

The tag is pushed with the workflow's own token, which starts no other workflow; that is
why everything a release does happens in this one run, and why it cannot run twice.

```
changes ─┬─► check ──┬──────────────► cluster ─┐
         ├─► chart ──┘                          │
         ├─► protocol ─┐                        │
         ├─► gui ──────┴─► images ──────────────┼─► release ─┬─► release-native ─► publish
         ├─► tui ───────────────────────────────┤            └─► deploy
         ├─► gui-e2e ───────────────────────────┘
         ├─► versions
         └─► native (pull requests)             ci-ok ◄── every pull-request job
```

## 4. `release.yml`: the native builds

| Job | Runners | Produces | Smoke test |
|---|---|---|---|
| `daemon` | `ubuntu-24.04`, `ubuntu-24.04-arm`, `macos-15-intel`, `macos-14`, `windows-2022` | `troupe-daemon-<version>-<target>.tar.gz`, built in `apps/troupe_daemon` so only the harness compiles | unpack; `version`, `status`, `run`, `status`, `eval` (Windows: `version`, `status`, and a zstd round trip in `eval`) |
| `tui` | the same five | `troupe-<version>-<target>[.exe]`, a Burrito binary built in `clients/tui` (Linux targets on musl) | `--version` cold and warm, then a headless fake-provider run in the embedded daemon that must write `hello.txt` |
| `tui-containers` | `ubuntu-24.04` | — | the Linux binary in `ubuntu:24.04` and `alpine:3.20`, with no Erlang in either |
| `desktop` | `macos-14` (universal), `windows-latest`, `ubuntu-22.04` (the glibc floor) | `.dmg`, `.exe`/`.msi`, `.deb`/`.rpm`/`.AppImage` from `tauri-action`, unsigned until the `APPLE_*` / `AZURE_*` secrets exist | — |
| `attach` | `ubuntu-latest` | — | only with a tag: uploads every artifact to that draft release |

The desktop app's version is `VERSION` without its pre-release part, because WiX refuses
a non-numeric pre-release identifier; `scripts/version.exs` writes it that way.

## 5. Secrets, variables and environments

| Name | Kind | Where | Used by |
|---|---|---|---|
| `REGISTRY`, `REGISTRY_NAMESPACE`, `REGISTRY_USERNAME`, `REGISTRY_PASSWORD` | secrets | repository | `images`, `release`. All four or none: without them nothing is published and the run summary says which are missing; a release fails, because a release is its images. |
| `GUI_BASE` | variable | repository | `images`: the GUI's mount path, default `app`. |
| `KUBECONFIG` | secret | `production` environment | `deploy`, `deploy.yml`: the `troupe-deployer` account's kubeconfig — `kubectl apply -f deploy/ci-deployer.yaml`, then `scripts/ci-kubeconfig`. |
| `DEPLOY_VALUES` | secret | `production` environment | the deployment's Helm values file. |
| `PLANE_URL` | variable | `production` environment | where `scripts/deploy` asks `/.well-known/troupe` which version is running. |
| `APPLE_*`, `AZURE_*` | secrets | repository | `release.yml`'s `desktop` job, to sign; absent, the build is unsigned. |

`production`'s deployment policy should allow `main` alone, so no pull request can reach
its secrets. A required reviewer on it is optional: with one, `deploy` waits for a second
person; without, the review of the pull request that changed `VERSION` is the approval.
`HARNESS_TOKEN`, which the TUI's and the daemon's workflows used to fetch this repository
as a private git dependency, is no longer read by anything.

## 6. Caches

| Cache | Jobs | Key |
|---|---|---|
| `deps`, `_build` | `check`, `protocol` | `${{ runner.os }}-mix-${{ hashFiles('mix.lock') }}` |
| `clients/tui/deps`, `clients/tui/_build` | `tui` | `${{ runner.os }}-tui-` and both locks |
| pnpm store | `gui`, `gui-e2e`, `desktop` | `actions/setup-node`'s own, on `clients/gui/pnpm-lock.yaml` |
| Docker layers | `images` | `type=gha`, one scope per image |
| Rust | `desktop` | `swatinem/rust-cache`, one key per target |

## 7. What is not in CI

- **A real roll is only ever a release.** `deploy.yml --dry-run` and a release candidate
  render against the cluster; nothing rolls a cluster from a pull request, and there is
  no staging environment to roll one to.
- **Signing.** The desktop installers and the Windows binaries are unsigned until the
  secrets exist; the images are not signed at all.
- **The native builds on every merge.** They run on pull requests that touch them,
  nightly, and at a release — a harness change that breaks the Windows build is found the
  next morning, not at the merge.
