# Report

## Stage 1 — the shell, team sessions, and sign-in

Built: the protocol client's auth, fold, attachment and fleet layers; the desktop app's
sign-in, sessions list, session, files and approvals screens, on the design system in
`docs/design/`; and a fake deployment that the tests and the demo both run against.

Not built: stages 2, 3 and 4. Each needs server work in `../troupe-remote` first — the
daemon's loopback WebSocket for stage 2, the sealer move and the plane's private-session
methods for stage 3 — and the spec says a stage is not started until the previous one is
green. Stage 4's Review and admin screens need no server change and are the cheapest to
do next.

### What proves each done item

Everything below is `pnpm test` in `packages/client`. Each done item is one `describe`
block in `test/stage1.test.ts`, named after it.

```bash
pnpm --filter @troupe/client test
```

```
▶ stage 1, done item 1: sign in, list, create, prompt, and stay signed in
  ✔ goes from a clean profile to a streamed answer, and a relaunch needs no sign-in
▶ stage 1, done item 2: a plane that does not know this origin says so
  ✔ names the exact origin to add, and adding it makes the same build work
▶ stage 1, done item 3: two clients on one session agree
  ✔ shows the same order and the same authors, and every optimistic send reconciles
▶ stage 1, done item 4: the approvals inbox
  ✔ lists approvals from three sessions with none of them open, and the first answer wins
▶ stage 1, done item 5: a pod token running out
  ✔ mints and refreshes on the open socket without interrupting a turn
  ✔ reconnects from its cursor with no gap and no duplicate when refresh is disabled
▶ stage 1, done item 6: a large tool result
  ✔ is a reference on load and is fetched by range only when expanded
▶ the fleet store         (6 tests)
▶ the transcript fold     (7 tests)
ℹ tests 20
ℹ pass 20
ℹ fail 0
ℹ duration_ms 8405.4328
```

Item by item, and what the assertion actually is:

1. **Sign in, list, create, prompt, stream.** A clean store, a provider that answers
   `slow_down` on the first poll and rotates its refresh token, the code shown and
   approved on a timer. Asserts the rotated token is the one persisted, that
   `profiles.list` answered with the agents and skills *before* anything was created,
   that `session.create` with `agent: "plan"` was accepted, that the answer arrived in
   deltas, and that a second `AuthSession` over the same store signs in with no
   interaction — if it had fallen back to the device grant the test would hang, because
   nothing would approve it.
2. **The origin message.** Run through `browserFetch`, which applies a browser's
   same-origin policy to Node's `fetch` (decision 9). With the origin off the allowlist
   the message names it and the variable to add it to; adding it makes the same client,
   the same store and the same fetch work with nothing else changed.
3. **Two clients.** 100 inputs, 50 from each of two people on two sockets. Asserts both
   transcripts are identical in seq, author and text; that both authors appear; and that
   no pending send is left unreconciled on either side.
4. **The approvals inbox.** Three sessions stopped on approvals and then *closed* — the
   test waits for the worker's connection count to reach zero before building the
   inbox, so "without any of them open" is checked rather than assumed. Answering from
   the inbox continues the turn; a second answer from another person sees
   `approval_resolved`, does not run the turn again, and does not change the decision.
5. **Token expiry.** With a warning: `auth.refresh` happens mid-turn, the turn finishes,
   the pod saw exactly one `initialize`, and the token in hand changed. With the warning
   suppressed: the socket closes on `exp`, the view reconnects, and the seqs it processed
   across the boundary are exactly `1..n` — in order, no duplicate, nothing missing.
6. **A large result.** A 240 KB tool result arrives as a reference with a 4 KiB preview;
   `blob.get` has been called zero times after the transcript loads. Expanding it fetches
   by range and loops, because the server caps each answer at 64 KiB and says so in the
   range it returns.

### Sign-in to first streamed token

```bash
pnpm first-token
```

```
  20 runs, cumulative from the moment "Sign in" is pressed

  milestone                   median       p95
  sign in                    117.3ms   132.9ms
  list sessions              118.2ms   134.7ms
  read the profiles          119.0ms   135.7ms
  create a session           119.7ms   136.8ms
  attach and subscribe       121.4ms   143.9ms
  first streamed token       130.5ms   152.6ms
  answer complete            151.0ms   168.9ms
```

Read this as a floor, not a forecast. Almost all of the 117ms before "sign in" completes
is the device grant's polling interval, which the fake sets to 100ms and a real provider
sets to five seconds — and which is anyway spent waiting for a person to type a code into
another window. What the client adds after that is the interesting number: **about 13ms
from a signed-in session to the first token on screen**, covering `sessions.list`,
`profiles.list`, `session.create`, dialling the worker, `initialize`, `subscribe`, and
the replay. A real deployment adds the plane's placement and budget reservations, a pod
cold start where there is one, and the model's own time to first token.

### The browser build and the shell

The GUI is one web bundle. `apps/desktop/src/shell.ts` is the whole contract between it
and anything wrapping it, and the views ask what is available rather than branching on
which they are.

| | Browser build | Desktop shell (not built yet) |
| --- | --- | --- |
| Team sessions on a plane | yes | yes |
| Where the refresh token lives | this browser's `localStorage`, readable by any script on the origin — and the connect screen says so | the OS credential store |
| Sessions on this computer (stage 2) | only if told the daemon's port and token by hand | finds `daemon.json`, starts the daemon on demand |
| Private sessions (stage 3) | no — they run in the daemon | yes |
| Choosing a workspace directory | a path typed in | a directory picker |
| Needs an origin on the plane's allowlist | yes, and on the identity provider's too | yes — `tauri://localhost` or equivalent |

**Tauri versus Electron is not yet decided and does not need to be.** Nothing in stage 1
depends on it: the two capabilities a shell adds are a `TokenStore` and a `findDaemon`,
both of which either implementation can provide in well under a hundred lines. The
decision belongs with stage 2, where the daemon-spawning behaviour is actually written,
and should be made on distribution size and code-signing, not on API surface. The browser
build works today and says on its connect screen exactly what it cannot do.

### Changes made in `../troupe-remote`

`PROTOCOL.md` only. `fs.list`, `fs.read` and `fs.upload` existed in the gateway and in
the schema but appeared in neither the method list nor the scope table, so a client
author working from PROTOCOL.md — which is the document's whole purpose — would have had
to read Elixir to find the file API. The scope table was also missing `presence.set` and
`tools.unregister`. Both now match `apps/troupe_gateway/lib/troupe/gateway/dispatch.ex`.
No server behaviour changed.

### Against the live plane, troupe.itmindsinternal.dk

Run on 2026-09-13 against the small production plane on Scaleway Kapsule.

**What was found, in the order it was found.**

1. **The plane and its workers answered no browser.** `plane.corsOrigins` and
   `operator.workerAllowedOrigins` were both `[]`. Fixed in
   `.local/scaleway/values.itminds.yaml` and deployed as Helm revision 9; both
   deployments now carry `http://localhost:5173`. Verified from the cluster:

   ```
   {"name":"TROUPE_CORS_ORIGINS","value":"http://localhost:5173"}
   {"name":"TROUPE_WORKER_ALLOWED_ORIGINS","value":"http://localhost:5173"}
   ```

2. **Entra will not let a browser use the device grant.** Measured from a real page
   against the real tenant: the `devicecode` endpoint sends no cross-origin headers, so
   the request is refused before it leaves and the page is told only `TypeError: Failed
   to fetch`. The token endpoint, by contrast, answered cross-origin with a readable
   body. So the browser build now signs in with authorization code + PKCE, and the
   device grant remains for hosts that have no redirect to come back from. See
   DECISIONS 20–25; `packages/client/test/pkce.test.ts` covers it in 9 tests.

3. **The authorization endpoint was configured but never published.** The plane has
   `TROUPE_OIDC_AUTHORIZE_URL` set and `/.well-known/troupe` does not include it. The
   client reads the provider's own `/.well-known/openid-configuration` instead, which
   Entra answers cross-origin, and prefers the plane's value if one ever appears.
   Publishing it there is a one-line plane change worth making.

4. **Entra offered a personal Microsoft account.** The authority names one tenant, so a
   personal account cannot succeed — it fails after the password. The client now sends
   `domain_hint=organizations` for a tenant-scoped Microsoft issuer.

**Where it stands.** The GUI reaches Entra's sign-in form with a well-formed request:

```
authority             https://login.microsoftonline.com/9c5bd6eb-…/oauth2/v2.0/authorize
client_id             b18faeb7-ad28-4e80-bcd7-ec540c9b8c8e
redirect_uri          http://localhost:5173
response_type         code
code_challenge_method S256
domain_hint           organizations
scope                 openid profile email offline_access groups
```

Completing it needs a person's credentials, which this build was not given. It also
needs `http://localhost:5173` registered on app `b18faeb7-…` as a **single-page
application** redirect URI — not "Web", which issues no cross-origin token response.

**Still to check once somebody has signed in**, in this order: `/auth/exchange` returns
a plane token; `sessions.list` and `profiles.list` answer; `session.create` places a
session; the worker's `wss://` upgrade is accepted from the browser origin (this is what
`workerAllowedOrigins` was set for and the only part with no fallback); and a prompt
streams. The one to watch is the worker upgrade — it is the only hop whose allowlist has
never been exercised by anything.

5. **The plane asked for a scope that does not exist.** The loose end above was not a
   loose end: Entra refused the sign-in outright with `AADSTS650053: the application
   asked for scope 'groups' that doesn't exist on the resource`. `groups` was a
   hard-coded default in the plane's own router and `:scopes` was settable by nothing,
   so **every** sign-in against this tenant failed this way — the CLI's device grant
   included. Group membership is a claim the provider is configured to issue, named by
   `TROUPE_GROUPS_CLAIM`, not something a client asks for. Fixed in troupe-remote: the
   default is now the four OIDC scopes, `TROUPE_OIDC_SCOPES` overrides it, the chart
   exposes `plane.oidc.scopes`, and two tests in `web_test.exs` cover both. Deployed as
   plane `0.2.7`, Helm revision 11.

6. **A reused image tag deployed the old code, silently.** Pushing the fix as `0.2.6` —
   a tag that already existed — changed nothing: `imagePullPolicy: IfNotPresent` meant
   the node kept the image it had, and because the Deployment's spec did not change, no
   pod was even restarted. `helm upgrade` reported success and the running digest was
   still the old one. Caught by comparing the pod's `imageID` against the digest the push
   printed, which is the only thing that actually proves what is running. Republished as
   `0.2.7`; the running digest now matches. Worth a habit: never reuse a tag, and check
   the digest rather than the tag.

7. **A successful sign-in was reported as a failure.** With the scope fixed, signing in
   worked and the screen said `this sign-in did not start in this tab`. React's
   StrictMode double-invokes effects in development: the first run spent the verifier and
   awaited the provider, the second found the cupboard bare, and *its* error was the one
   rendered — the first run's success went to a closure StrictMode had already discarded.
   Redeeming a code is now idempotent (DECISIONS 28), covered by two tests and checked in
   a real browser by calling the completion twice concurrently: one token request, both
   callers given the same tokens.

**Where it stands now.** The live discovery document reads:

```json
{"scopes": ["openid", "profile", "email", "offline_access"]}
```

and the authorize request the GUI builds is clean:

```
scope        openid profile email offline_access
domain_hint  organizations
redirect_uri http://localhost:5173
```

### Deployed to the IT Minds cluster

The GUI runs on the same Kapsule cluster as the plane, as its own Helm release in
`troupe-system`, built from this repository and mutating nothing in troupe-remote.

```
https://troupe.itmindsinternal.dk/app
```

| | |
| --- | --- |
| Image | `rg.fr-par.scw.cloud/troupe/troupe-gui:0.1.1`, `sha256:ae03b5a9…` |
| Release | `troupe-gui`, revision 3, namespace `troupe-system` |
| Pods | 2, both ready, both on the digest above |
| Ingress | `troupe-gui` — host `troupe.itmindsinternal.dk`, path `/app(/|$)(.*)`, class nginx |
| Certificate | `troupe-plane-tls`, shared with the plane's Ingress; no second issuance |

Verified from a browser against the live host:

- the page renders, and both hashed assets answer 200 with `immutable` caching while
  `index.html` answers `no-cache`;
- a deep link (`/app/anything/deep`) falls back to the application rather than 404;
- `/.well-known/troupe` is reachable **same-origin** — no allowlist involved — and
  returns the corrected scopes;
- `/rpc` still reaches the plane (401 unauthenticated), so the two Ingresses on one host
  route as intended;
- the plane's URL is prefilled from the serving origin.

Sign-in is not yet exercised here: the redirect URI is now
`https://troupe.itmindsinternal.dk/app`, which has to be registered on the Entra
application as a single-page application redirect URI. That is the only thing standing
between this deployment and a working sign-in.

**Found while building it:** a test that passed on Windows failed inside the image,
because the second client in the approvals test counted messages before its
subscription's replay had been folded — it read zero, then watched the first turn's
answer arrive, which is indistinguishable from the turn running twice. A race in the
test rather than in the product, and exactly what running the suite somewhere else is
for. The Dockerfile runs the suite on the way through for that reason.

### Known limitations

- **The live deployment is reached but not yet signed into.** See the section above:
  the plane answers the browser, the request to Entra is well formed, and what remains is
  a person completing a sign-in. Everything past `/auth/exchange` — listing, creating,
  dialling a worker pod, streaming — is still unproven against a real deployment.
- **The fakes are this repository's reading of PROTOCOL.md.** They implement the
  protocol, not a screen — a real WebSocket, a hash-chained log, replay from a cursor
  with a closed boundary, token expiry and refresh, blob caps, first-answer-wins
  approvals — but a kind or Kapsule run is what would find the places
  where that reading is wrong, and `scripts/remote-up` needs kind, which is not on this
  machine. This is the largest gap in the work.
- **No Playwright.** The spec asks for browser tests in CI. The screens were driven by
  hand in a real browser — which is how two bugs were found (DECISIONS 6 and 10) — but
  that is not a test that runs again tomorrow. There is also no CI configuration in this
  repository yet.
- **The plane is polled every four seconds.** A session's own screen is live from its
  worker socket, but a list left open lags by up to four seconds. See DECISIONS 4.
- **The fleet's `patch` is not wired to a summary subscription.** The mechanism is there
  and tested; nothing calls it yet, because stage 1 opens one session at a time.
- **Presence is displayed but never announced.** `presence.set` is sent on attach; the
  header renders whatever `presence` ephemerals arrive. The fake worker does not emit
  them, so that path has been written and not exercised.
- **Markdown is a small subset**: headings, lists, fenced code, inline code and links.
  Tables, blockquotes and emphasis are not rendered. Diffs are not rendered as diffs yet
  — the design specifies hunks with a marker per line, and approvals currently show a
  command or a path but fall back to JSON for anything else.
- **`todo.edit`, `session.grant`, `session.pin` and `session.review`** are in the client
  and reachable from no screen.
- **Dormant and read-only are rendered from the plane's row**, so a session that goes
  dormant while open does not show its banner until the next poll.
- **No keyboard shortcut beyond the approval's `A` and `D`.** No command palette, no
  focus management between screens beyond DOM order.
- **Two tests are timing-shaped.** Done item 5 is about a token running out, so it has
  to wait for real clocks. Both halves were widened after one failure in fourteen runs
  under load — the refresh now has eighteen seconds of headroom rather than six, and the
  send after a reconnect retries while the socket is between lives — and the suite has
  since run twenty times clean. They remain the two worth suspecting first if CI ever
  goes red without a code change.
- **Accessibility is designed for but not audited.** Focus rings, live regions, 44px
  targets, status-plus-word and the 380px floor are all implemented; none of it has been
  through a screen reader.
