> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).

# Identity provider

What an OpenID Connect provider must allow for the GUI to sign people in. The GUI has no
client secret and no provider configuration of its own: it learns the issuer, client id,
endpoints and scopes from the plane's discovery document, and the plane's own provider
setup is documented in the server repository — see
[docs/admin/integrations.md](../../../../docs/admin/integrations.md) in
`troupe-remote` (a separate repository; not present in that tree at audit time, so the
link is to where it is expected).

## The one registration the GUI adds

The plane already has an application registered at the provider (its `client_id`,
published at `/.well-known/troupe`). The GUI uses **the same application**
(`packages/client/src/pkce.ts:10-12`) and needs one more thing on it:

**A single-page-application redirect URI equal to the GUI's origin plus its base path,
without a trailing slash.**

`apps/desktop/src/shell.ts:91-95` computes it as `location.origin` + `BASE_URL`, then
strips trailing slashes. Examples:

| Deployment | `TROUPE_GUI_BASE` / `basePath` | Redirect URI to register |
|---|---|---|
| Development | `/` | `http://localhost:5173` |
| At a path on the plane's host | `/app` | `https://troupe.example.com/app` |
| Own host | `/` | `https://gui.example.com` |

Providers match redirect URIs exactly (`shell.ts:88-89`), so `https://…/app/` with a
slash is a different URI. The recorded deployment's is
`https://troupe.itmindsinternal.dk/app` (`REPORT.md:264-267`).

For Microsoft Entra the platform type matters: register it under **Authentication →
Add a platform → Single-page application**, not Web, because only the SPA platform
answers the token endpoint cross-origin without a secret (`apps/desktop/src/views/SignIn.tsx:172-175`;
`REPORT.md:182-184`).

## Which flow, and why

| Host | Flow | Chosen when |
|---|---|---|
| Any browser | Authorization code with PKCE (S256), public client, no secret | `location.href` and `crypto.subtle` exist (`packages/client/src/auth.ts:193-196`) |
| Anything else (a terminal, a future desktop shell without a redirect, the test harness) | Device authorization grant | Otherwise |

The browser cannot use the device grant against Microsoft Entra: the `devicecode`
endpoint sends no CORS headers, so the request is refused before it leaves the page
(`pkce.ts:4-8`; `REPORT.md:152-158`; `DECISIONS.md` #20-21). The device grant is still
required at the provider for the CLI and any non-browser client of the same plane.

So the application must allow:

| Capability | Needed by | Provider setting (generic) |
|---|---|---|
| Authorization code grant with PKCE, public client | the GUI in a browser | Public client / SPA platform; PKCE required or allowed; no client secret expected |
| Redirect URI as above | the GUI in a browser | Redirect URIs |
| Device authorization grant | CLI, non-browser hosts, the test harness | "Allow public client flows" or equivalent |
| Refresh tokens | staying signed in across reloads | `offline_access` scope, or the provider's equivalent |
| Token endpoint reachable cross-origin from the GUI's origin | the GUI in a browser | Entra: implied by the SPA platform. Other providers: the public client's allowed web origins (`README.md:73-76`; `packages/client/test/support/idp.ts:29-37`) |
| The provider's `/.well-known/openid-configuration` reachable cross-origin | the GUI, when the plane does not publish `authorization_endpoint` | Entra answers it; others vary (`pkce.ts:65-72`; `DECISIONS.md` #22) |

## What the GUI takes from the plane's discovery document

`GET <plane>/.well-known/troupe` (`packages/client/src/plane.ts:218-223`):

| Field | Used as |
|---|---|
| `client_id` | `client_id` on the authorize request, the token exchange, the refresh, and the device grant (`pkce.ts:152, 162`; `plane.ts:227, 255, 279`) |
| `issuer` | The base for `/.well-known/openid-configuration` when no authorize endpoint is published; tenant detection for the Microsoft `domain_hint`; shown to the person as "You will sign in with `<host>`" (`pkce.ts:83`, `:189-200`; `SignIn.tsx:148`) |
| `authorization_endpoint` (optional) | Used directly if present, saving a round trip (`pkce.ts:74-82`) |
| `token_endpoint` | Code exchange, refresh, device polling (`pkce.ts:79, 151`; `plane.ts:257, 280`) |
| `device_authorization_endpoint` | Device grant step one (`plane.ts:228`) |
| `scopes` | Sent verbatim as `scope` on both flows (`pkce.ts:165`; `plane.ts:227`) |

Anything the operator changes at the provider or on the plane's OIDC settings reaches the
GUI on its next discovery call; there is nothing to redeploy on the GUI side.

## Scopes, and `groups`

The plane publishes the scope list; the GUI asks for exactly that. `groups` **is a
claim, not a scope**: group membership is a property of the token the provider is
configured to issue, named on the plane by `TROUPE_GROUPS_CLAIM`, and asking for it as a
scope makes Entra refuse the sign-in with `AADSTS650053` before a password is typed
(`DECISIONS.md` #27; `REPORT.md:193-202`). The server's default scope list is now the
four OIDC scopes (`openid profile email offline_access`, `REPORT.md:222-226`) with
`TROUPE_OIDC_SCOPES` to override (`../../../../config/runtime.exs:260`).

Discrepancy: the fake plane used by tests and `pnpm fake` still advertises `groups`
among its scopes (`packages/client/test/support/plane.ts:126`). The fake provider
ignores scopes, so nothing fails; a real one would.

## Entra-specific behaviour in the GUI

| Behaviour | Where |
|---|---|
| `prompt=select_account` on every browser sign-in, so a shared machine is asked which account | `SignIn.tsx:83-85` |
| `domain_hint=organizations` when the issuer host is `login.microsoftonline.com`, `login.microsoft.com` or `sts.windows.net` **and** the path names a tenant other than `common` or `consumers` — so the picker stops offering personal accounts that would fail after the password | `pkce.ts:180-200`; `DECISIONS.md` #23 |
| No `domain_hint` for any other provider | `pkce.ts:186-188` |
| `response_mode=query` so the code never lands in the fragment | `pkce.ts:169-171` |
| A returned `error` (e.g. `AADSTS50011`, redirect URI not registered) is surfaced verbatim | `pkce.ts:247-248` |

## The two allowlists

A browser build must be allowed in two places besides the provider (`README.md:69-76`;
`DECISIONS.md` #10). Neither is a GUI setting.

| Allowlist | Where | What breaks without it | What the GUI shows |
|---|---|---|---|
| The plane's CORS allowlist | `TROUPE_CORS_ORIGINS` on the plane (`../../../../config/runtime.exs:266`; chart `plane.corsOrigins`, `charts/troupe/values.yaml:82` in the server repo) | Discovery, `/auth/exchange` and `/rpc` from the browser | The text below |
| The worker's allowed origins | `TROUPE_WORKER_ALLOWED_ORIGINS` (`runtime.exs:130`; chart `workerAllowedOrigins`, `values.yaml:49`) | The `wss://` upgrade to a pod from the browser — the one hop with no fallback (`REPORT.md:188-191`) | A reconnecting banner, then "Could not reach this session" after the backoff list (`Session.tsx:183-196`) |

When the GUI is served at a path on the plane's own host, the plane allowlist is not
consulted for it (same origin); the worker's still is, because pods are on their own
hosts (`REPORT.md:142-150`).

### The exact error text

When a `fetch` to the plane fails before any response arrives — the shape of a blocked
cross-origin request, or of an unreachable host, which a browser cannot tell apart — the
GUI shows (`packages/client/src/auth.ts:87-90`):

> could not reach the plane at `<planeUrl>`. Either the plane is not reachable, or it
> does not allow this origin: a plane only answers a browser from an origin in its
> allowlist, and this build is served from `<origin>`. Add `<origin>` to
> TROUPE_CORS_ORIGINS on the plane and restart it.

Outside a browser the second sentence is instead: "This is not a browser, so it is not
the origin allowlist; check the URL and that the plane is reachable." (`auth.ts:89`).

When the provider refuses the redirect with a message matching
`redirect_uri`, `AADSTS50011`, `invalid_client` or `unauthorized_client`, the GUI adds
(`SignIn.tsx:164-176`):

> The identity provider does not know this address. Register `<redirectUri>` as a
> **single-page application** redirect URI on the application this plane signs in with
> — for Microsoft Entra that is Authentication → Add a platform → Single-page
> application, not Web.

## Checklist for a new deployment

1. Note the GUI's origin and base path; compute the redirect URI (origin + path, no
   trailing slash).
2. On the plane's application at the provider, add it as an SPA redirect URI.
3. Confirm the application is a public client that allows PKCE and, for the CLI, the
   device grant; confirm `offline_access` (or equivalent) is granted.
4. Confirm the plane's published `scopes` contain no `groups`.
5. If the GUI is on its own host, add its origin to `TROUPE_CORS_ORIGINS`.
6. Add the GUI's origin to `TROUPE_WORKER_ALLOWED_ORIGINS` in every case.
7. Sign in once from a browser and watch for the two messages above.

Unconfirmed: whether a full sign-in has completed against the recorded deployment
(`REPORT.md:264-267`, `:278-281`; AUDIT §4.1).

## Related

- [configuration.md](configuration.md) — the base path that determines the redirect
  URI.
- [operations.md](operations.md) — troubleshooting the two allowlists.
- [../developer/architecture.md](../developer/architecture.md) §4 — the flows in code.
