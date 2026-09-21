> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).
> Since revised for the move into the Troupe repository: the GUI's own chart and `scripts/deploy` are gone, and it deploys as the `gui:` block of the root `charts/troupe` (root Decisions 669 and 670).

# Deployment

How a built bundle reaches people: the platform's chart, the release that deploys it, the
base-path contract, and what is recorded about the one live deployment. Operator-facing
detail (every value, every runtime behaviour) is in
[../admin/configuration.md](../admin/configuration.md) and
[../admin/operations.md](../admin/operations.md).

## The shape

One image, one Deployment, one Service, one Ingress and one NetworkPolicy, all in the
platform's chart as its `gui:` block. The container takes no environment variables and
holds no secret (the Deployment has no `env:` block). Everything a user's browser then
does goes from the browser to the plane and to a worker pod — the GUI's pods are never in
that path (`Dockerfile:3-6`).

## The chart

The GUI had a chart of its own, `charts/troupe-gui`, installed as a second Helm release
onto the plane's host. It went with the move into the monorepo, never having been
released: its templates moved into the root [`charts/troupe`](../../../../charts/troupe),
not rethought, and the GUI is on by default there, because the product is the platform
and a client to use it with (root Decision 670). The chart's version and `appVersion` are
the release's (the root `VERSION`), so the GUI's image tag defaults to the same number as
the plane's.

| Template | Renders | Notes |
|---|---|---|
| `templates/gui-deployment.yaml` | Only when `gui.enabled` and `plane.enabled`; the render fails if `gui.basePath` is `/`, which is the plane's. A `Service` `troupe-gui`, `ClusterIP`, port 80 → `http`. A `Deployment` `troupe-gui` with `gui.replicas`, pod security context uid/gid 101, `RuntimeDefault` seccomp, image `gui.image.repository:tag` with the tag defaulting to `appVersion`, port 8080 named `http`, read-only root filesystem, no privilege escalation, all capabilities dropped, readiness and liveness on `/healthz`, `emptyDir`s for `/var/cache/nginx` and `/tmp`. An `Ingress` `troupe-gui` on `plane.host`, class `plane.ingressClassName`, TLS from `plane.tlsSecretName`, with `rewrite-target: /$2` and path `<base>(/\|$)(.*)` `ImplementationSpecific` | The rewrite is nginx-ingress specific. No cert-manager annotation: the plane's Ingress asks for the host's certificate, and the two share it |
| `templates/network-policy.yaml` | A `NetworkPolicy` `troupe-gui` admitting the ingress namespace on 8080 and nothing else | With the Deployment, and only then |
| `templates/plane-deployment.yaml` | The plane's `TROUPE_APP_URL`: `plane.appUrl` if set, else the GUI's base path when `gui.enabled`, else empty | Where the plane's index page sends a person for the GUI — never to a 404 |

Values and their effects are tabulated in
[../admin/configuration.md](../admin/configuration.md).

## The base-path contract

Three things must agree (`DECISIONS.md` #29-31):

1. **The image** was built with `TROUPE_GUI_BASE` = some path, which Vite normalised
   and wrote into every asset URL (`apps/desktop/vite.config.ts:16-17`). CI builds with
   `vars.GUI_BASE || 'app'` (the root `ci.yml`'s `images` job) and `scripts/build-images`
   with `/app`; the Dockerfile default is `/` (`Dockerfile:38`).
2. **`gui.basePath` in the values** equals it. The default is `/app`, and `/` is refused.
3. **The Ingress** rewrites `<basePath>/x` to `/x` before nginx sees it
   (`templates/gui-deployment.yaml`), so the container serves from its root regardless
   of the mount point.

If 1 and 2 disagree, `index.html` loads and every asset 404s — a blank page
(`DECISIONS.md` #30). If the ingress class is not nginx-ingress, the rewrite annotation
is ignored and the same blank page results. Changing the base path is a rebuild, not a
`helm upgrade`.

The bundle uses the same value at runtime for two things: the OIDC redirect URI (origin
+ base path, no trailing slash — `apps/desktop/src/shell.ts:91-95`) and the plane-URL
prefill (the origin, when the base path is not `/` — `shell.ts:105-109`). A GUI at
`/app` on the plane's host is same-origin with the plane, so the CORS allowlist stops
mattering for it (`DECISIONS.md` #29).

## Deploying: a release does it

There is no deploying the GUI on its own. A release deploys the whole chart (root
Decision 669):

1. `scripts/release <version>` at the root opens a pull request whose only change is
   `VERSION` and its copies — the GUI's `package.json` files, `tauri.conf.json` and
   `Cargo.toml` among them (`scripts/version.exs set`).
2. Merging it is the release. The run on `main` that follows has built and tested
   `troupe-gui` as `sha-<short>`; its `release` job tags the commit, promotes that image
   and the four server images to the version, packages the chart, and opens the release
   that the native builds, the desktop installers among them, are attached to.
3. Its `deploy` job runs the root `scripts/deploy` with that packaged chart against the
   `production` environment. A release candidate (`-rc.N`) is rendered against the
   cluster as a dry run and changes nothing.

## The root `scripts/deploy`

`scripts/deploy <chart> [--dry-run]`, where `<chart>` is a packaged chart as a release
publishes it (`troupe-0.3.0.tgz`) or the chart directory. It is the one implementation of
deploying: the `deploy` job, the `deploy` workflow and a person with the same credentials
all run it.

| Step | What happens |
|---|---|
| Resolve inputs | The variables below; the chart's `appVersion` is the version every image is deployed at |
| `--dry-run` | Apply the CRDs and the chart server-side as a dry run, so the API server checks them; change nothing |
| CRDs | `kubectl apply --server-side` of the chart's CRDs, because Helm installs a CRD once and never upgrades it |
| Deploy | `helm upgrade --install --wait --timeout 10m`, rolling back on failure |
| Roll out | `kubectl rollout status` for every Deployment of the release, the GUI's included |
| Check the version | With `PLANE_URL` set, `/.well-known/troupe` must report the chart's `appVersion`, and `EXPECT_COMMIT` when that is set too |
| Print what is running | Every pod's `imageID` — the **digest**, because a reused tag with `IfNotPresent` restarts nothing and `helm upgrade` still reports success (`REPORT.md:204-211`; `DECISIONS.md` #34) |

Inputs:

| Variable | Default |
|---|---|
| `KUBECONFIG_FILE` | `<root>/.local/kubeconfig.yaml` |
| `VALUES` | `<root>/.local/values.itminds.yaml` |
| `NAMESPACE` | `troupe-system` |
| `RELEASE` | `troupe` — the platform's release, which the GUI is part of |
| `PLANE_URL` | unset — no version check |
| `EXPECT_COMMIT` | unset |

`<root>` is the repository root, not `clients/gui`. There is no `TAG`: the GUI's image is
the release's version unless the values file sets `gui.image.tag`. In CI the `production`
environment supplies the kubeconfig and values as the secrets `KUBECONFIG` and
`DEPLOY_VALUES`, and `PLANE_URL` as a variable; see [ci-cd.md](ci-cd.md).

Render against a cluster, changing nothing:

```bash
scripts/deploy charts/troupe --dry-run
```

The script needs `helm`, `kubectl`, `curl` and `jq` on the path. On Windows it runs under
Git Bash.

## The recorded live deployment

`REPORT.md:236-251` records a deployment made on 2026-09-13. **Recorded, not verified
for this audit**: nothing was run against the cluster (AUDIT §5).

| Fact | Recorded value | Source |
|---|---|---|
| URL | `https://troupe.itmindsinternal.dk/app` | `REPORT.md:242` |
| Image | `rg.fr-par.scw.cloud/troupe/troupe-gui:0.1.1`, digest `sha256:ae03b5a9…` | `REPORT.md:247` |
| Release | `troupe-gui`, revision 3, namespace `troupe-system` | `REPORT.md:248` |
| Pods | 2, both ready, both on that digest | `REPORT.md:249` |
| Ingress | host `troupe.itmindsinternal.dk`, path `/app(/\|$)(.*)`, class nginx | `REPORT.md:250` |
| Certificate | `troupe-plane-tls`, shared with the plane's Ingress | `REPORT.md:251` |
| Values | `.local/values.itminds.yaml`, gitignored | AUDIT §1.5 |
| Checked from a browser | page renders; hashed assets `immutable`, `index.html` `no-cache`; deep link falls back; `/.well-known/troupe` same-origin; `/rpc` still reaches the plane; plane URL prefilled | `REPORT.md:253-262` |
| Not yet done | sign-in — the redirect URI `https://troupe.itmindsinternal.dk/app` had to be registered on the Entra application as an SPA redirect | `REPORT.md:264-267` |

Unconfirmed: how `0.1.1` was built and pushed. It is not a tag CI would produce
(`sha-<7>` or a `v*` version), the chart's `appVersion` is `0.1.0`, and no `v*` tag
exists in the history (AUDIT §3.5). The image repository is a Scaleway registry, not the
chart's default `ghcr.io/objective-mj/troupe-gui` (`values.yaml:6`), so the values file
overrides `image.repository`.

That deployment is the old chart's release, `troupe-gui`. Its Deployment, Service and
Ingress have the names `charts/troupe` gives the GUI's — `troupe-gui`, in the same
namespace — and Helm will not adopt objects another release owns, so a cluster still
carrying it needs `helm uninstall troupe-gui -n troupe-system` before the first deploy of
a chart with `gui.enabled`. `/app` answers nothing from the uninstall until that deploy
has rolled out.

## Rollback

A rollback is a release, not a GUI. The `deploy` workflow (the root
`.github/workflows/deploy.yml`, started by hand with a version) rolls that release's
published chart onto production through the same `scripts/deploy`, or renders it with
`dry_run`; the GUI goes back with the rest of the platform, because its version is the
release's. By hand, with the same credentials:

```bash
helm --kubeconfig .local/kubeconfig.yaml -n troupe-system history troupe
```

```bash
helm --kubeconfig .local/kubeconfig.yaml -n troupe-system rollback troupe <revision>
```

Because nothing in the GUI is stateful (no volume but two `emptyDir`s), a rollback is only
a change of its image. `scripts/deploy` prints the digests at the end; `helm rollback`
does not, so follow it with:

```bash
kubectl --kubeconfig .local/kubeconfig.yaml -n troupe-system get pods -l app.kubernetes.io/instance=troupe,app.kubernetes.io/component=gui -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,IMAGE:.status.containerStatuses[0].imageID'
```

## Staging

There is no staging environment: one `production` environment, and a release candidate
(`-rc.N`) that renders against its API server without changing it. The local stand-in for
the chart is the kind cluster: `scripts/remote-up` at the root builds the GUI's image with
`scripts/build-images` and serves it at `http://plane.localtest.me:30080/app`, which
exercises the image, the chart and an nginx ingress (root Decision 670). `pnpm fake` plus
`pnpm dev` (`README.md:53-58`; [local-setup.md](local-setup.md)) exercises the client
against the fakes, and `dev/plane-stack.yml` against a real plane ([../e2e.md](../e2e.md)),
but neither the image nor the chart.

## Related

- [../admin/operations.md](../admin/operations.md) — the same procedures from the
  operator's side, with troubleshooting.
- [../admin/identity-provider.md](../admin/identity-provider.md) — the registration a
  new deployment needs.
- [ci-cd.md](ci-cd.md) — where the image comes from, and the release that deploys it.
