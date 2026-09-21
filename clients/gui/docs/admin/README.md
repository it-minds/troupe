> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).
> The GUI now lives at `clients/gui` in the Troupe repository and is deployed as the `gui:` block of the root `charts/troupe`; its own chart and `scripts/deploy` are gone (root Decisions 666, 669, 670).

# Admin track

Documentation for whoever runs the Troupe GUI: a static web bundle served by nginx, part
of the platform's own chart, talking from the user's browser to a Troupe plane and its
worker pods. The plane and workers are in the same repository; their operator docs are
under [../../../../docs/](../../../../docs/admin/README.md).

Three facts shape everything here (AUDIT §1.4):

- **The container takes no environment variables.** The Deployment template has no
  `env:` block (the root `charts/troupe/templates/gui-deployment.yaml`).
- **There is no `.env.example`** and no runtime configuration file. What the GUI serves
  was decided when the image was built; the one build-time input, `TROUPE_GUI_BASE`,
  is baked into the asset URLs.
- **Nothing is stored server-side.** User state is in each person's browser.

## Pages

| Page | What it covers |
|---|---|
| [configuration.md](configuration.md) | Every `gui.*` value, and the plane's values the GUI shares, with its default and effect; the base-path contract; browser storage keys; the plane URL prefill; what is read from the plane's discovery document; theme; nginx behaviours |
| [identity-provider.md](identity-provider.md) | What the OIDC provider must allow: the SPA redirect URI, PKCE without a secret, the device grant for other hosts, scopes and the `groups` claim, Entra specifics, the two allowlists, and the exact error text |
| [operations.md](operations.md) | Deploy, upgrade and roll back with the platform's release and the root `scripts/deploy`; health checks; what to monitor; backup (nothing); routine tasks; a troubleshooting table; the recorded deployment |

Other tracks: [../user/README.md](../user/README.md) for what people see;
[../developer/README.md](../developer/README.md) for changing the code;
[../whitepaper.md](../whitepaper.md) for the shape of the system.

## Self-check: Helm values

Every value of the root `charts/troupe/values.yaml` the GUI reads, and where it is
documented. The `gui:` block is the GUI's own; the rest it shares with the plane.

| Value | Documented in |
|---|---|
| `gui.enabled` | [configuration.md](configuration.md) "Helm values" |
| `gui.image.repository` | [configuration.md](configuration.md) |
| `gui.image.tag` | [configuration.md](configuration.md); [operations.md](operations.md) "Deploy and upgrade" |
| `gui.image.pullPolicy` | [configuration.md](configuration.md); [operations.md](operations.md) "Troubleshooting" (reused tag) |
| `gui.replicas` | [configuration.md](configuration.md); [operations.md](operations.md) "Routine tasks" |
| `gui.basePath` | [configuration.md](configuration.md) "The base-path contract"; [operations.md](operations.md) "Change the base path" |
| `gui.resources.requests`, `gui.resources.limits` | [configuration.md](configuration.md) |
| `imagePullSecrets`, `namespace` | [configuration.md](configuration.md) |
| `plane.host`, `plane.ingressClassName`, `plane.tlsSecretName` | [configuration.md](configuration.md); [operations.md](operations.md) "Troubleshooting" (ingress rewrite) |
| `plane.appUrl` | [configuration.md](configuration.md); [operations.md](operations.md) "Routine tasks" |

## Self-check: runtime and browser storage

The GUI reads no runtime configuration. What it stores in the browser:

| Key | Store | Line | Documented in |
|---|---|---|---|
| `troupe.auth.refresh:<planeUrl>` | `localStorage` | `packages/client/src/auth.ts:40, 167` | [configuration.md](configuration.md) "Browser storage" |
| `troupe.auth.pending` | `sessionStorage` | `packages/client/src/pkce.ts:115` | [configuration.md](configuration.md); [identity-provider.md](identity-provider.md) |
| `troupe.pref.planeUrl` | `localStorage` | `apps/desktop/src/shell.ts:115, 122`; `views/SignIn.tsx:26, 75` | [configuration.md](configuration.md) "The plane URL" |
| `troupe.pref.theme` | `localStorage` | `apps/desktop/src/views/bits.tsx:131, 138` | [configuration.md](configuration.md) "Theme" |

Held in memory only, never stored: the plane token (`auth.ts:153`) and pod tokens
(`packages/client/src/attach.ts:49`) — [configuration.md](configuration.md).

Build-time input: `TROUPE_GUI_BASE` (`apps/desktop/vite.config.ts:16`; `Dockerfile:38`)
— [configuration.md](configuration.md) "The base-path contract".

## Self-check: server-side settings the GUI depends on

None of these is the GUI's. Each is a setting on the plane, the workers or the identity
provider that the GUI's behaviour assumes.

| Setting | Owner | Why the GUI needs it | Documented in |
|---|---|---|---|
| `TROUPE_CORS_ORIGINS` (chart `plane.corsOrigins`) | plane (`../../../../config/runtime.exs:266`) | Discovery, `/auth/exchange`, `/rpc` from a browser on another origin; the GUI names it in its error (`packages/client/src/auth.ts:88`) | [identity-provider.md](identity-provider.md) "The two allowlists"; [operations.md](operations.md) "Troubleshooting" |
| `TROUPE_WORKER_ALLOWED_ORIGINS` (chart `operator.workerAllowedOrigins`) | workers (`runtime.exs:130`) | The `wss://` upgrade from the browser to a pod (`REPORT.md:188-191`) | [identity-provider.md](identity-provider.md); [operations.md](operations.md) |
| `TROUPE_OIDC_SCOPES` (chart `plane.oidc.scopes`) and the absence of `groups` | plane (`runtime.exs:260`) | The GUI sends the published scopes verbatim; `groups` as a scope fails at Entra (`DECISIONS.md` #27) | [identity-provider.md](identity-provider.md) "Scopes, and groups" |
| `TROUPE_GROUPS_CLAIM` | plane | Group membership is a claim, not a scope (`DECISIONS.md` #27) | [identity-provider.md](identity-provider.md) |
| `TROUPE_OIDC_AUTHORIZE_URL` / `authorization_endpoint` in discovery | plane (`runtime.exs:327`) | If published, the GUI skips the provider's metadata fetch (`packages/client/src/pkce.ts:74-82`). Unconfirmed whether the live plane now publishes it (`DECISIONS.md` #22 says it did not) | [configuration.md](configuration.md) "What the GUI reads from the plane's discovery document" |
| The plane's `client_id`, `issuer`, endpoints | plane discovery (`packages/client/src/plane.ts:9-17`) | Every request to the provider | [configuration.md](configuration.md); [identity-provider.md](identity-provider.md) |
| SPA redirect URI = `<origin><basePath>` | identity provider | The browser sign-in (`apps/desktop/src/shell.ts:91-95`) | [identity-provider.md](identity-provider.md) "The one registration the GUI adds" |
| Public client with PKCE; device grant enabled; refresh tokens | identity provider | Browser and non-browser sign-in; staying signed in | [identity-provider.md](identity-provider.md) "Which flow, and why" |

Server-side detail for the first five is in the platform's docs at the repository root,
in particular [docs/admin/configuration.md](../../../../docs/admin/configuration.md) and
[docs/admin/integrations.md](../../../../docs/admin/integrations.md).

## Findings an operator should know

From [../AUDIT.md](../AUDIT.md):

- The live deployment is recorded (`REPORT.md:236-267`) and was not verified for the
  audit; its sign-in had not yet been completed (AUDIT §4.1).
- At audit time the chart's `appVersion` was `0.1.0`, the recorded image tag `0.1.1`, and
  there was no tagging rule (AUDIT §3.5). There is one now: the image is tagged with the
  release's version, which is the chart's `appVersion` (root Decisions 668 and 669).
- A local `docker build` copies `.local/` into the build stage because `.dockerignore`
  omits it; the runtime image is unaffected (AUDIT §3.1). Since the move the kubeconfig
  lives in the repository root's `.local/`, outside the GUI's build context.
- At audit time the CI workflow was untracked and had never run, and every image had been
  built by a person (AUDIT §1.5). The root CI now builds and pushes the image on every
  push to `main`, and a release promotes and deploys it.
