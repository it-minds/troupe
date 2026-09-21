# CI and CD

The GUI has no workflows of its own. Since it moved into the Troupe repository (root
Decision 666; Decision 45 here) it is built, tested, released and deployed by the root
workflows, beside everything else the repository ships.

| workflow | the GUI's part | when |
|---|---|---|
| [`ci.yml`](../../../../.github/workflows/ci.yml) | `gui` (tokens, typecheck, build, test), `gui-e2e` (the client against a plane built from the same commit), the `troupe-gui` image, and the release that promotes and deploys it | a pull request that touches it; every push to `main` |
| [`release.yml`](../../../../.github/workflows/release.yml) | `desktop`: the installers for macOS, Windows and Linux | a pull request that touches the app or the client, nightly, and every release |
| [`deploy.yml`](../../../../.github/workflows/deploy.yml) | nothing of its own: it rolls back, or renders, a whole release | only when a person starts it |

**A release deploys itself** (root Decision 669). That replaces "CI builds; a person
deploys" (`DECISIONS.md` #34), but not the reason for it: pushing an image and changing
production are still two decisions. A push to `main` publishes images and deploys
nothing; production changes when a merged change to `VERSION` cuts a release, which is a
reviewed merge rather than a laptop session.

---

## `ci` — the GUI's jobs

One workflow for the whole repository, and one required check, `ci-ok`. A job called
`changes` decides what a pull request runs: `gui` for any change under `clients/gui/`,
`gui-e2e` for a change to the client package, to `dev/`, or to the plane's side of the
protocol, and both for a change to `PROTOCOL.md`, `VERSION`, the toolchain or the
workflow itself. A job skipped because its part of the repository did not change counts as
passing. A push to `main` runs everything.

### `gui`

In `clients/gui`: `pnpm install --frozen-lockfile`, then `tokens:check`, `typecheck`,
`build`, `test`. pnpm is the version `packageManager` names; Node is the one in the root
`.tool-versions`.

`tokens:check` is there because `apps/desktop/src/tokens.css` and `src/mark.ts` are
generated from `docs/design/themes/*.tokens.json` and committed. A theme changed without
running `pnpm tokens` would otherwise reach a deployment as a file nobody regenerated.

`build` runs before `test` and after `typecheck`: the bench resolves `@troupe/client`
through the package's `exports` rather than through a `paths` alias, so on a clean runner
its types do not exist until the client has been built. That was a real failure, fixed in
`33f66f1`.

### `gui-e2e`

`dev/plane-stack.yml` brought up with `--build`: Postgres, OpenBao, Dex and a plane built
from `docker/Dockerfile` at the root of the same commit. Then `test/e2e.plane.test.ts`
runs against it. A protocol change and the client change that answers it are tested
together, in one pull request; see [../e2e.md](../e2e.md).

### `chart`

The GUI's templates are linted and rendered with the rest of `charts/troupe`: `helm lint`
with each values file and once with `gui.enabled: false` and a `plane.appUrl`, a check that
`gui.basePath: /` is still refused, and `kubeconform` on the rendered manifests with the
GUI and without it.

### The image

The `images` job builds `troupe-gui` beside the four server images, from `clients/gui` as
the whole Docker context — which is also the proof that nothing here reaches into the rest
of the repository — for `linux/amd64`, on every push to `main`. A pull request builds no
image: one from a fork has no credential, and a pull request is not a commit worth naming a
tag after.

**Where it pushes is one decision for every image.** Four secrets, the same ones the
server images use:

| secret | meaning |
|---|---|
| `REGISTRY` | registry host |
| `REGISTRY_NAMESPACE` | namespace inside it; the repository owner when unset |
| `REGISTRY_USERNAME` | who to log in as |
| `REGISTRY_PASSWORD` | the credential |

All four, or none. With the registry or its credential missing the job publishes nothing
and its summary says which secrets to add, rather than guessing: a fallback to ghcr.io
with GitHub's token once paired a password set on its own with a registry it was not for,
and failed at the login rather than at the configuration that caused it.

**Tags are never floating.** Every push is `sha-<first 7>`, and a version tag is not built
at all: a release promotes the `sha-` image it has just tested to the version, so
production runs the bytes CI tested. A reused tag plus `imagePullPolicy: IfNotPresent`
means the node keeps the image it has, no pod restarts because the Deployment's spec did
not change, and `helm upgrade` reports success over code that never changed. This has
happened on this cluster.

`TROUPE_GUI_BASE` is baked in at build time because Vite writes it into every asset URL,
so an image built for `/app/` cannot be served at `/`. The repository variable `GUI_BASE`
sets it; it defaults to `app` and must match the chart's `gui.basePath`.

### `versions`

The GUI's three `package.json` files, `tauri.conf.json`, `Cargo.toml` and `Cargo.lock`
repeat the root `VERSION`, because none of them can read it. `scripts/version.exs check`
fails when any copy disagrees; `scripts/version.exs set` is how a release changes them all
at once.

---

## `desktop` — installers

A job of the root `release.yml`, which also builds the daemon and the TUI. It runs when a
pull request touches `clients/gui/apps/desktop` or `clients/gui/packages/client` (as
`ci.yml`'s `native` job), nightly on `main`, and when a release is cut, when its installers
are attached to the release. One runner per platform; slow, so it is separate from the
tests and does not repeat them.

Ubuntu **22.04** is deliberate: it is the glibc floor, the oldest Ubuntu carrying
`libwebkit2gtk-4.1-dev`. Building on 24.04 raises the required glibc and silently breaks
every 22.04 user.

Unsigned until the signing secrets exist. Every signing step is written out and gated on
one — `APPLE_CERTIFICATE` for macOS, `AZURE_ENDPOINT` for Windows — and there are two
build steps rather than one with a conditional environment block, because an undefined
secret is not an absent variable: GitHub substitutes an empty string, `tauri-action` reads
the name's presence as "set up a signing keychain", and then fails importing nothing. See
[install.md](../install.md) for what each secret is and what it costs.

---

## Releasing and deploying

A release is a merged change to `VERSION`. `scripts/release <version>` at the root opens
the pull request; merging it makes the run on `main` tag `v<version>`, promote
`troupe-gui` and the server images to that version, package the chart, attach the native
builds — the desktop installers among them — and publish the release with one
`SHA256SUMS`. Its `deploy` job then rolls the release onto the `production` environment
with the root [`scripts/deploy`](../../../../scripts/deploy): the whole chart, the GUI
included, and a check that the plane reports the new version and commit. A release
candidate (`-rc.N`) does all of it and deploys as a server-side dry run. See
[deployment.md](deployment.md).

`deploy.yml` is for what the automatic path does not do: roll an earlier release back, or
render one against the cluster, by hand, through the same script. It takes a release's
version; there is no deploying the GUI on its own.

| the `production` environment holds | what it is |
|---|---|
| `KUBECONFIG` (secret) | a kubeconfig **with a token in it**, for the `troupe-deployer` service account |
| `DEPLOY_VALUES` (secret) | the deployment's Helm values file, kept out of the repository |
| `PLANE_URL` (variable) | the plane's public URL, where `scripts/deploy` checks the version it rolled |

**Not a person's kubeconfig.** The one Scaleway issues has an *exec plugin* for its user:
it shells out to `scw` on the machine using it to mint a token. On a runner that is
`executable scw not found`, and the token it would have minted is that person's.

`deploy/ci-deployer.yaml` at the root is the identity CI deploys as instead, and
`scripts/ci-kubeconfig` reads its token and prints the kubeconfig to upload. It is not the
one-namespace Role the GUI's own deployer had: the platform's chart creates CRDs,
ClusterRoles and an admission policy, so the account reaches across the cluster, and the
manifest says so rather than hiding it. The token Secret is declared rather than left to
`kubectl create token`, because that one expires — right for a person, wrong for a runner
that has to still work in three months without anybody remembering why it stopped.

The environment should allow `main` alone, so no pull request can reach the credentials; a
required reviewer on it is the team's call, since the version bump's review is the
approval the design assumes. Concurrency is one roll at a time, shared between the
`deploy` job and `deploy.yml` — two overlapping `helm upgrade`s on one release is a race
whose winner nobody chose. The digest of every pod that is actually running is printed at
the end, because the tag is not evidence.

---

## Dependencies

The root `.github/dependabot.yml` covers the GUI's npm packages and the desktop app's
crates, monthly and grouped so a patch bump is not a pull request of its own, beside the
workflows' actions (weekly) and the two Mix projects.

The actions ecosystem is the one that actually bit: with no configuration at all, only
GitHub's default security updates ran, every action sat on a major pinned to a Node
runtime GitHub is removing, and nothing was watching. `glib` is ignored with a reason —
it arrives through gtk3 and webkit2gtk, which is the stack Tauri 2 uses on Linux, and no
version answers both the advisory and Tauri's pin, so Dependabot errored on it weekly.

---

## What is still missing

- **No browser tests.** `spec.md` asks for Playwright in CI; there is none.

## Related

- [build.md](build.md) — what the image job builds.
- [deployment.md](deployment.md) — the chart it goes out in, and the cluster it goes to.
- [testing.md](testing.md) — what `pnpm test` covers.
- [../e2e.md](../e2e.md) — the suites against a real plane and a real worker.
