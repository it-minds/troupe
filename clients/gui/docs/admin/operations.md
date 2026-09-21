> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).

# Operations

Running the GUI on a cluster: deploy, upgrade, roll back, watch, and fix. The GUI is a
static bundle behind nginx with no state, no secrets and no environment variables
(`Dockerfile:1-6`; `charts/troupe-gui/values.yaml:1-3`), so most of this is short.

## Deploy and upgrade

`scripts/deploy` wraps `helm upgrade --install` (`scripts/deploy:37-46`). It reads five
variables, all with defaults (`:23-26`, `:39`):

| Variable | Default | Meaning |
|---|---|---|
| `KUBECONFIG_FILE` | `.local/kubeconfig.yaml` | Cluster credentials |
| `VALUES` | `.local/values.itminds.yaml` | The values file for this deployment |
| `NAMESPACE` | `troupe-system` | Namespace |
| `RELEASE` | `troupe-gui` | Helm release name |
| `TAG` | unset | `--set image.tag=…`; otherwise the tag in the values file, else the chart's `appVersion` `0.1.0` |

Render without changing anything:

```bash
scripts/deploy --dry-run
```

Deploy the tag the values file names:

```bash
scripts/deploy
```

Deploy a specific image:

```bash
TAG=sha-1a2b3c4 scripts/deploy
```

The script waits up to five minutes for the rollout (`:46`) and then prints every pod's
`imageID` — the running **digest** (`:55-58`). Read it: a tag that already existed in
the registry plus `imagePullPolicy: IfNotPresent` means no image is pulled and, because
the Deployment spec did not change, no pod restarts; `helm upgrade` reports success over
old code (`:48-54`; `REPORT.md:204-211`). Never reuse a tag.

Without the script, the equivalent Helm command (`README.md:134`):

```bash
helm upgrade --install troupe-gui charts/troupe-gui -n troupe-system --set image.repository=<registry>/troupe-gui --set image.tag=<tag> --set basePath=/app --set ingress.host=troupe.example.com --set ingress.tlsSecretName=troupe-plane-tls
```

## Rollback

There is no rollback in the script. Use Helm:

```bash
helm --kubeconfig .local/kubeconfig.yaml -n troupe-system history troupe-gui
```

```bash
helm --kubeconfig .local/kubeconfig.yaml -n troupe-system rollback troupe-gui <revision>
```

Or roll forward to a known-good tag with `TAG=… scripts/deploy`. Either way, confirm
with the digest:

```bash
kubectl --kubeconfig .local/kubeconfig.yaml -n troupe-system get pods -l app.kubernetes.io/instance=troupe-gui -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,IMAGE:.status.containerStatuses[0].imageID'
```

A rollback changes only the image; nothing persists in the pods (two `emptyDir`s,
`charts/troupe-gui/templates/deployment.yaml:52-54`). Users' browsers pick up the older
bundle on their next load because `index.html` is served `no-cache`
(`docker/nginx.conf:48`).

## Health checks

| Check | Path | Configured at |
|---|---|---|
| Readiness | `GET /healthz` on port 8080, after 2 s, every 10 s | `deployment.yaml:40-43` |
| Liveness | same, after 10 s, every 30 s | `deployment.yaml:44-47` |
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
which are the server repository's concern.

## Routine tasks

| Task | How |
|---|---|
| Deploy a new image | `TAG=<new tag> scripts/deploy`, or edit `image.tag` in the values file and run `scripts/deploy`. Check the digest |
| Change the base path | **Rebuild the image** with the new `TROUPE_GUI_BASE` (`docker build --build-arg TROUPE_GUI_BASE=<path>`), set `basePath` in the values to match, register the new redirect URI at the identity provider ([identity-provider.md](identity-provider.md)), deploy. A values-only change produces a blank page |
| Move the GUI to its own host | `basePath: /` (image built with `/`), `ingress.host` set, a certificate via `certIssuer` or `tlsSecretName`; add the new origin to the plane's `TROUPE_CORS_ORIGINS` and the worker's `TROUPE_WORKER_ALLOWED_ORIGINS`; register the new redirect URI |
| Add an origin on the plane | On the server: `plane.corsOrigins` / `TROUPE_CORS_ORIGINS` and `operator.workerAllowedOrigins` / `TROUPE_WORKER_ALLOWED_ORIGINS` (`REPORT.md:142-150`); a plane restart. Nothing on the GUI side |
| Rotate secrets | Nothing to rotate. The GUI holds none; certificates belong to cert-manager or the release that owns `tlsSecretName` |
| Scale | `replicas` in the values (`values.yaml:13`); the pods are independent |
| Change the theme, plane URL or any user-facing default | Not configurable at deployment; the theme is per browser, the plane URL is prefilled from the origin ([configuration.md](configuration.md)) |

## Troubleshooting

| Symptom | Likely cause | Check | Fix |
|---|---|---|---|
| Sign-in screen shows "could not reach the plane at … Add `<origin>` to TROUPE_CORS_ORIGINS" | The GUI's origin is not in the plane's CORS allowlist, or the plane is down (a browser cannot tell the page which; `packages/client/src/auth.ts:83-90`) | `curl -I https://<plane>/.well-known/troupe`; from a browser console on the GUI's origin, `fetch('<plane>/.well-known/troupe')` | Add the origin to `TROUPE_CORS_ORIGINS`, restart the plane. Not needed when the GUI is on the plane's own host |
| Provider page says the redirect URI is not registered (`AADSTS50011`), or the GUI shows "The identity provider does not know this address. Register `<uri>` …" | Redirect URI missing or registered as Web rather than SPA; or a trailing-slash mismatch | Compare the URI in the GUI's message with the provider's list exactly | Register `<origin><basePath>` as an SPA redirect URI (`SignIn.tsx:172-175`) |
| Provider refuses with `AADSTS650053` (scope does not exist) | The plane publishes `groups` as a scope | `curl https://<plane>/.well-known/troupe` and read `scopes` | Set `TROUPE_OIDC_SCOPES` / `plane.oidc.scopes` on the plane (`DECISIONS.md` #27) |
| Blank page; browser console shows 404s for `/app/assets/…` or `/assets/…` | Image built for one base path, served at another | Compare the asset URLs in the served `index.html` with `basePath` and the ingress path | Rebuild with the matching `TROUPE_GUI_BASE`, or fix `basePath` to match the image |
| Page loads at `/app` but a refresh on `/app/anything` gives 404 from the ingress | Ingress path or class wrong: the rewrite annotation only works on nginx-ingress; the path must be `<base>(/\|$)(.*)` | `kubectl get ingress troupe-gui -o yaml` and compare with `templates/ingress.yaml:18, 41` | Use `ingress.className: nginx`, or provide equivalent rewriting for another class |
| Page loads, but every session shows "Connection lost" then "Could not reach this session" | The worker's WebSocket upgrade refuses the browser's origin — the only hop with no fallback (`REPORT.md:188-191`) | Browser console: the `wss://…/v1/socket` upgrade fails | Add the GUI's origin to `TROUPE_WORKER_ALLOWED_ORIGINS` on the workers |
| `helm upgrade` succeeded but the old code is still served | Tag reused; `IfNotPresent` kept the cached image and no pod restarted | The digest printout from `scripts/deploy`, or the `kubectl` line above, against the registry's digest for the tag | Push under a new tag and deploy it; never reuse a tag (`REPORT.md:204-211`) |
| Old bundle after a deploy in one browser only | Cached `index.html` from a proxy in front of the ingress | Response headers for `index.html` should be `Cache-Control: no-cache` (`nginx.conf:48`) | Fix the intermediate cache; the image is correct |
| Users are signed out after clearing site data, or on a new browser | Expected: the refresh token lives in `localStorage` per browser | — | Sign in again |
| `helm template`/`upgrade` fails with "ingress.host is required" | `ingress.enabled` is true and `host` is empty | `templates/ingress.yaml:3-5` | Set `ingress.host` or `ingress.enabled: false` |
| cert-manager issues a second certificate for a host the plane already has | `certIssuer` set together with a shared `tlsSecretName` | `values.yaml:31-36` | Leave `certIssuer` empty when sharing a secret |

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

Unconfirmed: how the `0.1.1` image was built and pushed (AUDIT §3.5), and whether the
chart's `appVersion` (`0.1.0`) has since been aligned.

## Related

- [configuration.md](configuration.md) — every value referenced above.
- [identity-provider.md](identity-provider.md) — the registration steps.
- [../developer/deployment.md](../developer/deployment.md) — the same procedures with
  the chart internals.
- Server side: [docs/AUDIT.md](../../../troupe-remote/docs/AUDIT.md) in `troupe-remote`
  (separate repository) for the plane's and workers' settings.
