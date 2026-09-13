> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).

# Admin track

Documentation for whoever runs the Troupe GUI: a static web bundle served by nginx from
a Helm chart, talking from the user's browser to a Troupe plane and its worker pods. The
plane and workers are the separate `troupe-remote` repository; their operator docs are
under [../../../troupe-remote/docs/](../../../troupe-remote/docs/AUDIT.md).

Three facts shape everything here (`charts/troupe-gui/values.yaml:1-3`; AUDIT §1.4):

- **The container takes no environment variables.** The Deployment template has no
  `env:` block (`charts/troupe-gui/templates/deployment.yaml:27-51`).
- **There is no `.env.example`** and no runtime configuration file. What the GUI serves
  was decided when the image was built; the one build-time input, `TROUPE_GUI_BASE`,
  is baked into the asset URLs.
- **Nothing is stored server-side.** User state is in each person's browser.

## Pages

| Page | What it covers |
|---|---|
| [configuration.md](configuration.md) | Every Helm value with its default, template line and effect; the base-path contract; browser storage keys; the plane URL prefill; what is read from the plane's discovery document; theme; nginx behaviours |
| [identity-provider.md](identity-provider.md) | What the OIDC provider must allow: the SPA redirect URI, PKCE without a secret, the device grant for other hosts, scopes and the `groups` claim, Entra specifics, the two allowlists, and the exact error text |
| [operations.md](operations.md) | Deploy, upgrade and roll back with `scripts/deploy` and Helm; health checks; what to monitor; backup (nothing); routine tasks; a troubleshooting table; the recorded deployment |

Other tracks: [../user/README.md](../user/README.md) for what people see;
[../developer/README.md](../developer/README.md) for changing the code;
[../whitepaper.md](../whitepaper.md) for the shape of the system.

## Self-check: Helm values

Every key in `charts/troupe-gui/values.yaml`, and where it is documented.

| Value | Line | Documented in |
|---|---|---|
| `image.repository` | `values.yaml:6` | [configuration.md](configuration.md) "Helm values" |
| `image.tag` | `:7` | [configuration.md](configuration.md); [operations.md](operations.md) "Deploy and upgrade" |
| `image.pullPolicy` | `:8` | [configuration.md](configuration.md); [operations.md](operations.md) "Troubleshooting" (reused tag) |
| `imagePullSecrets` | `:9` | [configuration.md](configuration.md) |
| `replicas` | `:13` | [configuration.md](configuration.md); [operations.md](operations.md) "Routine tasks" |
| `nameOverride` | `:15` | [configuration.md](configuration.md) |
| `fullnameOverride` | `:16` | [configuration.md](configuration.md) |
| `resources.requests`, `resources.limits` | `:18-20` | [configuration.md](configuration.md) |
| `basePath` | `:25` | [configuration.md](configuration.md) "The base-path contract"; [operations.md](operations.md) "Change the base path" |
| `ingress.enabled` | `:28` | [configuration.md](configuration.md) |
| `ingress.className` | `:29` | [configuration.md](configuration.md); [operations.md](operations.md) "Troubleshooting" (ingress rewrite) |
| `ingress.host` | `:30` | [configuration.md](configuration.md) (required) |
| `ingress.tlsSecretName` | `:35` | [configuration.md](configuration.md); [operations.md](operations.md) (shared certificate) |
| `ingress.certIssuer` | `:36` | [configuration.md](configuration.md); [operations.md](operations.md) |
| `ingress.annotations` | `:37` | [configuration.md](configuration.md) |
| `podAnnotations` | `:39` | [configuration.md](configuration.md) |
| `nodeSelector` | `:40` | [configuration.md](configuration.md) |
| `tolerations` | `:41` | [configuration.md](configuration.md) |
| `affinity` | `:42` | [configuration.md](configuration.md) |

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

None of these is set in this repository. Each is a setting on the plane, the workers or
the identity provider that the GUI's behaviour assumes.

| Setting | Owner | Why the GUI needs it | Documented in |
|---|---|---|---|
| `TROUPE_CORS_ORIGINS` (chart `plane.corsOrigins`) | plane (`../../../troupe-remote/config/runtime.exs:266`) | Discovery, `/auth/exchange`, `/rpc` from a browser on another origin; the GUI names it in its error (`packages/client/src/auth.ts:88`) | [identity-provider.md](identity-provider.md) "The two allowlists"; [operations.md](operations.md) "Troubleshooting" |
| `TROUPE_WORKER_ALLOWED_ORIGINS` (chart `operator.workerAllowedOrigins`) | workers (`runtime.exs:130`) | The `wss://` upgrade from the browser to a pod (`REPORT.md:188-191`) | [identity-provider.md](identity-provider.md); [operations.md](operations.md) |
| `TROUPE_OIDC_SCOPES` (chart `plane.oidc.scopes`) and the absence of `groups` | plane (`runtime.exs:260`) | The GUI sends the published scopes verbatim; `groups` as a scope fails at Entra (`DECISIONS.md` #27) | [identity-provider.md](identity-provider.md) "Scopes, and groups" |
| `TROUPE_GROUPS_CLAIM` | plane | Group membership is a claim, not a scope (`DECISIONS.md` #27) | [identity-provider.md](identity-provider.md) |
| `TROUPE_OIDC_AUTHORIZE_URL` / `authorization_endpoint` in discovery | plane (`runtime.exs:327`) | If published, the GUI skips the provider's metadata fetch (`packages/client/src/pkce.ts:74-82`). Unconfirmed whether the live plane now publishes it (`DECISIONS.md` #22 says it did not) | [configuration.md](configuration.md) "What the GUI reads from the plane's discovery document" |
| The plane's `client_id`, `issuer`, endpoints | plane discovery (`packages/client/src/plane.ts:9-17`) | Every request to the provider | [configuration.md](configuration.md); [identity-provider.md](identity-provider.md) |
| SPA redirect URI = `<origin><basePath>` | identity provider | The browser sign-in (`apps/desktop/src/shell.ts:91-95`) | [identity-provider.md](identity-provider.md) "The one registration the GUI adds" |
| Public client with PKCE; device grant enabled; refresh tokens | identity provider | Browser and non-browser sign-in; staying signed in | [identity-provider.md](identity-provider.md) "Which flow, and why" |

Server-side detail for the first five is in the `troupe-remote` repository's docs, in
particular [docs/admin/integrations.md](../../../troupe-remote/docs/admin/integrations.md)
(not present in that tree at audit time; linked to where it is expected).

## Findings an operator should know

From [../AUDIT.md](../AUDIT.md):

- The live deployment is recorded (`REPORT.md:236-267`) and was not verified for the
  audit; its sign-in had not yet been completed (AUDIT §4.1).
- The chart's `appVersion` is `0.1.0`; the recorded image tag is `0.1.1`; there is no
  tagging rule (AUDIT §3.5).
- A local `docker build` copies `.local/` — including a kubeconfig — into the build
  stage because `.dockerignore` omits it; the runtime image is unaffected (AUDIT §3.1).
- The CI workflow that would build and push images is untracked and has never run
  (AUDIT §1.5); every image so far was built by a person.
