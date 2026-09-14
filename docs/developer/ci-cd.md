# CI and delivery

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13, and revised
> against the `ci/green-suite` work of 2026-09-14, which is the first time any of these
> jobs past `check` has run. See [AUDIT.md](../AUDIT.md).

One workflow: `.github/workflows/ci.yml`, named `ci`. Nine jobs. Every step is listed
below in file order.

Three facts first, because the rest of this document is detail:

- **There is no deploy step.** No job applies a chart, touches a cluster or talks to a
  staging or production environment. Delivery ends at images in a registry and binaries
  on a GitHub release. How a build reaches a cluster is a manual procedure in
  [deployment.md](deployment.md).
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

### `protocol` — "schema compatibility and the Python client" (`ci.yml:217-262`)

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

### `images` — "image ${{ matrix.release }}" (`ci.yml:150-215`)

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

### `build` — "build ${{ matrix.target }}" (`ci.yml:264-375`)

`needs: [check, protocol]`. `fail-fast: false`. Matrix:

| `os` | `target` | `ext` |
|---|---|---|
| `ubuntu-latest` | `linux_x86_64` | |
| `ubuntu-24.04-arm` | `linux_aarch64` | |
| `macos-15-intel` | `macos_x86_64` | |
| `macos-14` | `macos_aarch64` | |
| `windows-latest` | `windows_x86_64` | `.exe` |

| # | Step | What | Lines |
|---|---|---|---|
| 1 | checkout | `actions/checkout@v4` | `:283` |
| 2 | BEAM | `erlef/setup-beam@v1` | `:285-288` |
| 3 | Zig | `mlugg/setup-zig@v2` | `:290-292` |
| 4 | Install xz (macOS) | `brew install xz \|\| true` | `:294-296` |
| 5 | Install xz and 7zip (Windows) | `choco install -y xz 7zip` | `:298-299` |
| 6 | Build the release | `BURRITO_TARGET=<target> bash scripts/build-local` | `:309-313` |
| 7 | Name the artifact | `basename` of `burrito_out/troupe-*-<target><ext>`; outputs `name` | `:315-321` |
| 8 | Smoke test the artifact | `--version`; a fake-provider script with `write_file` and `shell`; `run "smoke" --headless --workspace smoke/ws --auto-approve`; `grep -q packaged smoke/ws/hello.txt`; `sessions --workspace smoke/ws` must print `Sessions for` or `No sessions` | `:323-349` |
| 9 | Report size and start-up cost | binary size, cold and warm `--version` timings into `$GITHUB_STEP_SUMMARY` after `maintenance uninstall` | `:351-369` |
| 10 | upload | `actions/upload-artifact@v4`, name and path `burrito_out/<name>`, `if-no-files-found: error` | `:371-375` |

Step 6 used to be a copy of `scripts/build-local` inlined here, and the copy had
drifted: it ran `mix release --overwrite` with no release name, which the umbrella's
five releases make Mix refuse rather than guess between, and the step after it read the
version out of `mix run` without `--no-compile`, so the compiler's own progress would
have ended up in the filename. It now runs the script, which owns the musl ABI the Linux
wrapper's ERTS needs, the Zig cache directories that keep `renameat2` off a filesystem
that refuses it, the unset `EX_RATATUI_BUILD`, the release name, and the artifact name
`troupe-<version>-<target>`.

No cache step: this job downloads deps fresh on each runner.

### `containers` — "clean-container check (linux x86_64)" (`ci.yml:377-436`)

`needs: build`. Runner `ubuntu-latest`.

| # | Step | What | Lines |
|---|---|---|---|
| 1 | checkout | `actions/checkout@v4` | `:382` |
| 2 | download | `actions/download-artifact@v4`, pattern `troupe-*-linux_x86_64`, merged into `dist/` | `:384-388` |
| 3 | Run in glibc and musl containers with nothing installed | for `ubuntu:24.04` and `alpine:latest`: assert `erl`, `elixir`, `mix`, `inotifywait` are absent; `--version`; a headless fake-provider run; `grep packaged`; a `--watch` run that must also finish and write its file | `:390-436` |

The watch half used to grep the output for `polling for changes`, which is not a string
this codebase contains. The notice reads `watch: no native file watcher available,
polling every Nms` and is published as an *ephemeral* event while the session is being
created, before any client has subscribed — so a fresh headless run never prints it. The
check is now that the run finishes, which is what "the fallback happened rather than the
session dying with no backend" looks like from outside.

### `installer-sh` — "install.sh (clean ubuntu container, zsh user)" (`ci.yml:438-458`)

`needs: build`. Runner `ubuntu-latest`. Downloads the linux artefact, writes
`release/SHA256SUMS`, and runs `scripts/test-install.sh` inside `ubuntu:24.04` with the
repository mounted at `/src` (`:445-458`). The step is named "Install, upgrade, reject a
corrupt artifact, uninstall": the script installs from a `file://` release directory,
upgrades and checks the previous binary is kept, corrupts an artifact and asserts the
installer refuses it on the checksum, then uninstalls and purges
(`scripts/test-install.sh`). The Windows job below runs the same scenario through
`scripts/test-install.ps1`.

### `installer-ps1` — "install.ps1 (windows runner)" (`ci.yml:460-484`)

`needs: build`. Runner `windows-latest`. Downloads the Windows artefact, writes
`SHA256SUMS` with `Get-FileHash`, runs `./scripts/test-install.ps1 -ReleaseDir release`
(`:467-484`).

### `release` — "publish" (`ci.yml:486-510`)

`needs: [build, containers, installer-sh, installer-ps1]`.
`if: startsWith(github.ref, 'refs/tags/v')`. Runner `ubuntu-latest`. Permissions
`contents: write`.

| # | Step | What | Lines |
|---|---|---|---|
| 1 | download | `actions/download-artifact@v4`, pattern `troupe-*`, merged into `dist/` | `:494-498` |
| 2 | Checksums | `sha256sum troupe-* > SHA256SUMS` in `dist/` | `:500-504` |
| 3 | publish | `softprops/action-gh-release@v2` with `dist/troupe-*` and `dist/SHA256SUMS` | `:506-510` |

`install.sh:17` and `install.ps1:39` default to
`https://github.com/it-minds/troupe-remote/releases/latest/download`, which is where this
job publishes. They used to default to `objective-mj/troupe`, a repository that does not
resolve, and nothing in CI noticed because both installer jobs are pointed at a `file://`
directory instead ([../AUDIT.md](../AUDIT.md) §4.2). **An anonymous install still fails**:
this repository is private, so its releases are not downloadable without a token. Making
them public is a distribution decision, not a CI one.

## 3. Dependency graph

```
check ───┐
         ├──► images     (push events only; 4 images)
protocol ┘
check ───┐
         ├──► build (5 targets) ──► containers ───┐
protocol ┘                     ├──► installer-sh ─┼──► release (v* tags only)
                               └──► installer-ps1 ┘
chart   (gates nothing; nothing needs it)
```

Only `check` and `protocol` are prerequisites for anything. `chart` runs in parallel and
its failure stops no other job. Whether any job is a required check on `main` is not in
the repository.

## 4. Artefacts and where they end up

| Artefact | Produced by | Retention / destination |
|---|---|---|
| `troupe-<version>-<target>[.exe]` | `build`, one per matrix leg | workflow artefacts (default retention); attached to the GitHub release on a `v*` tag with `SHA256SUMS` |
| `<registry>/<namespace>/troupe-{operator,plane,worker,a2a}:sha-<7>` | `images`, every push | the registry named by secrets, else `ghcr.io/<owner>` |
| `…:<version>` | `images`, on `v*` tags | same |
| step summary with size and start-up cost | `build` | the run's summary page |

## 5. Caches

| Cache | Jobs | Key |
|---|---|---|
| `deps`, `_build` | `check`, `protocol` | `${{ runner.os }}-mix-${{ hashFiles('mix.lock') }}`, restore-keys `${{ runner.os }}-mix-` (`:70-76,236-242`) |
| Docker layer cache | `images` | GitHub Actions cache, `type=gha,mode=max`, shared across the four-image matrix (`:214-215`) |
| Zig cache | `build` | not cached; `scripts/build-local` redirects it under `$TMPDIR` per run (`scripts/build-local:44-49`) |
| Zig cache | `check`, `protocol` | `mlugg/setup-zig@v2`'s own cache, on by default |

## 6. What is not in CI

- No kind or cluster end-to-end run. The operator's cluster suites and the plane's
  enrolment tests are tagged `:cluster` and excluded rather than failed
  ([testing.md](testing.md) §3), so nothing here exercises a real API server: not
  admission, not the operator's reconciliation, not a `TokenReview`.
- No `helm upgrade`, `kubectl apply`, or environment promotion of any kind. Delivery
  ends at images in a registry and binaries on a release; see
  [deployment.md](deployment.md).
- No signing of binaries or images (`README.md:325-326`: "no code signing").
- No publishing anyone can install from: see the note under `release` above.
- Nothing checks the worker *image* the way the `build` matrix checks the client
  binary. The Dockerfile now refuses to produce a worker release with no `reaper` in
  it, which is the failure that used to be silent, but no job starts the image and
  runs a command through it.
