# Build

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).

> **Re-audited 2026-09-14.** This repository is the remote and ships no client. The
> Kubernetes-only change removed `apps/troupe_tui`, `apps/troupe_ctl`, the `troupe`
> Burrito release, `install.sh`, `install.ps1`, `scripts/build-local`,
> `scripts/test-install.*` and the `build`, `containers`, `installer-sh` and
> `installer-ps1` CI jobs, and moved `clients/python` to
> `apps/troupe_gateway/test/conformance/`. Statements below have been brought in line with
> that; line citations that predate it refer to the tree at commit `20fe871`.

One kind of artefact comes out of the umbrella: four server images, built by
`docker/Dockerfile` with `RELEASE` picking which. Plus the chart that deploys them, and
three generators whose output is committed.

## 1. The four server images

### The Dockerfile

`docker/Dockerfile` is "One Dockerfile for the four releases this repository has.
`RELEASE` picks which" (`:1`). Two stages:

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

## 2. There is no client binary

There used to be a fifth release, `troupe`: `troupe_core`, `troupe_protocol`,
`troupe_gateway`, `troupe_tui` and `troupe_ctl` wrapped by Burrito into one executable for
each of five targets, built by `scripts/build-local` on a laptop and by one native runner
per target in CI, verified by `Troupe.Release.verify_linux_nif/1`, installed by
`install.sh` and `install.ps1`, and smoke-tested in a clean container.

All of it is gone, and so are the two apps it packaged. This repository is deployed to
Kubernetes by `charts/troupe`; it is installed on no machine, so there is no machine to
build for and no target matrix to maintain. A terminal or graphical client is a separate
release from a separate repository that speaks [PROTOCOL.md](../../PROTOCOL.md), and the
plane's front page links to it through `plane.cliUrl` and `plane.appUrl`.

What this leaves is one build path — `docker/Dockerfile`, four times — and the reaper
inside it.

### The reaper

`mix compile.reaper` is a `Mix.Task.Compiler` appended to `troupe_core`'s compilers
(`apps/troupe_core/mix.exs:14-15`). It runs `zig build-exe native/reaper/reaper.zig
-target <triple> -O ReleaseSafe -lc -fstrip` into `apps/troupe_core/priv/reaper/<triple>/reaper[.exe]`
for the host triple by default, all five (`x86_64-linux-musl`, `aarch64-linux-musl`,
`x86_64-macos`, `aarch64-macos`, `x86_64-windows`) under `TROUPE_REAPER_TARGETS=all`, or
a comma-separated list. Outputs are skipped when newer than the source and `mix clean`
removes `priv/reaper`.

`Troupe.Release.build_reapers/1`, the worker release's second step, sets
`TROUPE_REAPER_TARGETS` to `x86_64-linux-musl,aarch64-linux-musl` — the two Linux triples
and nothing else. It used to set `all`: a pod cannot execute a macOS or a Windows binary,
and building three of them cost a Zig invocation each on every image build. The three
non-Linux triples stay in the task's own table because a developer's `mix test` runs
`shell` on their own machine, which is the only place they are ever built now.

The image build makes the reaper's absence loud rather than silent. `docker/Dockerfile`
installs pinned Zig for `RELEASE=troupe_worker` alone, and then fails the build if the
assembled release has no `*-linux-musl/reaper` — without that check the image starts
perfectly well and answers every `shell` call with `:reaper_missing`, which is a failure
that only ever appears in a pod.

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

### The front page's brand

```bash
mix troupe.theme
mix troupe.theme --theme limelight
```

Renders one of `docs/design/themes/*.tokens.json` into
`apps/troupe_plane/priv/static/theme.css` through the same walk as
`mix troupe.admin.tokens` (`Mix.Tasks.Troupe.Admin.Tokens.render/2`), with the source and
task named in the generated header. Without `--theme` it renders **signal**, which is the
theme the plane's front page wears; `footlight` and `limelight` are the other two kits
described in [`docs/design/themes/THEMES.md`](../design/themes/THEMES.md).

The rest of the brand under `apps/troupe_plane/priv/static/brand/` is not generated by
mix. `mark.svg` and `favicon.svg` are authored by hand from the mask geometry in the
token document; `favicon.ico` and `apple-touch-icon.png` are the two formats that cannot
be SVG, and `python scripts/brand-icons.py` rasterises them (Pillow, not part of the
build — run it when the mark changes and commit what it writes). `brand/mask.png` is a
resized, palette-reduced copy of the photograph at `docs/mask.png`.

`apps/troupe_plane/test/troupe/plane/front_page_assets_test.exs` checks that every file
the page names exists, is in the endpoint's `/static` allowlist and is actually answered
by the endpoint — and that the page spends the theme's reserved colour exactly once, on
the mask.

All three tasks accept `--check`, which regenerates into memory and fails if the committed
file differs (`troupe.admin.assets.ex:59-75`, `troupe.admin.tokens.ex:81-90`, `troupe.theme.ex:78-89`). Their
moduledocs say `--check` is "what CI runs" (`troupe.admin.assets.ex:28-29`,
`troupe.admin.tokens.ex:16-17`). Discrepancy: `.github/workflows/ci.yml` has no step
that runs any of them. Run them after a Phoenix dependency bump or a tokens change and
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
