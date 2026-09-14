# CI and CD

Three workflows, and the line between them is the point.

| workflow | when | what it proves or does |
|---|---|---|
| `ci.yml` | every push, every pull request | the code is right, and an image exists for the commit |
| `desktop.yml` | pushes to `main`, `v*` tags, and pull requests that touch the app | it can be installed on macOS, Windows and Linux |
| `deploy.yml` | only when a person starts it | one named build is rolled onto a cluster |

**CI builds; a person deploys** (`DECISIONS.md` #34). Pushing an image and changing
production are different decisions with different blast radii, and a workflow that did
both would make every merge a production change. `deploy.yml` does not weaken that — it
runs on `workflow_dispatch` alone, and it takes the tag as an input so nobody can deploy
without naming the build they mean.

---

## `ci` — typecheck, test, build; image; chart

### `check`

`pnpm install --frozen-lockfile`, then `tokens:check`, `typecheck`, `build`, `test`.

`tokens:check` is there because `apps/desktop/src/tokens.css` and `src/mark.ts` are
generated from `docs/design/themes/*.tokens.json` and committed. A theme changed without
running `pnpm tokens` would otherwise reach a deployment as a file nobody regenerated.

`build` runs before `test` and after `typecheck`: the bench resolves `@troupe/client`
through the package's `exports` rather than through a `paths` alias, so on a clean runner
its types do not exist until the client has been built. That was a real failure, fixed in
`5c3df60`.

### `image`

Runs on a push only — a pull request from a fork has no credential, and a pull request is
not a commit worth naming a tag after.

**Where it pushes, and how it gets in, are one decision.** The four secrets are named to
match the server's workflow so one set configures both repositories:

| secret | meaning | when unset |
|---|---|---|
| `REGISTRY` | registry host | `ghcr.io` |
| `REGISTRY_NAMESPACE` | namespace inside it | the repository owner |
| `REGISTRY_USERNAME` | who to log in as | `nologin` — what Scaleway, Harbor and most others want beside a secret key |
| `REGISTRY_PASSWORD` | the credential | see below |

There are two configurations and no third. **Nothing set** is a fork or a first run, and
the image goes to this repository's own packages on ghcr.io with GitHub's token.
**Everything set** is a deployment, and the image goes where it says. **A registry named
with no credential is refused**, with a message saying which secret to add — because the
fallbacks used to be per-secret, so a repository that set `REGISTRY` and stopped there
pointed at somebody else's registry and then offered it GitHub's own token, which cannot
work and fails at the login rather than at the configuration that caused it. Quietly
publishing somewhere else instead would be worse: a green run whose images the deployment
will never pull.

**Tags are never floating.** Every push is `sha-<first 7>`; a `v1.2.3` tag also publishes
`1.2.3`. A reused tag plus `imagePullPolicy: IfNotPresent` means the node keeps the image
it has, no pod restarts because the Deployment's spec did not change, and `helm upgrade`
reports success over code that never changed. This has happened on this cluster.

`TROUPE_GUI_BASE` is baked in at build time because Vite writes it into every asset URL,
so an image built for `/app/` cannot be served at `/`. The repository variable `GUI_BASE`
sets it; it defaults to `app` and must match the chart's `basePath`.

### `chart`

`helm lint`, then `helm template` piped into `kubeconform` against real Kubernetes
schemas — because a chart that only ever fails at `helm upgrade` fails in front of a
cluster rather than in front of a reviewer.

Still untested: the chart with `basePath: /`, which takes the other branch of the
ingress template.

---

## `desktop` — installers

One runner per platform; slow, so it is separate from `ci` and does not repeat the tests.

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

## `deploy` — the human half, in one place

`workflow_dispatch` only. Inputs: the tag to deploy (required), the environment, the
namespace and release, and a dry run.

It runs `scripts/deploy` — the same script a person runs on a laptop — rather than
reimplementing it. Two implementations of "deploy" is how the documented one stops being
what actually happens.

| secret | what it is |
|---|---|
| `KUBECONFIG` | the cluster's kubeconfig, written to `.local/kubeconfig.yaml` where the script looks |
| `DEPLOY_VALUES` | the Helm values file for the deployment, the one kept out of the repository under `.local/` |

Without both, the run stops at its first step and says which is missing rather than
half-deploying. The credentials are removed at the end of the job whatever happened.

**Approval lives on the environment**, not in this file: configure required reviewers on
the `production` environment and a deploy waits for a second person. Concurrency is one
roll at a time per environment — two overlapping `helm upgrade`s on one release is a race
whose winner nobody chose.

The digest of what is actually running is printed into the run summary, for the same
reason `scripts/deploy` prints it: the tag is not evidence.

---

## Dependencies

`.github/dependabot.yml` covers the three ecosystems this repository has — GitHub
Actions weekly, npm and cargo monthly, grouped so a patch bump is not a pull request of
its own.

The actions ecosystem is the one that actually bit: with no configuration at all, only
GitHub's default security updates ran, every action sat on a major pinned to a Node
runtime GitHub is removing, and nothing was watching. `glib` is ignored with a reason —
it arrives through gtk3 and webkit2gtk, which is the stack Tauri 2 uses on Linux, and no
version answers both the advisory and Tauri's pin, so Dependabot errored on it weekly.

---

## What is still missing

- **No browser tests.** `spec.md` asks for Playwright in CI; there is none.
- **No required checks or branch protection.** Nothing yet stops a merge over a red `ci`.
- **The chart is not rendered with `basePath: /`.**

## Related

- [build.md](build.md) — what the `image` job builds.
- [deployment.md](deployment.md) — the cluster it goes to.
- [testing.md](testing.md) — what `pnpm test` covers.
