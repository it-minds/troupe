# CI and delivery

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).

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

## 1. Triggers and shared environment

| Item | Value | Lines |
|---|---|---|
| `on.push.branches` | `["**"]` — every branch | `ci.yml:10-11` |
| `on.push.tags` | `["v*"]` | `:12` |
| `on.pull_request` | all | `:13` |
| `env.ELIXIR_VERSION` | `1.20.4` | `:16` |
| `env.OTP_VERSION` | `28.5.0.5` | `:17` |
| `env.ZIG_VERSION` | `0.16.0` | `:18` |

## 2. The jobs

### `check` — "compile, format, credo, boundaries, test" (`ci.yml:21-90`)

Runner `ubuntu-latest`. Service container `postgres:16` with `POSTGRES_USER=troupe`,
`POSTGRES_PASSWORD=troupe`, `POSTGRES_DB=troupe_plane_test`, mapped `55432:5432`, health
check `pg_isready` every 5 s up to 12 times (`:31-43`). The comment explains the port:
`config/config.exs` points the test repo at `localhost:55432`, "so CI and a laptop run
from one configuration", and without a database "a green run proved nothing about the
plane" (`:24-30`).

| # | Step | Command / action | Lines |
|---|---|---|---|
| 1 | checkout | `actions/checkout@v4` | `:45` |
| 2 | BEAM | `erlef/setup-beam@v1` with the two versions | `:47-50` |
| 3 | Zig | `mlugg/setup-zig@v1` 0.16.0 | `:52-54` |
| 4 | Install inotify-tools | `sudo apt-get install -y inotify-tools` — "without it those tests skip and the polling backend is all that gets covered" | `:56-59` |
| 5 | cache | `actions/cache@v4` on `deps` and `_build`, key `${{ runner.os }}-mix-${{ hashFiles('mix.lock') }}`, restore-key prefix `-mix-` | `:61-67` |
| 6 | deps | `mix deps.get` | `:69` |
| 7 | Compile with warnings as errors | `MIX_ENV=test mix compile --force --warnings-as-errors` | `:71-72` |
| 8 | format | `mix format --check-formatted` (root `.formatter.exs` only; see [conventions.md](conventions.md) §3) | `:74` |
| 9 | credo | `mix credo --strict` | `:75` |
| 10 | Boundaries | `MIX_ENV=test mix troupe.boundaries` | `:77-80` |
| 11 | Migrate the plane's test database | `MIX_ENV=test mix ecto.create --quiet && MIX_ENV=test mix ecto.migrate --quiet` | `:82-85` |
| 12 | Test (10 consecutive runs) | `for i in $(seq 10); do mix test || exit 1; done` — "a race that shows up one time in five is a bug this project cares about" | `:87-90` |

Not provided by this job: a kubeconfig, MinIO, OpenBao, `bubblewrap`. Suites that need
them behave as described in [testing.md](testing.md) §3.

### `chart` — "helm lint, render, kubeconform" (`ci.yml:92-128`)

Runner `ubuntu-latest`. No `needs`; nothing needs it.

| # | Step | Command | Lines |
|---|---|---|---|
| 1 | checkout | `actions/checkout@v4` | `:96` |
| 2 | helm | `azure/setup-helm@v4` | `:98` |
| 3 | Lint, with each values file that is meant to install | `helm lint charts/troupe`, then with `values.small.yaml`, then with `values.scaleway.yaml` | `:100-104` |
| 4 | The chart refuses unclustered replicas | `helm template … --set plane.replicas=2 --set plane.distribution=none` must fail | `:106-113` |
| 5 | Render and validate | for `values.small.yaml` and `values.scaleway.yaml`: `helm template troupe charts/troupe --namespace troupe-system --include-crds --values …` piped into `ghcr.io/yannh/kubeconform:v0.6.7 -strict -summary -ignore-missing-schemas -kubernetes-version 1.31.0` | `:115-128` |

`dev/kind/values.yaml` is not linted or rendered here.

### `protocol` — "schema compatibility and the Python client" (`ci.yml:197-242`)

Runner `ubuntu-latest`. No `needs`.

| # | Step | Command | Lines |
|---|---|---|---|
| 1 | checkout | `actions/checkout@v4` | `:201` |
| 2 | BEAM | `erlef/setup-beam@v1` | `:203-206` |
| 3 | Zig | `mlugg/setup-zig@v1` | `:208-210` |
| 4 | Python | `actions/setup-python@v5`, `3.12` | `:212-214` |
| 5 | cache | same key as `check` | `:216-222` |
| 6 | deps | `mix deps.get` | `:224` |
| 7 | Schema compatibility | `mix troupe.schema.diff` — "Fields may be added; they may not be removed, renamed, retyped, or newly made required" | `:226-230` |
| 8 | Committed schema is current | `mix troupe.schema.gen` then `git diff --exit-code protocol/schema/v1` | `:232-236` |
| 9 | Python reference client, end to end | `mix test apps/troupe_gateway/test/troupe/gateway/python_client_test.exs --trace` | `:238-242` |

### `images` — "image ${{ matrix.release }}" (`ci.yml:130-195`)

`needs: [check, protocol]`. `if: github.event_name == 'push'` — "A push needs a
credential and a pull request from a fork has none" (`:133-135`). Runner
`ubuntu-latest`. Permissions `contents: read`, `packages: write`. Matrix
`release: [troupe_operator, troupe_plane, troupe_worker, troupe_a2a]`, `fail-fast: false`.

| # | Step | What | Lines |
|---|---|---|---|
| 1 | checkout | `actions/checkout@v4` | `:145` |
| 2 | Resolve the registry and the tags | `registry=${REGISTRY:-ghcr.io}`; `namespace=${REGISTRY_NAMESPACE:-$GITHUB_REPOSITORY_OWNER}`; `image=<registry>/<namespace>/<release with _ as ->` lower-cased; tags `<image>:sha-<7 chars of GITHUB_SHA>` on every push, plus `<image>:<tag without v>` when `GITHUB_REF` is `refs/tags/v*`; outputs `registry` and `tags` | `:153-173` |
| 3 | buildx | `docker/setup-buildx-action@v3` | `:175` |
| 4 | login | `docker/login-action@v3` to that registry with `secrets.REGISTRY_USERNAME || github.actor` and `secrets.REGISTRY_PASSWORD || secrets.GITHUB_TOKEN` | `:177-181` |
| 5 | build and push | `docker/build-push-action@v6`: context `.`, file `docker/Dockerfile`, `build-args: RELEASE=<release>`, `platforms: linux/amd64`, `push: true`, `cache-from: type=gha`, `cache-to: type=gha,mode=max` | `:186-195` |

Secrets used: `REGISTRY`, `REGISTRY_NAMESPACE`, `REGISTRY_USERNAME`, `REGISTRY_PASSWORD`;
`GITHUB_TOKEN` as the fallback password (`:147-152,155-157,180-181`). With none set the
images go to `ghcr.io/<owner>/troupe-<release>`. `REGISTRY_NAMESPACE` exists because
"Scaleway's registry wants its namespace there, not the GitHub owner" (`:149-150`).

Image naming, for reference: `ghcr.io/objective-mj/troupe-plane:sha-3f7c91f` on a branch
push to that owner; `rg.fr-par.scw.cloud/troupe/troupe-plane:0.2.0` on tag `v0.2.0` with
the Scaleway secrets set. `sha-<7>` tags are pushed on every branch push
([../AUDIT.md](../AUDIT.md) §3.16). Discrepancy: the comment at `:184-185` says "The
three images share every layer"; the matrix has four.

### `build` — "build ${{ matrix.target }}" (`ci.yml:244-368`)

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
| 1 | checkout | `actions/checkout@v4` | `:263` |
| 2 | BEAM | `erlef/setup-beam@v1` | `:265-268` |
| 3 | Zig | `mlugg/setup-zig@v1` | `:270-272` |
| 4 | Install xz (macOS) | `brew install xz \|\| true` | `:274-276` |
| 5 | Install xz and 7zip (Windows) | `choco install -y xz 7zip` | `:278-280` |
| 6 | deps | `mix deps.get` | `:282` |
| 7 | Build the release | `MIX_ENV=prod`, `BURRITO_TARGET=<target>`, `TROUPE_REAPER_TARGETS=all`; `TARGET_ABI=musl` for `linux_*`; `ZIG_LOCAL_CACHE_DIR` and `ZIG_GLOBAL_CACHE_DIR` under `$RUNNER_TEMP`; `mix release --overwrite` | `:284-303` |
| 8 | Name the artifact | version from `mix run --no-start -e 'IO.write(Mix.Project.config()[:version])'`; `mv burrito_out/troupe_<target><ext> burrito_out/troupe-<version>-<target><ext>`; outputs `name`, `version` | `:305-314` |
| 9 | Smoke test the artifact | `--version`; a fake-provider script with `write_file` and `shell`; `run "smoke" --headless --workspace smoke/ws --auto-approve`; `grep -q packaged smoke/ws/hello.txt`; `sessions --workspace smoke/ws` must print `Sessions for` or `No sessions` | `:316-342` |
| 10 | Report size and start-up cost | binary size, cold and warm `--version` timings into `$GITHUB_STEP_SUMMARY` after `maintenance uninstall` | `:344-362` |
| 11 | upload | `actions/upload-artifact@v4`, name and path `burrito_out/<name>`, `if-no-files-found: error` | `:364-368` |

No cache step: this job downloads deps fresh on each runner.

### `containers` — "clean-container check (linux x86_64)" (`ci.yml:370-419`)

`needs: build`. Runner `ubuntu-latest`.

| # | Step | What | Lines |
|---|---|---|---|
| 1 | checkout | `actions/checkout@v4` | `:375` |
| 2 | download | `actions/download-artifact@v4`, pattern `troupe-*-linux_x86_64`, merged into `dist/` | `:377-381` |
| 3 | Run in glibc and musl containers with nothing installed | for `ubuntu:24.04` and `alpine:latest`: assert `erl`, `elixir`, `mix`, `inotifywait` are absent; `--version`; a headless fake-provider run; `grep packaged`; a `--watch` run that must print `polling for changes` | `:383-419` |

### `installer-sh` — "install.sh (clean ubuntu container, zsh user)" (`ci.yml:422-442`)

`needs: build`. Runner `ubuntu-latest`. Downloads the linux artefact, writes
`release/SHA256SUMS`, and runs `scripts/test-install.sh` inside `ubuntu:24.04` with the
repository mounted at `/src` (`:429-442`). The step is named "Install, upgrade, reject a corrupt artifact, uninstall": the script installs from a `file://` release directory, upgrades and checks the previous binary is kept, corrupts an artifact and asserts the installer refuses it on the checksum, then uninstalls and purges (`scripts/test-install.sh`). The Windows job below runs the same scenario through `scripts/test-install.ps1`.

### `installer-ps1` — "install.ps1 (windows runner)" (`ci.yml:444-468`)

`needs: build`. Runner `windows-latest`. Downloads the Windows artefact, writes
`SHA256SUMS` with `Get-FileHash`, runs `./scripts/test-install.ps1 -ReleaseDir release`
(`:451-468`).

### `release` — "publish" (`ci.yml:470-494`)

`needs: [build, containers, installer-sh, installer-ps1]`.
`if: startsWith(github.ref, 'refs/tags/v')`. Runner `ubuntu-latest`. Permissions
`contents: write`.

| # | Step | What | Lines |
|---|---|---|---|
| 1 | download | `actions/download-artifact@v4`, pattern `troupe-*`, merged into `dist/` | `:478-482` |
| 2 | Checksums | `sha256sum troupe-* > SHA256SUMS` in `dist/` | `:484-488` |
| 3 | publish | `softprops/action-gh-release@v2` with `dist/troupe-*` and `dist/SHA256SUMS` | `:490-494` |

`install.sh` and `install.ps1` default to downloading from
`github.com/objective-mj/troupe` releases ([../AUDIT.md](../AUDIT.md) §4.2).

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
| `deps`, `_build` | `check`, `protocol` | `${{ runner.os }}-mix-${{ hashFiles('mix.lock') }}`, restore-keys `${{ runner.os }}-mix-` (`:61-67,216-222`) |
| Docker layer cache | `images` | GitHub Actions cache, `type=gha,mode=max`, shared across the four-image matrix (`:194-195`) |
| Zig cache | `build` | not cached; redirected to `$RUNNER_TEMP` per run (`:297-301`) |

## 6. What is not in CI

- No kind or cluster end-to-end run; the operator's cluster suites and the plane's
  enrolment tests have no cluster in `check` ([testing.md](testing.md) §3).
- No MinIO or OpenBao service in `check`; the protocol object-store, KMS and every
  worker `SessionCase` suite have no backend there.
- No `mix troupe.admin.assets --check` or `mix troupe.admin.tokens --check` step,
  although both tasks' moduledocs say CI runs them ([build.md](build.md) §3).
- No `helm upgrade`, `kubectl apply`, or environment promotion of any kind.
- No signing of binaries or images (`README.md:325-326`: "no code signing").
