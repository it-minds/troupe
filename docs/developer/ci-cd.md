# CI and delivery

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13, and revised
> against the `ci/green-suite` work of 2026-09-14, which is the first time any of these
> jobs past `check` has run. See [AUDIT.md](../AUDIT.md).

> **Re-audited 2026-09-14.** This repository is the remote and ships no client. The
> Kubernetes-only change removed `apps/troupe_tui`, `apps/troupe_ctl`, the `troupe`
> Burrito release, `install.sh`, `install.ps1`, `scripts/build-local`,
> `scripts/test-install.*` and the `build`, `containers`, `installer-sh` and
> `installer-ps1` CI jobs, and moved `clients/python` to
> `apps/troupe_gateway/test/conformance/`. Statements below have been brought in line with
> that; line citations that predate it refer to the tree at commit `20fe871`.

One workflow: `.github/workflows/ci.yml`, named `ci`. Five jobs. Every step is listed
below in file order.

Three facts first, because the rest of this document is detail:

- **There is no deploy step.** No job applies a chart, touches a cluster or talks to a
  staging or production environment. Delivery ends at four images in a registry and, on a
  `v*` tag, a packaged chart on a GitHub release. How a build reaches a cluster is a
  manual procedure in [deployment.md](deployment.md).
- **No branch protection or required-check configuration is recorded in the
  repository.** Which jobs gate a merge, if any, lives in the forge's settings, and the
  workflow header says it is written to run on both GitHub and Forgejo (`ci.yml:4-6`).
  [../AUDIT.md](../AUDIT.md) open question 2.
- `docs/deploying-on-scaleway.md:335-339` says "CI has never run". Commit `9ae7d3c`
  ("Deploying it on a real cluster, and the bugs only a cluster finds") and the same
  document's change list describe a real deployment. The audit flags the claim as
  unconfirmed (open question 1); nothing in the repository records a run either way.
- **Every run before 2026-09-14 died in the first minute**, at `mlugg/setup-zig@v1`,
  which asks for `zig-linux-x86_64-<version>.tar.xz` — the name Zig used before 0.15
  turned its release names target-first. Nothing downstream of `check` and `protocol`
  had ever executed, so the errors documented below under each job (a `mix release`
  with no release name, a clean-container check greping for a line the program does not
  print, a worker image with no `reaper` in it) were all found by running them for the
  first time rather than by a regression.

## 1. Triggers and shared environment

| Item | Value | Lines |
|---|---|---|
| `on.push.branches` | `["**"]` — every branch | `ci.yml:10-11` |
| `on.push.tags` | `["v*"]` | `:12` |
| `on.pull_request` | all | `:13` |
| `concurrency.group` | `<workflow>-<ref>` | `:20-22` |
| `concurrency.cancel-in-progress` | true except on `main` and `refs/tags/*` | `:22` |
| `env.ELIXIR_VERSION` | `1.20.4` | `:25` |
| `env.OTP_VERSION` | `28.5.0.5` | `:26` |
| `env.ZIG_VERSION` | `0.16.0` | `:27` |

A branch with an open pull request still gets two runs per push — one `push`, one
`pull_request` — because they are different refs and so different concurrency groups.

## 2. The jobs

### `check` — "compile, format, credo, boundaries, test" (`ci.yml:30-110`)

Runner `ubuntu-latest`. No `services:` block. The three backing services come up from
`dev/docker-compose.yml` through `scripts/dev-up`, which is the same command a laptop
runs: `services:` has nowhere to put the two setup steps that make them usable — the
bucket needs versioning enabled before erasure can destroy prior versions, and OpenBao
needs a transit engine and an `ecdsa-p256` key before the plane can sign anything. With
only a Postgres here, the protocol object-store suite, the KMS suite, `Troupe.Plane.Tokens`
and every worker test that wants a durable tier failed on every run — 175 of them on the
last run that had no MinIO.

| # | Step | Command / action | Lines |
|---|---|---|---|
| 1 | checkout | `actions/checkout@v4` | `:34` |
| 2 | BEAM | `erlef/setup-beam@v1` with the two versions | `:36-39` |
| 3 | Zig | `mlugg/setup-zig@v2` 0.16.0 | `:41-43` |
| 4 | Install inotify-tools and bubblewrap | `apt-get install -y inotify-tools bubblewrap`, then `sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` — Ubuntu 24.04 restricts unprivileged user namespaces, which is the whole of how `bwrap` sandboxes without root | `:50-59` |
| 5 | Postgres, MinIO and OpenBao | `scripts/dev-up` | `:67-68` |
| 6 | cache | `actions/cache@v4` on `deps` and `_build`, key `${{ runner.os }}-mix-${{ hashFiles('mix.lock') }}` | `:70-76` |
| 7 | deps | `mix deps.get` | `:78` |
| 8 | Compile with warnings as errors | `MIX_ENV=test mix compile --force --warnings-as-errors` | `:80-81` |
| 9 | format | `mix format --check-formatted` (root `.formatter.exs` only; see [conventions.md](conventions.md) §3) | `:83` |
| 10 | credo | `mix credo --strict` | `:84` |
| 11 | Generated assets are current | `mix troupe.admin.assets --check`, `mix troupe.admin.tokens --check`, `mix troupe.theme --check` | `:91-95` |
| 12 | Boundaries | `MIX_ENV=test mix troupe.boundaries` | `:99-100` |
| 13 | Migrate the plane's test database | `MIX_ENV=test mix ecto.create --quiet && MIX_ENV=test mix ecto.migrate --quiet` | `:104-105` |
| 14 | Test (10 consecutive runs) | `for i in $(seq 10); do mix test || exit 1; done` — "a race that shows up one time in five is a bug this project cares about" | `:109-110` |

Step 11 is new: `troupe.admin.assets`, `troupe.admin.tokens` and `troupe.theme` each say
in their own moduledoc that CI runs them with `--check`, and none of them did.

Not provided by this job: a kubeconfig. The `:cluster` tests are excluded rather than
failed; see [testing.md](testing.md) §3.

### `chart` — "helm lint, render, kubeconform" (`ci.yml:112-148`)

Runner `ubuntu-latest`. No `needs`; nothing needs it.

| # | Step | Command | Lines |
|---|---|---|---|
| 1 | checkout | `actions/checkout@v4` | `:116` |
| 2 | helm | `azure/setup-helm@v4` | `:118` |
| 3 | Lint, with each values file that is meant to install | `helm lint charts/troupe`, then with `values.small.yaml`, then with `values.scaleway.yaml` | `:120-124` |
| 4 | The chart refuses unclustered replicas | `helm template … --set plane.replicas=2 --set plane.distribution=none` must fail | `:126-133` |
| 5 | Render and validate | for `values.small.yaml` and `values.scaleway.yaml`: `helm template troupe charts/troupe --namespace troupe-system --include-crds --values …` piped into `ghcr.io/yannh/kubeconform:v0.6.7 -strict -summary -ignore-missing-schemas -kubernetes-version 1.31.0` | `:135-148` |

`dev/kind/values.yaml` is not linted or rendered here.

### `protocol` — "schema compatibility and the Python client" (`ci.yml:238-283`)

Runner `ubuntu-latest`. No `needs`.

| # | Step | Command | Lines |
|---|---|---|---|
| 1 | checkout | `actions/checkout@v4` | `:221` |
| 2 | BEAM | `erlef/setup-beam@v1` | `:223-226` |
| 3 | Zig | `mlugg/setup-zig@v2` | `:228-230` |
| 4 | Python | `actions/setup-python@v5`, `3.12` | `:232-234` |
| 5 | cache | same key as `check` | `:236-242` |
| 6 | deps | `mix deps.get` | `:244` |
| 7 | Schema compatibility | `mix troupe.schema.diff` — "Fields may be added; they may not be removed, renamed, retyped, or newly made required" | `:249-250` |
| 8 | Committed schema is current | `mix troupe.schema.gen` then `git diff --exit-code protocol/schema/v1` | `:252-256` |
| 9 | Python reference client, end to end | `mix test apps/troupe_gateway/test/troupe/gateway/python_client_test.exs --trace` | `:261-262` |

### `images` — "image ${{ matrix.release }}" (`ci.yml:150-236`)

`needs: [check, protocol]`. `if: github.event_name == 'push'` — "A push needs a
credential and a pull request from a fork has none" (`:133-135`). Runner
`ubuntu-latest`. Permissions `contents: read`, `packages: write`. Matrix
`release: [troupe_operator, troupe_plane, troupe_worker, troupe_a2a]`, `fail-fast: false`.

| # | Step | What | Lines |
|---|---|---|---|
| 1 | checkout | `actions/checkout@v4` | `:165` |
| 2 | Resolve the registry and the tags | `registry=${REGISTRY:-ghcr.io}`; `namespace=${REGISTRY_NAMESPACE:-$GITHUB_REPOSITORY_OWNER}`; `image=<registry>/<namespace>/<release with _ as ->` lower-cased; tags `<image>:sha-<7 chars of GITHUB_SHA>` on every push, plus `<image>:<tag without v>` when `GITHUB_REF` is `refs/tags/v*`; outputs `registry` and `tags` | `:173-193` |
| 3 | buildx | `docker/setup-buildx-action@v3` | `:195` |
| 4 | login | `docker/login-action@v3` to that registry with `secrets.REGISTRY_USERNAME || github.actor` and `secrets.REGISTRY_PASSWORD || secrets.GITHUB_TOKEN` | `:197-201` |
| 5 | build and push | `docker/build-push-action@v6`: context `.`, file `docker/Dockerfile`, `build-args: RELEASE=<release>`, `platforms: linux/amd64`, `push: true`, `cache-from: type=gha`, `cache-to: type=gha,mode=max` | `:206-215` |

**The worker image used to ship without its `reaper`.** `docker/Dockerfile`'s build
stage installed no Zig, so `mix compile.reaper` printed a warning and built nothing, and
`.dockerignore:17` excludes a laptop's prebuilt copy on purpose. The image started
perfectly well and answered every `shell` call with `:reaper_missing` — a failure with
no symptom until a pod ran a command. The build stage now installs the pinned Zig for
the worker release and fails the build if the binary is not in the assembled release
(audit §3.21, now closed).

Secrets used: `REGISTRY`, `REGISTRY_NAMESPACE`, `REGISTRY_USERNAME`, `REGISTRY_PASSWORD`.
On `it-minds/troupe-remote` they name the Scaleway registry the cluster already pulls
from — `rg.fr-par.scw.cloud/troupe` — with the push key `create-ci-key.sh` mints, which
is the same credential `push-images.sh` uses by hand.

`REGISTRY` and `REGISTRY_PASSWORD` are now required together. There used to be a fallback
to `ghcr.io/<owner>` with the workflow's own token, described as what a fork or a first
run wants; the first time this job ran, a `REGISTRY_PASSWORD` that had been set on its own
was paired with the `ghcr.io` the absent `REGISTRY` defaulted to, and `docker login`
answered `denied: denied` — a credential for one registry offered to another. Without
both, the job builds nothing and names the missing secrets in the run summary. With none set the
images go to `ghcr.io/<owner>/troupe-<release>`. `REGISTRY_NAMESPACE` exists because
"Scaleway's registry wants its namespace there, not the GitHub owner" (`:149-150`).

Image naming, for reference: `ghcr.io/objective-mj/troupe-plane:sha-3f7c91f` on a branch
push to that owner; `rg.fr-par.scw.cloud/troupe/troupe-plane:0.2.0` on tag `v0.2.0` with
the Scaleway secrets set. `sha-<7>` tags are pushed on every branch push
([../AUDIT.md](../AUDIT.md) §3.16). Discrepancy: the comment at `:184-185` says "The
three images share every layer"; the matrix has four.

### `release` — "publish the chart"

`needs: [check, protocol, chart, images]`.
`if: startsWith(github.ref, 'refs/tags/v')`. Runner `ubuntu-latest`. Permissions
`contents: write`.

| # | Step | What |
|---|---|---|
| 1 | checkout, `azure/setup-helm@v4` | the chart is the artefact, so the chart has to be on disk |
| 2 | Package the chart at this version | `helm package charts/troupe --version <tag without v> --app-version <same> --destination dist`, so an install of that file pulls the images this run built rather than whatever `values.yaml` was last edited to say |
| 3 | publish | `softprops/action-gh-release@v2` with `dist/troupe-*.tgz`, and a body giving the `helm upgrade --install` line |

### The four jobs that are gone

`build`, `containers`, `installer-sh` and `installer-ps1` were the client half of this
pipeline: a matrix with one native runner per target building a Burrito executable, a
clean-container check that ran it in `ubuntu:24.04` and `alpine:latest` with no Erlang
installed, and the installers exercised end to end against a `file://` release directory.
`release` then attached the binaries and a `SHA256SUMS` to a GitHub release.

All four were deleted with the client itself. This repository is deployed to Kubernetes
and installed on no machine, so the only artefacts worth publishing are the four images —
which `images` already tags with the version on a `v*` tag — and the chart, which is what
`release` now packages. The open question the old `release` carried with it, that
`install.sh` pointed at a private repository's release assets and an anonymous install
would fail, went away with the installers rather than being answered.

## 3. Dependency graph

```
check ───┐
         ├──► images (push events only; 4 images) ──┐
protocol ┘                                          ├──► release (v* tags only)
chart ──────────────────────────────────────────────┘
```

`chart` used to gate nothing. It gates `release` now, because the thing `release`
publishes is the chart, and publishing one that `kubeconform` has not seen would be
worse than publishing nothing. Whether any job is a required check on `main` is not in
the repository.

## 4. Artefacts and where they end up

| Artefact | Produced by | Retention / destination |
|---|---|---|
| `<registry>/<namespace>/troupe-{operator,plane,worker,a2a}:sha-<7>` | `images`, every push | the registry named by secrets |
| `…:<version>` | `images`, on `v*` tags | same |
| `troupe-<version>.tgz` | `release`, on `v*` tags | attached to the GitHub release; `--version` and `--app-version` are the tag, so the chart pulls the images of the same run |

There is no binary artefact of any kind, and no `SHA256SUMS`: nothing here is downloaded
onto a machine and run.

## 5. Caches

| Cache | Jobs | Key |
|---|---|---|
| `deps`, `_build` | `check`, `protocol` | `${{ runner.os }}-mix-${{ hashFiles('mix.lock') }}`, restore-keys `${{ runner.os }}-mix-` (`:70-76,236-242`) |
| Docker layer cache | `images` | GitHub Actions cache, `type=gha,mode=max`, shared across the four-image matrix (`:214-215`) |
| Zig cache | `check`, `protocol` | `mlugg/setup-zig@v2`'s own cache, on by default |

## 6. What is not in CI

- No kind or cluster end-to-end run. The operator's cluster suites and the plane's
  enrolment tests are tagged `:cluster` and excluded rather than failed
  ([testing.md](testing.md) §3), so nothing here exercises a real API server: not
  admission, not the operator's reconciliation, not a `TokenReview`.
- No `helm upgrade`, `kubectl apply`, or environment promotion of any kind. Delivery
  ends at images in a registry and a chart on a release; see
  [deployment.md](deployment.md).
- No image signing.
- **Nothing runs the images.** This is the gap the Kubernetes-only change makes the
  important one: the client binary used to be smoke-tested on four native runners and in
  two clean containers, and that is exactly the work that has gone away. The Dockerfile
  refuses to produce a worker release with no `reaper` in it, which is the failure that
  used to be silent, but no job starts an image, runs a command through it, or brings a
  plane and a worker up together. A cluster job is the next thing this pipeline needs.
