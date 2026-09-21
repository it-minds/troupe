> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).

# Configuration

Everything an operator can set, and everything the running GUI reads. There is little of
either: the container takes **no environment variables**, there is no `.env.example`,
and the one build-time input is baked into the image (`charts/troupe-gui/values.yaml:1-3`;
AUDIT §1.4). What varies per deployment is the Helm values, the identity provider's
registration ([identity-provider.md](identity-provider.md)), and the plane's own
allowlist, which belongs to the server's configuration.

## Helm values

`charts/troupe-gui/values.yaml`, with the template line each one reaches.

| Value | Default | Template | Effect |
|---|---|---|---|
| `image.repository` | `ghcr.io/objective-mj/troupe-gui` (`values.yaml:6`) | `deployment.yaml:29` | Image name. The recorded deployment uses a different registry (`REPORT.md:247`) |
| `image.tag` | `""` (`:7`) | `deployment.yaml:29` — `default .Chart.AppVersion` | Empty means the chart's `appVersion`, `0.1.0` (`Chart.yaml:6`). `scripts/deploy` overrides it with `--set image.tag=$TAG` when `TAG` is set (`scripts/deploy:39`) |
| `image.pullPolicy` | `IfNotPresent` (`:8`) | `deployment.yaml:30` | With a reused tag, the node keeps the image it has and no pod restarts; check the digest, not the tag (`values.yaml`, `scripts/deploy:48-54`) |
| `imagePullSecrets` | `[]` (`:9`) | `deployment.yaml:17-19` | Needed for a private registry |
| `replicas` | `2` (`:13`) | `deployment.yaml:7` | Two so a rolling deploy has no 502 window; there is no state to coordinate (`:11-12`) |
| `nameOverride` | `""` (`:15`) | `_helpers.tpl:1-3` | Chart name in labels and resource names |
| `fullnameOverride` | `""` (`:16`) | `_helpers.tpl:5-16` | Full resource name; otherwise `<release>` or `<release>-troupe-gui` |
| `resources.requests` | `cpu: 10m, memory: 32Mi` (`:19`) | `deployment.yaml:48` | |
| `resources.limits` | `cpu: 200m, memory: 128Mi` (`:20`) | `deployment.yaml:48` | |
| `basePath` | `/app` (`:25`) | `_helpers.tpl:31-35` → `ingress.yaml:2, 12-19, 37-46` | The mount point. **Must equal the `TROUPE_GUI_BASE` the image was built with** (`:22-24`). `/` disables the rewrite and uses a `Prefix` path |
| `ingress.enabled` | `true` (`:28`) | `ingress.yaml:1` | |
| `ingress.className` | `nginx` (`:29`) | `ingress.yaml:27` | The `rewrite-target` annotation is nginx-ingress's; another class will not strip the prefix |
| `ingress.host` | `""` (`:30`) | `ingress.yaml:3-5, 30, 34` | **Required** when the ingress is enabled; the template fails otherwise |
| `ingress.tlsSecretName` | `""` (`:35`) | `ingress.yaml:28-32` | Names the certificate secret. Naming one another release owns is supported: two Ingresses on one host share one certificate (`:31-34`) |
| `ingress.certIssuer` | `""` (`:36`) | `ingress.yaml:20-22` | Sets `cert-manager.io/cluster-issuer`. Leave empty when sharing a secret, or cert-manager issues a second certificate for the same host (`:33-34`) |
| `ingress.annotations` | `{}` (`:37`) | `ingress.yaml:23-25` | Merged after the chart's own |
| `podAnnotations` | `{}` (`:39`) | `deployment.yaml:13-15` | |
| `nodeSelector` | `{}` (`:40`) | `deployment.yaml:55-57` | |
| `tolerations` | `[]` (`:41`) | `deployment.yaml:58-60` | |
| `affinity` | `{}` (`:42`) | `deployment.yaml:61-63` | |

Fixed by the templates, not configurable: pod `runAsNonRoot`, `runAsUser: 101`,
`fsGroup: 101`, `seccompProfile: RuntimeDefault` (`deployment.yaml:22-26`); container
`allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop:
["ALL"]` (`:34-37`); port 8080 named `http` (`:31-33`); readiness probe `/healthz` after
2 s every 10 s and liveness after 10 s every 30 s (`:40-47`); `emptyDir` volumes at
`/var/cache/nginx` and `/tmp` (`:49-54`); Service `ClusterIP` port 80 → `http`
(`service.yaml:7-12`).

Unconfirmed: the values used for the recorded deployment are in the gitignored
`.local/values.itminds.yaml` and were not read for this audit (AUDIT §1.5).

## The base-path contract

Three places must say the same thing:

| Where | What | Set by |
|---|---|---|
| The image | `TROUPE_GUI_BASE` at `docker build` time; normalised so `app`, `/app`, `/app/` are the same (`apps/desktop/vite.config.ts:16-17`) | Whoever built the image; CI would use `vars.GUI_BASE` or `app` (`.github/workflows/ci.yml:109`); the Dockerfile default is `/` (`Dockerfile:38`) |
| The chart | `basePath` (`values.yaml:25`, default `/app`) | The values file |
| The ingress | Path `<basePath>(/\|$)(.*)` with `rewrite-target: /$2` (`ingress.yaml:18, 41`) | Rendered from `basePath` |

Vite writes the base into every asset URL, so an image built for `/app/` served at `/`
(or the reverse) loads `index.html` and then 404s on every script: a blank page
(`values.yaml:22-24`; `DECISIONS.md` #30). **Changing the base path is a rebuild of the
image, not a values change.** The ingress strips the prefix so the container is
"ignorant of where it is mounted" (`ingress.yaml:13-17`; `DECISIONS.md` #31).

The bundle also uses the base path at runtime: the OIDC redirect URI is
`<origin><basePath>` without a trailing slash (`apps/desktop/src/shell.ts:91-95`), and
when the base path is not `/` the sign-in screen prefills the plane URL with the page's
own origin (`shell.ts:105-109`; `DECISIONS.md` #35). Serving the GUI at a path on the
plane's host is therefore the recommended shape: same origin, no CORS entry, one
certificate (`DECISIONS.md` #29; `README.md:127-131`).

## Browser storage

What the GUI persists in the user's browser, and nothing else. Every read and write is
wrapped in `try/catch`, so a browser that refuses storage degrades to memory
(`packages/client/src/auth.ts:42-63`, `apps/desktop/src/shell.ts:113-126`,
`views/bits.tsx:148-161`).

| Key | Store | Holds | Written at | Cleared at |
|---|---|---|---|---|
| `troupe.auth.refresh:<planeUrl>` | `localStorage` | **The identity provider's refresh token — the only persisted secret.** One key per plane URL | `auth.ts:40` (prefix) + `:167` (key), written in `adopt` (`:295`) | Sign out (`:263-266`) or a refresh the provider refuses (`:255-258`) |
| `troupe.auth.pending` | `sessionStorage` | PKCE verifier, `state`, redirect URI, token endpoint, client id, plane URL — only between leaving for the provider and coming back | `packages/client/src/pkce.ts:115, 155-157` | Spent on the first redemption attempt, success or failure (`:265-269`); tab close |
| `troupe.pref.planeUrl` | `localStorage` | The plane URL last typed | `apps/desktop/src/shell.ts:120-126`; `views/SignIn.tsx:75` | Never by the app |
| `troupe.pref.theme` | `localStorage` | `"dark"` or `"light"` | `views/bits.tsx:136-139` | Never by the app |

**Not persisted anywhere:** the plane token (memory in `AuthSession`, `auth.ts:153`,
≤ 15 minutes, renewed 120 s before expiry, `:160`, `:273-281`) and the pod tokens
(memory in `SessionAttachment`, `packages/client/src/attach.ts:11, 49`). Session
content is never stored; every screen is a fold over events the socket delivered
(`packages/client/src/transcript.ts:1-3`). Clearing site data for the GUI's origin signs
the person out and forgets their plane URL and theme; nothing else is lost.

A desktop shell could supply an OS-keychain `secretStore` instead of `localStorage`
(`shell.ts:23-32`, `:69-78`); none exists in this repository. The browser build tells
the person on the sign-in screen that the token is in browser storage
(`views/SignIn.tsx:18-23`, `:149`).

## The plane URL

The person types it (`views/SignIn.tsx:116-125`). Prefill rule: the remembered
`troupe.pref.planeUrl` if any, else `likelyPlaneUrl()` — the page's own origin when the
GUI is served at a sub-path, empty when it is served at `/` (`SignIn.tsx:26`;
`shell.ts:105-109`). Trailing slashes are stripped (`auth.ts:157`). The GUI supports one
plane at a time per tab, though refresh tokens are keyed per plane URL.

## What the GUI reads from the plane's discovery document

`GET <planeUrl>/.well-known/troupe`, unauthenticated (`packages/client/src/plane.ts:218-223`).
Fields used:

| Field | Used for | Citation |
|---|---|---|
| `issuer` | Shown on the sign-in screen ("You will sign in with `<host>`"); the base for `/.well-known/openid-configuration` when the plane publishes no authorize endpoint; Microsoft tenant detection for `domain_hint` | `SignIn.tsx:82, 148`; `pkce.ts:83`, `:189-200` |
| `client_id` | Every request to the identity provider | `plane.ts:227, 255, 279`; `pkce.ts:152, 162` |
| `device_authorization_endpoint` | Device grant (non-browser hosts) | `plane.ts:228` |
| `token_endpoint` | Device polling, refresh, and the PKCE code exchange | `plane.ts:257, 280`; `pkce.ts:79, 151` |
| `scopes` | Sent as the `scope` parameter on both flows | `plane.ts:227`; `pkce.ts:165` |
| `authorization_endpoint` (optional) | If present, used directly and the provider's metadata is not fetched | `pkce.ts:74-82` |
| `plane.protocol_version` | Asserted in one test only (`stage1.test.ts:167`); the client sends `protocol_version: "1"` unconditionally | `plane.ts:15`; `connection.ts:69, 149` |

The plane's `rpc` and `jwks` paths from `plane.*` are not read; the client always posts
to `<planeUrl>/rpc` and `<planeUrl>/auth/exchange` (`plane.ts:291, 303`).

## Theme

Dark by default. `ThemeToggle` reads `troupe.pref.theme`, else `prefers-color-scheme:
light`, and sets `data-theme` on `<html>` (`views/bits.tsx:129-146`). The generated
stylesheet defines dark on `:root`, light under `:root[data-theme="light"]`, and light
again for systems that ask for it when no toggle has been set (`scripts/tokens.ts:132-155`;
`DECISIONS.md` #15). There is no server-side or deployment-level theme setting.

## nginx behaviours relevant to operation

`docker/nginx.conf`, shipped in the image (`Dockerfile:53`):

| Behaviour | Detail | Line |
|---|---|---|
| Port | `listen 8080`; the image is `nginx-unprivileged`, uid 101, so no root and no capability to bind (`Dockerfile:48-51`) | `nginx.conf:13` |
| Real client IP | `X-Forwarded-For` trusted from `0.0.0.0/0` — assumes the ingress is the only thing in front | `:19-20` |
| Security headers | `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`, on every response. No CSP, no HSTS (HSTS is the ingress's job) | `:23-25` |
| Compression | gzip for CSS, JS, JSON, SVG ≥ 1 KiB | `:27-29` |
| Health | `GET /healthz` → `200 ok`, no access log; both probes and the image `HEALTHCHECK` use it (`deployment.yaml:41, 45`; `Dockerfile:58-59`) | `:33-37` |
| Hashed assets | `.js .css .woff2 .woff .png .jpg .jpeg .gif .svg .ico .webp .map` → `Cache-Control: public, immutable`, one year. Safe because Vite renames on content change | `:41-45` |
| Everything else | `Cache-Control: no-cache`; `try_files $uri $uri/ /index.html` — the SPA fallback, so a deep link or a refresh on `/app/anything` serves the app rather than 404 | `:47-50` |
| Read-only filesystem | nginx writes only under `/var/cache/nginx` and `/tmp`, both `emptyDir`s in the chart | `deployment.yaml:49-54` |
| Logs | Default nginx access and error logs to stdout/stderr (the base image's configuration; not overridden here). `/healthz` is excluded | `:34` |

## Related

- [identity-provider.md](identity-provider.md) — the registration outside this chart.
- [operations.md](operations.md) — deploy, upgrade, rollback, troubleshooting.
- [../developer/build.md](../developer/build.md) — how the base path gets into the
  image.
- Server-side settings the GUI depends on: the plane's `TROUPE_CORS_ORIGINS`
  (`../../../../config/runtime.exs:266`) and the worker's
  `TROUPE_WORKER_ALLOWED_ORIGINS` (`runtime.exs:130`), documented in the server's
  [docs/AUDIT.md](../../../../docs/AUDIT.md) — a separate repository.
