> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).

# Architecture

How the GUI is put together: three packages, one boundary rule, and the modules that
make up the protocol client and the React app. Diagrams and the reasoning behind the
shape are in [../whitepaper.md](../whitepaper.md); this file is the map with file and
line references. Protocol semantics are the server's to define — see
[PROTOCOL.md](../../../../PROTOCOL.md) in the separate `troupe-remote`
repository — and are only restated here where the client depends on a specific detail.

## 1. Three packages

The workspace is `packages/*` and `apps/*` (`pnpm-workspace.yaml:1-3`).

| Package | Name and version | What it is | Runtime dependencies |
|---|---|---|---|
| `packages/client` | `@troupe/client` 0.1.0 (`packages/client/package.json:2-3`) | The protocol in TypeScript: WebSocket connection, plane HTTP client, sign-in, session view and attachment, transcript fold, fleet store | none — the manifest has no `dependencies` key; `ws` is a dev dependency for the fake worker (`packages/client/package.json:22-28`) |
| `packages/bench` | `@troupe/bench` 0.1.0 (`packages/bench/package.json:2-3`) | Throughput test: N clients × K prompts against a worker or a plane | `@troupe/client` (`packages/bench/package.json:11`) |
| `apps/desktop` | `@troupe/desktop` 0.1.0 (`apps/desktop/package.json:2-3`) | The GUI: Vite + React 19, one plain web bundle | `react`, `react-dom`, `@fontsource/ibm-plex-{sans,mono}`, `@troupe/client` (`apps/desktop/package.json:12-18`) |

### The boundary rule

`spec.md:24` states it: `apps/desktop` imports `@troupe/client` and nothing from the
server repository; `@troupe/client` depends on no framework; nothing in the GUI reads a
file under `$TROUPE_STATE_HOME`. What the code does:

- Every desktop import of client code goes through the `@troupe/client` entry point
  (`apps/desktop/src/hooks.ts:6-15`, `App.tsx:9-10`, `shell.ts:13-14`, `views/*.tsx`).
  The path alias resolves it to `packages/client/src/index.ts` for both Vite
  (`apps/desktop/vite.config.ts:27`) and `tsc` (`apps/desktop/tsconfig.json:17-19`).
- `packages/client` imports nothing but its own modules and the platform (`WebSocket`,
  `fetch`, `crypto.subtle`, `localStorage`, `sessionStorage`), each guarded for hosts
  that lack it (`connection.ts:110-111`, `auth.ts:44-46`, `pkce.ts:107-113`).
- The only build-time input the bundle reads is `import.meta.env.BASE_URL`
  (`apps/desktop/src/shell.ts:93, 107`); a grep for `import.meta.env` finds nothing
  else. `TROUPE_STATE_HOME` appears in this repository only as an environment variable
  passed to the *worker container* in the bench recipe (`README.md:175`,
  `docs/bench.md:39`).
- Nothing enforces the rule mechanically: there is no lint or dependency-cruiser step.
  The `types: []` in `packages/client/tsconfig.json:7` keeps Node's ambient types out
  of the client's build, which is the nearest thing to a guard.

### The path a client takes

`README.md:18-25` lists it: discovery over HTTP, sign-in at the identity provider,
`/auth/exchange` for a plane token, `POST /rpc` to list and place sessions, then one
WebSocket to a worker pod for the live session. `PlaneClient` covers the HTTP steps and
`TroupeConnection` + `SessionView` the socket (`README.md:28-29`). The plane is never in
the data path of a live session (`packages/client/src/fleet.ts:77-82`).

## 2. `packages/client/src`, module by module

### `types.ts` — the shapes

JSON-RPC 2.0 envelopes (`types.ts:4-32`), the error code table from PROTOCOL.md §10
(`types.ts:35-54`), `Scope` (`:56`), `InitializeResult` (`:65-74`), durable and
ephemeral events with the `isDurable` guard on `seq` (`:83-109`), `EventEnvelope`
(`:111-116`), `SessionSummary`, `SubscribeResult`, `ResyncRequired`, `AuthExpiring`,
`ToolInvoke`, `BlobResponse`, `FsEntry`/`FsListing`/`FsFile` (`:127-206`). Every
object type is open (`[k: string]: unknown`) because v1 is additive (`types.ts:1-2`).

### `connection.ts` — `TroupeConnection`

One socket, one JSON-RPC message per text frame.

| Function | What it does | Protocol calls |
|---|---|---|
| `TroupeConnection.open(opts, hooks)` (`:109-191`) | Opens the WebSocket (10 s default timeout, `:112`), sends `initialize` as request id 1 with `protocol_version: "1"`, `client_info` (default `troupe-gui 0.1.0`), `capabilities: {tools: false, blobs: true}` and the token in `params.auth.token` (`:148-155`), resolves once the server answers | `initialize` |
| `call(method, params)` (`:215-228`) | Request/response, ids from 2 upward (`:92`) | any |
| `notify` (`:242-246`) | Fire-and-forget | any |
| `refreshAuth(token)` (`:236-239`) | Hands a new pod token over on the open socket | `auth.refresh` |
| `nextCommandId()` (`:209-212`) | `c-<12 hex>-<n>`; the random prefix keeps ids unique across clients because the server's idempotency ledger is keyed on the id alone (`:94-97`) | — |
| `on(hooks)` (`:204-206`) | Replaces hooks on a live connection | — |
| `close()` (`:248-250`) | Code 1000 | — |

Inbound dispatch (`:271-291`): `event` → `onEvent`, `resync_required` →
`onResyncRequired`, `auth.expiring` → `onAuthExpiring`, `tool.invoke` → served by
`onToolInvoke` or answered `-32601 method_not_found` when no hook is set (`:294-312`).
Unknown notifications are ignored (`:288-289`). On close every pending call is rejected
with `TroupeConnectionClosed` (`:314-321`). There is no reconnection logic in this
module; that lives in `attach.ts`.

### `plane.ts` — `PlaneClient`

The plane's HTTP surface. `fetch` is bound to `globalThis` because a browser's `fetch`
throws `Illegal invocation` otherwise, a `TypeError` indistinguishable from a blocked
cross-origin request (`plane.ts:207-210`, `DECISIONS.md` #6).

| Method | HTTP | Notes |
|---|---|---|
| `discover()` (`:219-223`) | `GET /.well-known/troupe` | No auth. Returns `Discovery` (`:9-17`): `issuer`, `client_id`, `device_authorization_endpoint`, `token_endpoint`, `scopes`, `plane.{name,rpc,jwks,protocol_version}` |
| `startDeviceFlow(d)` (`:226-235`) | `POST <device_authorization_endpoint>` form-encoded | Device grant step one |
| `pollDeviceFlow(d, auth)` (`:241-275`) | `POST <token_endpoint>` in a loop | Honours `authorization_pending`; `slow_down` doubles the interval (`:264-269`) |
| `refreshIdp(d, refreshToken)` (`:278-287`) | `POST <token_endpoint>` `grant_type=refresh_token` | Providers rotate the token |
| `exchange(idToken)` (`:290-298`) | `POST /auth/exchange {id_token}` | Returns `PlaneCredential` (`:36-44`): token, `expires_at`, subject, teams, profiles |
| `rpc(planeToken, method, params)` (`:301-320`) | `POST /rpc` with bearer | HTTP 401 becomes `TroupeRpcError` `-32003 unauthenticated` (`:312-315`) |

Typed helpers over `rpc`: `me`, `createSession`, `openSession` (default mode `read`,
`:332`), `mintToken`, `listSessions` (filters are top-level params, `:346-350`),
`getSession`, `listProfiles`, `listTeams`, `reviewSession`, `grantSession`,
`pinSession`, `eraseSession` (`:322-385`). `normalizeEndpoint` (`:189-198`) turns
whatever the plane puts in `endpoint` into a `ws(s)://…/v1/socket` URL.

The screens call `session.review`, `session.grant`, `session.pin`/`unpin`,
`session.erase`, `teams.list` and `me` from nowhere (`REPORT.md:303-304`; AUDIT §1.3).

### `auth.ts` — `AuthSession`

Signing in and staying signed in for one plane.

- **Token stores** (`:18-64`): `memoryTokenStore()` and `webTokenStore(prefix =
  "troupe.auth.")` over `localStorage`. The key is `refresh:<planeUrl>` (`:166-168`),
  so the full `localStorage` key is `troupe.auth.refresh:<planeUrl>`.
- **What is persisted**: only the identity provider's refresh token (`:1-10`, `:295`).
  The plane token lives in `this.credential` (`:153`) and is never written; pod tokens
  live in `SessionAttachment` (`attach.ts:11`).
- **`preferredFlow`** (`:193-196`): `redirect` when `location.href` and
  `crypto.subtle` both exist, else `device`.
- **`signIn(progress, signal)`** (`:233-241`): device grant, then `adopt`.
- **`beginRedirectSignIn(opts)`** (`:202-209`) / **`completeRedirectSignIn()`**
  (`:221-230`): the PKCE flow; the caller navigates, so a shell could open a system
  browser (`:198-201`). The URL is scrubbed in a `finally` (`:227-229`).
- **`adopt(tokens)`** (`:290-299`): persists the rotated refresh token *before* the
  exchange, then `POST /auth/exchange` with `id_token ?? access_token`.
- **`restore()`** (`:248-260`): refresh at the IdP → exchange; on refusal the stored
  token is cleared. A `PlaneUnreachableError` is rethrown, not treated as a bad token.
- **`token()`** (`:273-281`): renews when fewer than `renewMarginSeconds` (default 120,
  `:160`) remain, sharing one in-flight renewal. Renewal is `restore()` — an IdP
  refresh plus a new exchange; there is no plane-side refresh endpoint (`:283-287`).
- **`rpc(method, params)`** (`:302-305`): `token()` then `PlaneClient.rpc`, wrapped so
  a `TypeError` from `fetch` becomes `PlaneUnreachableError` naming the origin and
  `TROUPE_CORS_ORIGINS` (`:78-96`, `:109-117`).
- **`signOut()`** (`:263-266`): clears the credential and the stored refresh token. The
  provider's own session is untouched.

### `pkce.ts` — the authorization code flow

- `pkcePair()` (`:59-63`): 64-character verifier from the unreserved set, S256
  challenge via `crypto.subtle.digest`.
- `idpMetadata(discovery, fetch)` (`:73-87`): uses `discovery.authorization_endpoint`
  if the plane publishes one, else fetches `<issuer>/.well-known/openid-configuration`
  from the provider (`DECISIONS.md` #22).
- `beginRedirect(opts)` (`:142-178`): stores `{verifier, state, redirectUri,
  tokenEndpoint, clientId, planeUrl}` in `sessionStorage` under `troupe.auth.pending`
  (`:115`, `:147-157`) and builds the authorize URL with `response_type=code`,
  `code_challenge_method=S256`, `response_mode=query`, optional `prompt`, and
  `domain_hint=organizations` for a tenant-scoped Microsoft issuer (`:159-177`,
  `:189-200`).
- `completeRedirect(href, fetch)` (`:238-262`): memoised per authorization code so
  React StrictMode's double effect redeems once (`:214-229`, `DECISIONS.md` #28);
  `redeem` (`:264-288`) checks `state`, spends the verifier, and posts
  `grant_type=authorization_code` with `code_verifier` and no client secret.
- `scrubRedirect()` (`:291-300`): removes `code`, `state`, `error`, `error_description`,
  `session_state`, `error_uri` with `history.replaceState`.

### `session.ts` — `SessionView`

One session over whichever socket is bound. The cursor `lastSeq` belongs to the view,
not the socket (`:33-38`), which is what makes a reconnect invisible.

| Method | Protocol call | Notes |
|---|---|---|
| `bind(conn)` / `unbind()` (`:74-82`) | — | Subscriptions belong to the socket, so `subscriptionId` is reset |
| `handle(envelope)` (`:89-105`) | — | Routes by topic or `session_id`; drops durable events with `seq <= lastSeq`; fires `onApprovalRequested`, `onDelta`, `onEvent`, listeners and waiters |
| `subscribe(fromSeq = lastSeq, level = "detail")` (`:113-123`) | `subscribe` | Same call for first subscribe (0) and every resubscribe |
| `resubscribe()` (`:136-139`) | `subscribe` | From the cursor |
| `unsubscribe()` (`:141-145`) | `unsubscribe` | |
| `listen(fn)` (`:130-133`) | — | A second observer on the same stream (the Files pane uses it) |
| `waitFor(pred, timeoutMs)` (`:151-166`) | — | Register before the command that causes the event |
| `send(text, commandId?)` (`:169-172`) | `input.send` | Ack is not the effect; `input_accepted` is |
| `respondApproval(callId, decision)` (`:175-182`) | `approval.respond` | |
| `cancel()` (`:185-187`) | `turn.cancel` | |
| `switchProfile(profile)` (`:190-196`) | `profile.switch` | Applied at the next turn boundary |
| `editTodo(action, params)` (`:198-205`) | `todo.edit` | No screen calls it |
| `setPresence(state)` (`:208-210`) | `presence.set` | |
| `fsList(path = ".")`, `fsRead(path)` (`:213-219`) | `fs.list`, `fs.read` | |
| `blobGet(blob, range?)` (`:226-230`) | `blob.get` | Server may answer a shorter range |
| `blobBytes(blob, limit = 4 MiB)` (`:233-254`) | `blob.get` in a loop | Asks in ≤256 KiB chunks and advances by the range the server *returned* |
| `blobText(blob)` (`:257-259`) | | UTF-8 decode of `blobBytes` |
| `prompt(text, timeoutMs)` (`:270-347`) | `input.send`, then `session.get` polling | A turn ends durably (`agent_done`, `cancelled`, `budget_exhausted`, `llm_error`) or quietly (ephemeral `agent_state` `idle`/`done` after `input_accepted`); after an `llm_response` with `end_turn` it polls `session.get` on the socket in case the ephemeral was dropped (`:315-339`) |

`createLocalSession(conn, params)` (`:369-374`) sends `session.create` over the socket
itself — the path a local daemon or a directly-dialled worker takes; the bench uses it.
The GUI never does. There is no hash-chain verification anywhere in `src/`; only the
test fake's `SessionLog.verify()` checks it (`test/support/log.ts:61-71`; AUDIT §3.2).

### `attach.ts` — `SessionAttachment`

The policy that keeps one session's socket alive. See §5 below for the lifecycle.
`attachment.view` is stable across reconnections; `attachment.conn` is replaced
(`:40-45`). Options (`:20-34`): `open(mode)` and `mint()` are supplied by the caller
so this module never speaks to the plane itself; `backoffMs` defaults to
`[250, 500, 1000, 2000, 5000, 10000]` (`:38`); `mode` defaults to `read` (`:57`).

### `transcript.ts` — the fold

A pure function `fold(state, event)` (`:215-399`) plus helpers. See §6.

### `fleet.ts` — `FleetStore`

The union of every `FleetSource`, with the plane as the one source stage 1 has. See §7.

### `index.ts`

The public surface (`index.ts:1-30`): everything the desktop app and the bench import.
Anything not exported here is private to the package.

## 3. `apps/desktop/src`, module by module

| File | Responsibility | Protocol calls made |
|---|---|---|
| `main.tsx` (`:1-10`) | Mounts `<App/>` under `React.StrictMode`, imports `styles.css` | — |
| `App.tsx` | The rail and the screen switch. No router: `Where` is a local union `sessions | approvals | session{id}` (`:19`, `:23`). Shows `SignIn` until an `AuthSession` exists (`:32`); the rail shows session count, the amber "Waiting for you" count from `awaitingApproval` (`:34`, `:47-55`), the identity block from `auth.me` (`:58-63`), `ThemeToggle` and Sign out (`:64-67`) | none directly; `useFleet(auth)` (`:24`) |
| `hooks.ts` | React adapters over the client's stores; "nothing in here knows the protocol" (`:1-3`) | `useFleet` polls `sessions.list` through `PlaneSource` every 4 000 ms (`:18-33`); `useProfiles` calls `profiles.list` once per auth (`:35-52`); `useSessionView(auth, id, mode = "activate")` opens a `SessionAttachment` with `open` = `session.open` and `mint` = `token.mint` (`:91-95`), sends `presence.set viewing` on attach (`:107`), and exposes `send`, `respond`, `cancel`, `switchProfile`, `readBlob` (`:120-149`) |
| `shell.ts` | The whole contract with a desktop shell: `window.troupe` implementing `TroupeShell` (`:23-32`); `capabilities()` says where secrets live (`:52-66`); `tokenStore()` picks OS keychain → `localStorage` → memory (`:69-78`); `redirectUri()` = origin + `BASE_URL` without trailing slash (`:91-95`); `likelyPlaneUrl()` = the origin when `BASE_URL !== "/"` (`:105-109`); `prefs` over `localStorage` `troupe.pref.<key>` (`:112-127`). No shell implementation exists in this repository | — |
| `views/SignIn.tsx` | Plane URL input prefilled from `prefs.planeUrl` or `likelyPlaneUrl()` (`:26`); on load finishes a returning redirect or restores from the store (`:37-69`); on submit discovers, then redirects (PKCE, `prompt: select_account`) or runs the device grant (`:71-99`); explains registration errors (`:163-179`) | `discover`, then either `beginRedirectSignIn`/`completeRedirectSignIn` or `signIn`; `restore` |
| `views/Sessions.tsx` | Home: search plus state and profile filters over `filterRows` (`:34-46`), a "Waiting for you" group lifted above the rest by `statusOf` (`:43-44`, `:108-119`), and the `StartSession` dialog (`:171-293`) | `profiles.list` via `useProfiles` (`:172`); `session.create` with `profile`, optional `agent`, `title`, `prompt` (`:189-194`) |
| `views/Session.tsx` | One session: header with profile switch (`:87-149`), banners (`:158-204`), the stream (`:206-260`), collapsed tool activity (`:324-345`), `LargeResult` fetching a blob only on click (`:352-382`), a small Markdown subset (`:388-449`), sticky `ApprovalPanel`s (`:64-72`), `Composer` (`:523-583`) or `ReadOnly` (`:586-593`), and the backstage with Tasks, Files, sub-agent states and facts (`:451-521`) | Through `useSessionView`: `session.open` (mode `activate`, the hook's default), `token.mint`, `subscribe`, `input.send`, `approval.respond`, `turn.cancel`, `profile.switch`, `presence.set`, `blob.get` |
| `views/Approval.tsx` | The approval panel and the decision record. Headline, consequence and scoped label are chosen by a regex over the tool name (`:21-44`); `A`/`D` answer when focus is not in a field (`:94-106`); an answered panel stays and names who decided (`:122-137`) | none; calls `onAnswer` |
| `views/Approvals.tsx` | The inbox: rows from `awaitingApproval(rows)` — one `sessions.list`, no replay (`:28`, `:3-6`); each row opens its session in `read` mode while on screen (`:72-92`) | `session.open` mode `read`, `token.mint`, `subscribe`, `approval.respond` |
| `views/Files.tsx` | Read-only tree and viewer; relists on `fs_changed` via `view.listen` (`:42-47`) | `fs.list`, `fs.read` |
| `views/bits.tsx` | `Pill` (glyph and word), `statusOf` precedence waiting > readonly > error > running > dormant > queued, `Where`, `Cost` (micros → dollars), `When`, `personColour` (the reserved colour excluded), `Loading` | — |
| `views/brand.tsx` | `Mask` and `Wordmark` drawn from the generated `mark.ts`; `Eye`, the mask's eye as the status glyph — one outline per state, so greyscale still reads | — |
| `views/Appearance.tsx` | The theme screen, on first sign-in and in Settings: three cards, each a live preview in its own theme, plus the light/dark control | — |
| `theme.ts` | Which theme and mode this person reads in; writes `data-theme` and `data-mode` on the document root and `troupe.pref.*`. The only module that knows where the preference lives (`DECISIONS.md` #39) | — |
| `styles.css` | The stylesheet, on `DESIGN.md`; imports the Plex faces (`:16-20`) | — |
| `tokens.css` | **Generated** from `docs/design/themes/*.tokens.json` by `scripts/tokens.ts`; three themes in light and dark, do not edit (`tokens.css:1-3`) | — |
| `mark.ts` | **Generated** from the same files: the mask's geometry, so the brand is drawn from the design system rather than retyped | — |

## 4. The sign-in flows

Two flows, chosen by the host (`auth.ts:184-196`, `DECISIONS.md` #20-21):

| | Authorization code + PKCE | Device grant |
|---|---|---|
| Chosen when | `location.href` is a string and `crypto.subtle` exists — every browser build (`auth.ts:193-196`, `SignIn.tsx:81`) | Anything else: Node, the test harness (`test/support/harness.ts:44`), a future shell without a redirect |
| Why | Microsoft Entra sends no CORS headers on its `devicecode` endpoint (`pkce.ts:4-8`, `REPORT.md:152-158`) | The right flow for a terminal or shell |
| Endpoints | Authorize endpoint from the plane's discovery if published, else the provider's `openid-configuration` (`pkce.ts:73-87`); token endpoint from discovery | `device_authorization_endpoint` and `token_endpoint` from discovery (`plane.ts:226-275`) |
| Redirect URI | `redirectUri()` = origin + base path, no trailing slash (`shell.ts:91-95`); must be registered as a single-page-application redirect (`SignIn.tsx:172-175`) | none |
| Transient state | `sessionStorage` `troupe.auth.pending` (`pkce.ts:115`) | in memory |
| Finish | `completeRedirectSignIn()` on the next load (`SignIn.tsx:48-52`) | `pollDeviceFlow` resolves |

Both end in `adopt`: persist the refresh token, `POST /auth/exchange`, hold the plane
token in memory (`auth.ts:290-299`).

Where tokens live:

| Token | Lifetime | Where | Citation |
|---|---|---|---|
| IdP refresh token | provider-defined; rotated on use | `localStorage` `troupe.auth.refresh:<planeUrl>` in a browser; a shell's `secretStore` if one exists; memory otherwise | `auth.ts:40-64`, `shell.ts:69-78` |
| Plane token | ≤ 15 min (server; `PROTOCOL.md`, server AUDIT §1.2) | `AuthSession.credential`, memory only; renewed 120 s before expiry | `auth.ts:153`, `:160`, `:273-281` |
| Pod token | per attachment; `expires_at` on the `Attachment` | `SessionAttachment.attachment`, memory only | `attach.ts:11`, `:49` |

Discrepancy: `spec.md:30` describes the browser sign-in as the device grant. The code
uses PKCE in browsers; the device grant remains for other hosts (AUDIT §2).

## 5. The attachment lifecycle

`SessionAttachment` (`packages/client/src/attach.ts`):

1. **Open.** `SessionAttachment.open(opts)` → `connect()` (`:92-118`): call the
   caller's `open(mode)` — in the GUI that is `auth.rpc("session.open", {session_id,
   mode})` (`hooks.ts:94`) — and fail if the plane returned no token (`:95`).
2. **Dial.** `TroupeConnection.open` to `normalizeEndpoint(attachment.endpoint)` with
   the pod token, which sends `initialize` (`:98-112`).
3. **Subscribe.** `view.bind(conn)` then `view.subscribe()` from the view's cursor
   (`:115-116`); status `live` (`:117`). First time, the cursor is 0 and the whole log
   replays.
4. **`auth.expiring`.** `refresh()` (`:121-135`): caller's `mint()` — `token.mint` on
   the plane (`hooks.ts:95`) — then `conn.refreshAuth(token)` = `auth.refresh` on the
   same socket. No reconnect. A failed refresh is reported as a detail on `live`, and
   the eventual close triggers the reconnect (`:130-134`).
5. **`resync_required`.** `view.resubscribe()` from the cursor; if that throws,
   reconnect (`:108`).
6. **Close.** `reconnect(reason)` (`:137-158`): `conn = null`, `view.unbind()`, then
   for each wait in `backoffMs` set status `reconnecting`, sleep, and try `connect()`
   again (which repeats `session.open`, `initialize` and `subscribe` from the cursor).
   After the list is exhausted, status `failed`.
7. **`close()`** (`:76-85`): `unsubscribe`, close the socket, status `closed`.

While reconnecting the view is unbound and `view.send` throws
(`session.ts:64-67`). Discrepancy: the composer's hint says "What you send is held and
goes when the connection comes back" (`Session.tsx:576`) and the banner says "anything
you type now is sent when it comes back" (`Session.tsx:186-187`); the code restores the
draft with an error instead (`Session.tsx:534-536`; AUDIT §2).

Mode: `hooks.ts:76` defaults to `activate`, so opening a session from the list uses
`session.open` with `mode: "activate"`; the inbox passes `read` (`Approvals.tsx:76`).
Discrepancy: the dormant banner says "Reading it does not wake it"
(`Session.tsx:175`); AUDIT §2 and §4.3.

## 6. The fold (`transcript.ts`)

`fold(state, e)` is pure: the same events in the same order produce the same
`TranscriptState` (`transcript.ts:1-7`, tested in `test/transcript.test.ts:48-70`).
Duplicate and out-of-order suppression is `SessionView.handle`'s job, not the fold's
(`transcript.ts:209-214`).

`TranscriptState` (`:71-92`): `entries`, `streaming`, `thinking`, `agentState` keyed by
sub-agent path (`""` is root), `pending`, `todo`, `presence`, `profile`,
`bundleVersion`, `lastSeq`, `error`, `doneReason`, `costMicros`.

Durable events (`:222-398`):

| Event | Effect |
|---|---|
| `input_queued` | marks the matching pending input `queued` (`:223-230`) |
| `input_accepted` | removes the pending input with that `command_id` (`:233-236`) |
| `user_input` | appends a `user` entry with `author = actor.subject` (`:238-245`) |
| `llm_response` | appends an `assistant` entry if the message has text; clears root `streaming`/`thinking`; clears `error`; adds `gateway.cost_micros` to `costMicros` (`:247-266`) |
| `tool_call_started` / `tool_call_completed` | appends a `tool` entry, then fills `ok` and `content` (string or `BlobRef`) (`:268-293`) |
| `delegation_started` | `delegation` entry (`:295-308`) |
| `approval_requested` / `approval_decided` / `approval_resolved` | `approval` entry; then `decision`; then `resolvedBy` (`:310-346`) |
| `todo_updated` | replaces `todo` and appends a `todo` entry (`:348-355`) |
| `session_created`, `agent_started`, `profile_switched`, `agent_done`, `llm_error` | set `profile`/`bundleVersion`/`doneReason`/`error` and append a `system` entry (`:357-393`) |
| other types in `SYSTEM_TYPES` (`:179-197`) | `system` entry with `systemText` (`:138-177`) |
| anything else | only `lastSeq` moves (`:395-396`) |

Ephemerals (`:401-418`): root `llm_delta` appends to `streaming` or `thinking`;
`agent_state` updates `agentState[path]`; `presence` replaces `presence`. A sub-agent's
deltas are not painted (`:404`).

Optimistic sends: `addPending`/`dropPending` (`:200-207`) keep an input in `pending`
until `input_accepted` names its command id; it renders below the stream as
"Sending"/"Queued", never inside it (`Session.tsx:246-255`, `DECISIONS.md` #11).

Helpers: `rootState`, `isBusy` (`thinking|acting|compacting|busy`), `openApprovals`
(`:421-433`).

## 7. The fleet store (`fleet.ts`)

- `FleetSource` is anything with `id`, `kind` and `list()` (`:46-50`). `PlaneSource`
  calls `sessions.list` with a plane token and maps rows with `rowFromPlane`
  (`:84-99`); every row it produces has `kind: "team"`.
- `FleetStore.poll(ms = 5000)` refreshes immediately and then on an interval
  (`:190-195`). The app passes 4 000 (`hooks.ts:18`, `:25`). Discrepancy: the
  default and the app disagree; `DECISIONS.md` #4 and `REPORT.md:292` say four seconds
  (AUDIT §2, §4.5).
- **Merge rules** (`:218-233`): sources are folded in the order `team`, `local`,
  `private`; a later row with the same id overwrites the earlier one field by field and
  keeps its own `raw`, so a daemon's copy wins over the plane's. Sorted pinned first,
  then most recent `lastActiveAt`, then id (`:242-248`).
- **A failing source keeps its last rows** and records the error under
  `snapshot.sources[id].error` (`:170-187`); the list never empties because a token
  expired. `Sessions.tsx:82-87` shows it as a banner.
- `patch(id, partial)` (`:206-216`) applies live news without a round trip; nothing
  calls it yet (`REPORT.md:294-295`).
- `filterRows`, `awaitingApproval` (rows with `pendingApprovals > 0`),
  `totalCostMicros` (`:250-270`).

## Related

- [tech-stack.md](tech-stack.md) — the toolchain each package declares.
- [testing.md](testing.md) — what the 33 tests prove about the modules above.
- [conventions.md](conventions.md) — where a new protocol method or view goes.
- [../user/features.md](../user/features.md) — the same modules from the person's side.
- Server: [docs/AUDIT.md](../../../../docs/AUDIT.md) and
  [PROTOCOL.md](../../../../PROTOCOL.md) in the `troupe-remote` repository.
