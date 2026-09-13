# Build

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).

Two kinds of artefact come out of the umbrella: four server images built by
`docker/Dockerfile`, and one client binary per target built by Burrito. Plus three
generators whose output is committed.

## 1. The four server images

### The Dockerfile

`docker/Dockerfile` is "One Dockerfile for the four server releases. `RELEASE` picks
which" (`:1`). Two stages:

| Stage | Base | What happens | Lines |
|---|---|---|---|
| `build` | `hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}` (defaults `1.20.4`, `28.5.0.5`, `bookworm-20260824-slim`) | `apt-get install build-essential git ca-certificates`; `MIX_ENV=prod`; `mix local.hex`, `local.rebar`; copy `mix.exs`, `mix.lock` and every `apps/*/mix.exs`; `mix deps.get --only prod` (fetch only — `deps.compile` cannot run before the sibling apps' source exists, `:35-38`); copy `config`, `apps`, `native`; `mix deps.compile && mix compile && mix release ${RELEASE} --overwrite`; move `_build/prod/rel/${RELEASE}` to `/app/release` | `:7-46` |
| `runtime` | `debian:${DEBIAN_VERSION}` | `libstdc++6 openssl libncurses6 locales ca-certificates`, plus `git bubblewrap` **only when `RELEASE=troupe_worker`**; `en_US.UTF-8` locale; user and group `troupe`, uid/gid 1000 ("the uid the operator's pod spec asks for", `:66`); `WORKDIR /app`; copy the release; `ENV RELEASE_NAME=${RELEASE}`; `ENTRYPOINT ["/bin/sh", "-c", "exec /app/bin/${RELEASE_NAME} start"]` | `:48-78` |

The build argument `RELEASE` defaults to `troupe_operator` in both stages (`:13,50`).
`git` and `bubblewrap` are confined to the worker image because "a namespace-juggling
sandbox helper and a network client are the two things one would least like to find in
the image that is internet-facing and the image that holds every cluster privilege"
(`:52-56`). `exec` in the entrypoint is so "Kubernetes' SIGTERM has to become a graceful
stop, not a killed shell" (`:76-77`). There is no `EXPOSE` and no `HEALTHCHECK`; ports
and probes are the chart's business.

The worker release runs `Troupe.Release.build_reapers/1` between `:assemble` and `:tar`
(`mix.exs:75`), so `mix compile.reaper` runs with `TROUPE_REAPER_TARGETS=all` inside the
image and the result is copied into `lib/troupe_core-<version>/priv/reaper`
(`apps/troupe_core/lib/troupe/release.ex:56-71`). A laptop's `priv/reaper` is excluded
from the context because it "would be the wrong architecture with the right name"
(`.dockerignore:14-17`), and the comment there says "The worker release builds its own
inside the image". The `build` stage, however, installs only `build-essential git
ca-certificates` (`docker/Dockerfile:15-17`) and the `hexpm/elixir` base does not ship
Zig, so on a plain reading `mix compile.reaper` prints "zig not found on PATH, skipping
native build" (`compile.reaper.ex:45-53`), `build_reapers/1` finds no `priv/reaper` to
copy (`release.ex:62-69`), and the worker image carries no reaper — after which
`Troupe.Reaper.path/0` returns `{:error, :reaper_missing}` for every `shell` call
(`apps/troupe_core/lib/troupe/reaper.ex:20-25`). Nothing in `REPORT.md`, `DECISIONS.md`
or `ARCHITECTURE.md` mentions the reaper in the image build. The image was not built for
this audit; Unconfirmed, and worth a check before relying on `shell` in a pod.

### scripts/build-images

```bash
scripts/build-images
```

```bash
scripts/build-images troupe_worker
```

```bash
TROUPE_REGISTRY=rg.fr-par.scw.cloud/troupe TROUPE_IMAGE_TAG=0.2.0 TROUPE_PUSH=true scripts/build-images
```

| Behaviour | Code |
|---|---|
| Builds `troupe_operator troupe_plane troupe_worker troupe_a2a` unless arguments name a subset | `scripts/build-images:23-25` |
| Image name `${TROUPE_REGISTRY:-ghcr.io/objective-mj}/troupe-<release with _ as ->:${TROUPE_IMAGE_TAG:-dev}` | `:19-20,26` |
| `docker build --platform linux/amd64 --file docker/Dockerfile --build-arg RELEASE=<release>` — explicit so a non-amd64 laptop does not build an image "the node pool cannot run" | `:28-32` |
| `TROUPE_PUSH=true` pushes; otherwise, if `kind get clusters` lists `${TROUPE_KIND_CLUSTER:-troupe-dev}`, `kind load docker-image` into it; otherwise nothing | `:34-40` |

Discrepancy: `docs/deploying-on-scaleway.md:116-120` shows the Scaleway push without
`TROUPE_PUSH=true` and says the script "builds all three server images"; it builds four
and pushes only with the variable set.

`scripts/remote-up` calls this script and then `kubectl rollout restart` on the plane
and operator, because "a rebuilt image under the same tag changes nothing in the pod
spec, so Kubernetes has no reason to replace the pods" (`scripts/remote-up:148-153`).

## 2. The client binary

### The release

`mix.exs:77-101`: release `troupe` with applications `troupe_core`, `troupe_protocol`,
`troupe_gateway`, `troupe_tui`, `troupe_ctl` (in that order; the CLI last because its
`troupe daemon` blocks, `apps/troupe_ctl/lib/troupe/ctl/application.ex:5-8`),
`include_executables_for: [:unix, :windows]`, steps `:assemble`,
`Troupe.Release.build_reapers/1`, `Troupe.Release.verify_linux_nif/1`, `Burrito.wrap/1`,
and five Burrito targets:

| Target | `os` / `cpu` | CI runner (`ci.yml:256-260`) |
|---|---|---|
| `linux_x86_64` | linux / x86_64 | `ubuntu-latest` |
| `linux_aarch64` | linux / aarch64 | `ubuntu-24.04-arm` |
| `macos_x86_64` | darwin / x86_64 | `macos-15-intel` |
| `macos_aarch64` | darwin / aarch64 | `macos-14` |
| `windows_x86_64` | windows / x86_64 | `windows-latest` |

Cross-building is not supported: "rustler_precompiled resolves the ExRatatui NIF against
the build host, so a macOS binary built on Linux would carry a Linux .so and fail at NIF
load" (`ci.yml:252-255`, `scripts/build-local:2-7`, `README.md:226-229`). One target per
native runner is the whole design of the `build` job.

### scripts/build-local

```bash
scripts/build-local
```

What it does, in order (`scripts/build-local`):

| Step | Lines |
|---|---|
| Requires `zig` and `xz` on `PATH`; requires `zig version` to be exactly `0.16.0` ("Burrito 1.6 hard-pins Zig 0.16.0") | `:12-23` |
| Target: `BURRITO_TARGET` if set, else derived from `uname` (`linux_*`, `macos_*`, `windows_x86_64` under MINGW/MSYS/CYGWIN) | `:25-41` |
| Sets `ZIG_LOCAL_CACHE_DIR` and `ZIG_GLOBAL_CACHE_DIR` under `${TMPDIR:-/tmp}/troupe-zig-cache` because "Zig 0.16 uses renameat2 with flags that ecryptfs and some network filesystems reject with EINVAL" | `:43-49` |
| `TARGET_ABI=musl` for `linux_*`: "The Linux wrapper carries a musl ERTS, so the bundled NIF must be the musl variant" | `:51-54` |
| `unset EX_RATATUI_BUILD`: a locally built crate ignores `TARGET_ABI` | `:56-58` |
| `MIX_ENV=prod`, `BURRITO_TARGET`, `TROUPE_REAPER_TARGETS=all`; `mix deps.get`; `mix release troupe --overwrite` (named, because the umbrella has more than one release) | `:60-68` |
| Reads the version with `mix run --no-start --no-compile`, clears Burrito's payload cache (`~/.local/share/.burrito/troupe_erts-*`, or `~/Library/Application Support/.burrito` on macOS) because "a rebuild that does not change `version:` re-runs the cached copy", and renames `burrito_out/troupe_<target>` to `burrito_out/troupe-<version>-<target>[.exe]` | `:70-97` |

`Troupe.Release.verify_linux_nif/1` runs for any `BURRITO_TARGET` starting with `linux`
and byte-scans the assembled `ex_ratatui` `.so` for `libc.so.6` or `GLIBC_`, raising with
the rebuild command if it finds either (`apps/troupe_core/lib/troupe/release.ex:19-46,80-98`).
It exists because ExRatatui's own check keys off `BURRITO_TARGET` being literally
`"linux"` (`:14-17`).

The same steps by hand, for a Linux host:

```bash
TARGET_ABI=musl BURRITO_TARGET=linux_x86_64 TROUPE_REAPER_TARGETS=all MIX_ENV=prod mix release troupe --overwrite
```

CI's `build` job runs the equivalent (`ci.yml:284-303`), then names the artefact
`troupe-<version>-<target><ext>`, smoke-tests it with the fake provider, records size and
cold/warm start in the step summary, and uploads it (`ci.yml:305-368`; see
[ci-cd.md](ci-cd.md)).

### The reaper

`mix compile.reaper` is a `Mix.Task.Compiler` appended to `troupe_core`'s compilers
(`apps/troupe_core/mix.exs:14-15`). It runs `zig build-exe native/reaper/reaper.zig
-target <triple> -O ReleaseSafe -lc -fstrip` into `apps/troupe_core/priv/reaper/<triple>/reaper[.exe]`
for the host triple by default, all five (`x86_64-linux-musl`, `aarch64-linux-musl`,
`x86_64-macos`, `aarch64-macos`, `x86_64-windows`) under `TROUPE_REAPER_TARGETS=all`, or
a comma-separated list (`compile.reaper.ex:26-32,78-134`). Outputs are skipped when newer
than the source (`:136-141`) and `mix clean` removes `priv/reaper` (`:72-76`).

## 3. Generated, committed files

### Protocol schema

```bash
mix troupe.schema.gen
```

Writes `protocol/schema/v1/<commands|events>/*.json` and `index.json` from
`Troupe.Protocol.Schema.documents/0`; never deletes a document for a type that no longer
exists, so the diff task can report the removal (`apps/troupe_protocol/lib/mix/tasks/troupe.schema.gen.ex:26-48`).

```bash
mix troupe.schema.diff
```

Compares the committed documents with the current definitions and raises on any field
removed, renamed, retyped or newly required; a compatible change passes and reminds you
to regenerate (`troupe.schema.diff.ex:26-45,57-76`). CI runs both and then
`git diff --exit-code protocol/schema/v1` (`.github/workflows/ci.yml:229-236`).

### Console assets

```bash
mix troupe.admin.assets
```

Concatenates `deps/phoenix/priv/static/phoenix.min.js`,
`deps/phoenix_html/priv/static/phoenix_html.js` and
`deps/phoenix_live_view/priv/static/phoenix_live_view.min.js` plus a small boot script
into `apps/troupe_plane/priv/static/app.js` (`apps/troupe_plane/lib/mix/tasks/troupe.admin.assets.ex:34-42,77-141`).

```bash
mix troupe.admin.tokens
```

Renders `docs/design/admin/tokens.json` into `apps/troupe_plane/priv/static/tokens.css`
(dark values on `:root`, light values under `[data-theme="light"]` and
`prefers-color-scheme: light`) and writes the status list to
`apps/troupe_plane/priv/design/statuses.json` (`troupe.admin.tokens.ex:19-31,35-60`).

Both tasks accept `--check`, which regenerates into memory and fails if the committed
file differs (`troupe.admin.assets.ex:59-75`, `troupe.admin.tokens.ex:81-90`). Their
moduledocs say `--check` is "what CI runs" (`troupe.admin.assets.ex:28-29`,
`troupe.admin.tokens.ex:16-17`). Discrepancy: `.github/workflows/ci.yml` has no step
that runs either task. Run them after a Phoenix dependency bump or a tokens change and
commit the result.

## 4. Version

Every `mix.exs` and the chart say `0.2.0`; the CI `build` job reads
`Mix.Project.config()[:version]` to name artefacts (`ci.yml:309`) and the `images` job
tags `sha-<7>` on every push plus the bare version on a `v*` tag (`ci.yml:165-170`). The
repository has no `v*` tags ("there are no release tags: 0.2.0 is the in-development
set", `DECISIONS.md:1877`; [../AUDIT.md](../AUDIT.md) open question 15). Bumping means editing `mix.exs:4`, each `apps/*/mix.exs:7`,
`charts/troupe/Chart.yaml` (`version` and `appVersion`), the image tags in
`charts/troupe/values.small.yaml` and `values.scaleway.yaml`, and recording a new fixture
set with `mix troupe.fixtures.record <version>` if the fold changed meaning.
