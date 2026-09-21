> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).
> Since revised for the move into the Troupe repository: the GUI is deployed, upgraded and rolled back with the platform's `charts/troupe` release, by the root `scripts/deploy` (root Decisions 669 and 670).

# Operations

Running the GUI on a cluster: deploy, upgrade, roll back, watch, and fix. The GUI is a
static bundle behind nginx with no state, no secrets and no environment variables
(`Dockerfile:1-6`), so most of this is short.

## Deploy and upgrade

The GUI has no deploy of its own. It is part of the platform's Helm release, `troupe`,
from the root `charts/troupe`, and a release deploys itself (root Decision 669):
`scripts/release <version>` at the root opens a pull request that changes `VERSION`, and
merging it makes the run on `main` promote every image — `troupe-gui` among them — to
that version, package the chart, and roll it onto the `production` environment with the
root [`scripts/deploy`](../../../../scripts/deploy). See the root README's
[Releasing and deploying](../../../../README.md#releasing-and-deploying).

`scripts/deploy <chart> [--dry-run]` takes a packaged chart or the chart directory and
reads six variables, all optional:

| Variable | Default | Meaning |
|---|---|---|
| `KUBECONFIG_FILE` | `.local/kubeconfig.yaml` | Cluster credentials |
| `VALUES` | `.local/values.itminds.yaml` | The values file for this deployment |
| `NAMESPACE` | `troupe-system` | Namespace |
| `RELEASE` | `troupe` | Helm release name — the platform's, which the GUI is part of |
| `PLANE_URL` | unset | When set, `/.well-known/troupe` must report the chart's version afterwards |
| `EXPECT_COMMIT` | unset | With `PLANE_URL`, the commit the plane must report as well |

The paths are relative to the repository root. There is no tag for the GUI alone: its
image is the chart's `appVersion`, the release's version, unless the values file sets
`gui.image.tag`.

Render against the cluster without changing anything:

```bash
scripts/deploy charts/troupe --dry-run
```

The script applies the chart's CRDs, runs `helm upgrade --install --wait` with rollback
on failure, waits for every Deployment's rollout, checks the plane's version when
`PLANE_URL` is set, and then prints every pod's `imageID` — the running **digest**. Read
the GUI's: a tag that already existed in the registry plus `imagePullPolicy:
IfNotPresent` means no image is pulled and, because the Deployment spec did not change, no
pod restarts; `helm upgrade` reports success over old code (`REPORT.md:204-211`). Never
reuse a tag.

Without the script, the equivalent Helm command is the root README's
[Deploy](../../../../README.md#deploy); the GUI comes with it unless the values say
`gui.enabled: false`.

**A cluster that still runs the old chart's `troupe-gui` release** — the recorded
deployment below is one — has to remove it first: `helm uninstall troupe-gui -n
troupe-system`. Its Deployment, Service and Ingress have the names `charts/troupe` gives
the GUI's, in the same namespace, and Helm will not adopt objects another release owns,
so the first deploy with `gui.enabled` fails until they are gone. `/app` answers nothing
from the uninstall until that deploy has rolled out.

## Rollback

A rollback is a release: the `deploy` workflow (the root `.github/workflows/deploy.yml`,
started by hand with a version) rolls that release's chart onto production through the
same `scripts/deploy`, or renders it without changing anything. The GUI goes back with the
rest of the platform. With the credentials in hand, Helm works too:

```bash
helm --kubeconfig .local/kubeconfig.yaml -n troupe-system history troupe
```

```bash
helm --kubeconfig .local/kubeconfig.yaml -n troupe-system rollback troupe <revision>
```

Either way, confirm with the digest:

```bash
kubectl --kubeconfig .local/kubeconfig.yaml -n troupe-system get pods -l app.kubernetes.io/instance=troupe,app.kubernetes.io/component=gui -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,IMAGE:.status.containerStatuses[0].imageID'
```

For the GUI a rollback changes only the image; nothing persists in its pods (two
`emptyDir`s). Users' browsers pick up the older bundle on their next load because
`index.html` is served `no-cache` (`docker/nginx.conf:48`).

## Health checks

| Check | Path | Configured at |
|---|---|---|
| Readiness | `GET /healthz` on port 8080, after 2 s, every 10 s | `templates/gui-deployment.yaml` |
| Liveness | same, after 10 s, every 30 s | `templates/gui-deployment.yaml` |
| Image `HEALTHCHECK` | `wget -q -O /dev/null http://127.0.0.1:8080/healthz`, every 30 s | `Dockerfile:58-59` |
| What `/healthz` proves | nginx is up and serving its config; it returns `200 ok` without touching the bundle (`nginx.conf:33-37`). It does not prove the bundle is correct for the base path | |

Through the ingress, `https://<host><basePath>/healthz` is rewritten to `/healthz` and
answers `ok`. A better smoke test is the page itself: fetch `https://<host><basePath>/`
and confirm the referenced `/assets/…` files answer 200 with `Cache-Control: public,
immutable` (`REPORT.md:255-256` did this for the recorded deployment).

## What to monitor

- **nginx access and error logs** on the pods' stdout/stderr (the base image's default;
  `/healthz` is excluded, `nginx.conf:34`). A burst of 404s under `/assets/` after a
  deploy means a base-path mismatch or a stale `index.html`.
- **`/healthz`** through the probes.
- **Pod restarts and readiness** via `kubectl get pods`.
- **There are no metrics**, no tracing and no client-side error reporting. The GUI
  emits nothing about session content by design (`spec.md:57`). Anything about
  sign-in or protocol failures is visible only in the user's browser.

## Backup

Nothing to back up. The pods hold no state; the chart mounts no persistent volume; the
image holds no secret or configuration beyond `nginx.conf` (`Dockerfile:52-53`). The
only per-user state is in each person's browser (`localStorage` keys listed in
[configuration.md](configuration.md)) and is theirs to lose: clearing it means signing
in again and retyping a plane URL. Session content lives on the plane and the workers,
which are the platform's concern ([../../../../docs/admin/backup-restore.md](../../../../docs/admin/backup-restore.md)).

## Routine tasks

| Task | How |
|---|---|
| Deploy a new image | Cut a release (`scripts/release <version>` at the root); merging it deploys the GUI with the rest of the platform. Check the digest |
| Change the base path | **Rebuild the image** with the new `TROUPE_GUI_BASE` (in CI, the repository variable `GUI_BASE`), set `gui.basePath` in the values to match, register the new redirect URI at the identity provider ([identity-provider.md](identity-provider.md)), deploy. A values-only change produces a blank page |
| Serve a GUI from its own host | Not from this chart, which mounts the GUI on the plane's host only. Serve your own build (with `/`) elsewhere, set `gui.enabled: false` and `plane.appUrl` to its address, add its origin to the plane's `TROUPE_CORS_ORIGINS` and the worker's `TROUPE_WORKER_ALLOWED_ORIGINS`, and register the new redirect URI |
| Add an origin on the plane | On the server: `plane.corsOrigins` / `TROUPE_CORS_ORIGINS` and `operator.workerAllowedOrigins` / `TROUPE_WORKER_ALLOWED_ORIGINS` (`REPORT.md:142-150`); a plane restart. Nothing on the GUI side |
| Rotate secrets | Nothing to rotate. The GUI holds none; its certificate is the plane's (`plane.tlsSecretName`) |
| Scale | `gui.replicas` in the values; the pods are independent |
| Change the theme, plane URL or any user-facing default | Not configurable at deployment; the theme is per browser, the plane URL is prefilled from the origin ([configuration.md](configuration.md)) |

## Troubleshooting

| Symptom | Likely cause | Check | Fix |
|---|---|---|---|
| Sign-in screen shows "could not reach the plane at … Add `<origin>` to TROUPE_CORS_ORIGINS" | The GUI's origin is not in the plane's CORS allowlist, or the plane is down (a browser cannot tell the page which; `packages/client/src/auth.ts:83-90`) | `curl -I https://<plane>/.well-known/troupe`; from a browser console on the GUI's origin, `fetch('<plane>/.well-known/troupe')` | Add the origin to `TROUPE_CORS_ORIGINS`, restart the plane. Not needed when the GUI is on the plane's own host |
| Provider page says the redirect URI is not registered (`AADSTS50011`), or the GUI shows "The identity provider does not know this address. Register `<uri>` …" | Redirect URI missing or registered as Web rather than SPA; or a trailing-slash mismatch | Compare the URI in the GUI's message with the provider's list exactly | Register `<origin><basePath>` as an SPA redirect URI (`SignIn.tsx:172-175`) |
| Provider refuses with `AADSTS650053` (scope does not exist) | The plane publishes `groups` as a scope | `curl https://<plane>/.well-known/troupe` and read `scopes` | Set `TROUPE_OIDC_SCOPES` / `plane.oidc.scopes` on the plane (`DECISIONS.md` #27) |
| Blank page; browser console shows 404s for `/app/assets/…` or `/assets/…` | Image built for one base path, served at another | Compare the asset URLs in the served `index.html` with `basePath` and the ingress path | Rebuild with the matching `TROUPE_GUI_BASE`, or fix `basePath` to match the image |
| Page loads at `/app` but a refresh on `/app/anything` gives 404 from the ingress | Ingress path or class wrong: the rewrite annotation only works on nginx-ingress; the path must be `<base>(/\|$)(.*)` | `kubectl get ingress troupe-gui -o yaml` and compare with `templates/gui-deployment.yaml` | Use `plane.ingressClassName: nginx`, or provide equivalent rewriting for another class |
| Page loads, but every session shows "Connection lost" then "Could not reach this session" | The worker's WebSocket upgrade refuses the browser's origin — the only hop with no fallback (`REPORT.md:188-191`) | Browser console: the `wss://…/v1/socket` upgrade fails | Add the GUI's origin to `TROUPE_WORKER_ALLOWED_ORIGINS` on the workers |
| `helm upgrade` succeeded but the old code is still served | Tag reused; `IfNotPresent` kept the cached image and no pod restarted | The digest printout from the root `scripts/deploy`, or the `kubectl` line above, against the registry's digest for the tag | Push under a new tag and deploy it; never reuse a tag (`REPORT.md:204-211`) |
| Old bundle after a deploy in one browser only | Cached `index.html` from a proxy in front of the ingress | Response headers for `index.html` should be `Cache-Control: no-cache` (`nginx.conf:48`) | Fix the intermediate cache; the image is correct |
| Users are signed out after clearing site data, or on a new browser | Expected: the refresh token lives in `localStorage` per browser | — | Sign in again |
| `helm template`/`upgrade` fails with "gui.basePath is the root of the plane's host" | `gui.basePath` is `/` | `templates/gui-deployment.yaml` | Mount it under a path, such as `/app`, with an image built for that path |
| The first deploy with the GUI fails because `troupe-gui` objects exist and belong to another release | The old chart's `troupe-gui` release is still installed | `helm -n troupe-system list` | `helm uninstall troupe-gui -n troupe-system`, then deploy (see "Deploy and upgrade") |

## The recorded deployment

From `REPORT.md:236-267`, **recorded on 2026-09-13 and not verified for this audit**;
nothing was run against the cluster (AUDIT §5).

| | |
|---|---|
| URL | `https://troupe.itmindsinternal.dk/app` |
| Image | `rg.fr-par.scw.cloud/troupe/troupe-gui:0.1.1` (`sha256:ae03b5a9…`) |
| Release / namespace | `troupe-gui`, revision 3, `troupe-system` |
| Pods | 2, ready |
| Ingress | host `troupe.itmindsinternal.dk`, path `/app(/\|$)(.*)`, class nginx |
| Certificate | `troupe-plane-tls`, shared with the plane's ingress |
| Values | `.local/values.itminds.yaml` (gitignored, not read for these documents) |
| Plane allowlists at the time | `TROUPE_CORS_ORIGINS` and `TROUPE_WORKER_ALLOWED_ORIGINS` carried `http://localhost:5173` (`REPORT.md:147-150`); same-origin serving makes the CORS entry unnecessary for `/app` itself |
| Outstanding | The SPA redirect URI `https://troupe.itmindsinternal.dk/app` had to be registered at Entra; sign-in was not exercised (`REPORT.md:264-267`) |

Unconfirmed: how the `0.1.1` image was built and pushed (AUDIT §3.5). The version
question is settled: the GUI's image is now tagged with the release's version, which is
the chart's `appVersion` (root Decision 668). That deployment is the old chart's
`troupe-gui` release; see "Deploy and upgrade" for what a cluster still carrying it needs.

## Related

- [configuration.md](configuration.md) — every value referenced above.
- [identity-provider.md](identity-provider.md) — the registration steps.
- [../developer/deployment.md](../developer/deployment.md) — the same procedures with
  the chart internals.
- Server side: the platform's operator docs at the repository root,
  [docs/admin/](../../../../docs/admin/README.md), for the plane's and workers' settings.
