# Build

What comes out of this repository: five server images and a Helm chart for a cluster;
`troupe-daemon`, `troupe` and the desktop app for a machine; and a few generated files
that are committed.

## 1. The server images

`docker/Dockerfile` builds all four umbrella releases; `RELEASE` picks which (default
`troupe_operator`). Two stages:

- **build**, on `hexpm/elixir` (Elixir, OTP and Debian versions as build arguments):
  dependencies are fetched from the `mix.exs` files first so the layer caches, then
  `config/` and `apps/` are copied and `mix release ${RELEASE}` runs. For
  `RELEASE=troupe_worker` it installs a pinned Zig so `mix compile.reaper` can build the
  two Linux `reaper`s, and then **fails the build** if the release has no
  `*-linux-musl/reaper` — without it the image starts and answers every `shell` call with
  `:reaper_missing`, a failure that only ever shows in a pod.
- **runtime**, on Debian slim: uid/gid 1000 (what the operator's pod spec asks for), the
  release, and `ENTRYPOINT exec /app/bin/${RELEASE_NAME} start` so a SIGTERM becomes a
  graceful stop. `git` and `bubblewrap` are installed for the worker image only: a sandbox
  helper and a network client are the last things to want in the internet-facing plane or
  the operator that holds cluster privileges. Ports and probes are the chart's business.

`.dockerignore` keeps out `clients/`, `docs/`, tests, `_build`, `deps` and a laptop's
`priv/reaper` (the wrong architecture with the right name). The fifth image, `troupe-gui`,
is built from `clients/gui` as its own context.

```bash
scripts/build-images                          # all five, tagged dev, loaded into kind if troupe-dev exists
scripts/build-images troupe_worker            # a subset
TROUPE_REGISTRY=rg.fr-par.scw.cloud/troupe TROUPE_IMAGE_TAG=0.3.3 TROUPE_PUSH=true scripts/build-images
```

Images are `linux/amd64` explicitly, so a non-amd64 laptop does not build one the node
pool cannot run. A rebuilt image under an unchanged tag changes nothing in a pod spec:
`scripts/remote-up` follows the build with `kubectl rollout restart`.

## 2. The machines' builds

All on native runners in `.github/workflows/native.yml` ([CI](../../.github/CI.md)):

- **`troupe-daemon`**: `MIX_ENV=prod mix release troupe_daemon` in `apps/troupe_daemon`,
  a tarball per target, with the host's `reaper` inside.
- **`troupe`**, the TUI: a Burrito binary per target from `clients/tui`
  (`clients/tui/scripts/build-local` for this host). Linux targets link musl.
- **The desktop app**: Tauri, from `clients/gui/apps/desktop`: `.dmg`, `.exe`/`.msi`,
  `.deb`/`.rpm`/`.AppImage`, unsigned until the signing secrets exist
  ([install.md](../../clients/gui/docs/install.md)).

`install.sh` and `install.ps1` at the root install `troupe` and `troupe-daemon` from a
release and check them against its `SHA256SUMS`. On this Windows machine,
`scripts/setup-windows-toolchain.ps1` and `scripts/install-local.ps1` build and install
from a checkout.

### The reaper

`mix compile.reaper` is a compiler appended to `troupe_core`'s: it runs `zig build-exe
native/reaper/reaper.zig` (under `apps/troupe_core`) into
`apps/troupe_core/priv/reaper/<triple>/`, for the host triple by default, every triple
with `TROUPE_REAPER_TARGETS=all`, or a comma-separated list. Without Zig it warns and
skips, and `shell` does not run. A release sets the two Linux triples.

## 3. Generated, committed files

| Generated | Written by | Checked in CI by |
|---|---|---|
| `protocol/schema/v1/**` | `mix troupe.schema.gen` from `Troupe.Protocol.Schema` | `mix troupe.schema.diff` (add-only), then regenerate and `git diff --exit-code` |
| `apps/troupe_plane/priv/static/app.js` | `mix troupe.admin.assets`, from the Phoenix, Phoenix HTML and LiveView bundles in `deps/` | `--check` in the `lint` job |
| `apps/troupe_plane/priv/static/tokens.css`, `priv/design/statuses.json` | `mix troupe.admin.tokens`, from `docs/design/admin/tokens.json` | `--check` |
| `apps/troupe_plane/priv/static/theme.css` | `mix troupe.theme` (Signal by default), from `docs/design/themes/*.tokens.json` | `--check` |
| `apps/troupe_plane/priv/static/brand/{favicon.ico,apple-touch-icon.png}` | `python scripts/brand-icons.py` (Pillow), when the mark changes | a test that they exist |
| `docs/egress-allowlist.md` | `mix troupe.egress`, from what each component declares it dials | a test that it is current |
| `docs/third-party-licences.md` | `elixir scripts/licences.exs`, from the two Mix locks, the pnpm workspace and `Cargo.lock`, once their packages are fetched | `--check` in `licences.yml`, which also refuses a licence outside the script's policy |
| `clients/gui/apps/desktop/src/{tokens.css,mark.ts}` | `pnpm tokens`, from `clients/gui/docs/design/themes/*.tokens.json` | `pnpm tokens:check` |
| `test/fixtures/logs/<version>/` | `mix troupe.fixtures.record <version>`, once per release; refuses to overwrite | `fold_test.exs` replays every version |

There is no npm or esbuild in the umbrella: the console's JavaScript is the UMD bundles
shipped inside the Phoenix packages, concatenated.

## 4. Version

`VERSION` is the version of everything this repository releases (Decision 668): the
umbrella's apps and the daemon read it, and so does the TUI. The chart, the GUI's
packages and the desktop app cannot, and carry a copy that `elixir scripts/version.exs
check` compares (CI's `versions` job) and `elixir scripts/version.exs set <version>`
writes. The desktop app gets the version without its pre-release part, because WiX
refuses a non-numeric one. A release is a merged change to `VERSION`
([deployment.md](deployment.md)).
