# Report

## Stage 1 — the shell, team sessions, and sign-in

Built: the protocol client's auth, fold, attachment and fleet layers; the desktop app's
sign-in, sessions list, session, files and approvals screens, on the design system in
`docs/design/`; and a fake deployment that the tests and the demo both run against.

Stages 2 and 4 have since been built; stage 3 has not. See **Stage 2** and **Stage 4**
below for what each one is and what proves it, and **Stage 3** for what it needs and why
none of it is pretended at in the screens.

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

---

## Stage 2 — sessions on this computer

Built: a `DaemonClient` that multiplexes every open session over the daemon's one socket,
a `DaemonSource` that puts them in the same list as the team's, a **This computer** screen
for the machine-level things, the local half of **Start a session**, watch mode on a local
session's backstage, worktree listing and removal, and the two capabilities a desktop
shell adds — finding the daemon and picking a directory.

### What the server needed, and where it is

Two things, both in
[it-minds/troupe-remote#2](https://github.com/it-minds/troupe-remote/pull/2):

1. **A door a browser can use.** A browser cannot open a Unix socket, cannot open a raw
   TCP socket, and cannot be told to speak NDJSON over one — so every transport the daemon
   served was unreachable from a page. The daemon now also binds `Gateway.Web` to
   `127.0.0.1` on a kernel-chosen port and publishes it as a `ws` entry beside the primary
   transport in `daemon.json`. It is the same server a pod runs, with `Gateway.Connection`
   behind the upgrade: one line of configuration rather than a second implementation.
2. **`identity.link`.** A daemon knows the operating system's user and calls them
   `local:<username>`, which means nothing anywhere else. Linking records the subject the
   identity provider issued, so every actor in every log is that person and
   `session_created` carries an `owner`. It verifies nothing and is not meant to — the
   trust boundary is the file mode on the socket, and this is a label applied by somebody
   already admitted.

### One socket, several sessions

A worker pod is one session per socket, because the plane mints a token whose audience is
that pod and that session. A daemon is the opposite: one token admits everything on the
machine, and every session it holds is reachable over the connection that is already
open. `DaemonClient` is therefore a multiplexer — one `TroupeConnection`, a `SessionView`
per open session, and an envelope offered to each view until one claims it, which is the
same routing `SessionView.handle` already did with one candidate.

Nothing else about the protocol changes, and that is the point. `subscribe` replays the
same way, a command is an acknowledgement rather than an effect the same way, and `fold`
is the same function. `useSessionView` takes the session's kind and picks the socket; every
screen above it — the transcript, the approvals, the composer, the file pane — is unchanged
and does not know which it is looking at.

### What proves each done item

```bash
pnpm --filter @troupe/client test
```

```
▶ stage 2, done item 2: one list, two kinds, each labelled
  ✔ merges the daemon's sessions with a plane's, and the kind survives the merge
  ✔ keeps the local sessions when the plane stops answering
  ✔ reports a daemon's whole-unit cost as micros, the way the plane reports it
▶ stage 2: several sessions on one socket
  ✔ routes each session's events to its own view, and opens the socket exactly once
  ✔ closing one session leaves the other's socket alone
▶ stage 2, done item 3: who the daemon records
  ✔ goes from the machine's login to the person, and back
  ✔ refuses to link nobody
▶ stage 2: the commands only a local session has
  ✔ creates a session in a directory, and watch mode follows the workspace
  ✔ a daemon that cannot seal does not claim it can
ℹ tests 49
ℹ pass 49
ℹ fail 0
```

`test/support/daemon.ts` is a daemon rather than a mock: a real WebSocket, a token out of
a file, a hash-chained log per session, a replay closed before anything live is sent, and
an actor that changes when an identity is linked. It exists because a fake that agrees
with the client by construction proves nothing.

**Done items 1 and 5 are proved in the server's repository**, because they are statements
about the daemon rather than about a client. `Troupe.Gateway.LoopbackTest` covers the `ws`
entry, the token, the refused origin and the actor after `identity.link` — six tests,
`Result: 6 passed`.

### Done item 5 is not built: client-hosted MCP servers

The spec asks for the shell to read the person's `mcp.json` and offer each server per
session behind the consent challenge. The protocol half is here — `tools.register` and
`tools.unregister` are on `DaemonClient`, the connection serves `tool.invoke` when
something is hosting one, and the daemon answers an unconsented registration with a fresh
challenge. What is absent is the shell half: reading `mcp.json`, spawning a stdio MCP
server, and speaking MCP to it. That is a process manager and a second protocol inside the
desktop shell, and it is not started. No screen offers it, so nothing here suggests it
works.

### Known limitations

- **The app still requires a plane.** Sign-in is the gate, so a person with only a daemon
  cannot get past it. Nothing in the local path depends on the plane once past it, but the
  spec's "one list" reads better if a local-only launch is possible, and it is not yet.
- **Watch mode is toggled from the session, not from the workspace.** The protocol is
  workspace-scoped and exclusive per workspace, so a second session's toggle is refused
  with the server's sentence rather than being greyed out with the reason. Correct, but the
  control could say it before it is pressed.
- **The daemon's `fleet` topic is not subscribed.** The list is polled on the same cadence
  as the plane's. Live for one half and four seconds stale for the other would be worse
  than honestly the same age throughout, but the mechanism is there and unused.
- **`daemon_start` names `troupe` on the path.** A shell that cannot find it says so and
  suggests running `troupe daemon` by hand; it does not go looking in the places an
  installer might have put it.

---

## Stage 3 — private sessions: not built

Nothing on any screen claims otherwise, and that is deliberate. The **Keep it private**
control appears only when the daemon's own `initialize` reports `private_sessions`, which
no daemon does yet — a checkbox for something the server has never heard of reads as a
setting that did not take, which is worse than no checkbox.

What is ready: `FleetRow` carries `kind: "private"` and a `sync` state; the store merges a
private session's two rows with the daemon's copy winning; the list renders **Synced**,
**Syncing**, **Here only** and **Conflict**, the last naming the device that holds the copy
that counts; `rowFromDaemon` maps a private row; and the create dialog has the control
behind its capability gate.

What it needs, none of which is a client change:

* the worker's `Sealer` moved into `troupe_protocol` and used by the daemon for sessions
  created with `config.private`, writing segments, snapshots, workspace tars, blobs and a
  plaintext manifest under `sessions/<id>/`;
* a key path `troupe/people/<subject>/sessions/<id>` in OpenBao, with a JWT auth role
  bound to the identity provider's issuer and a policy templated on the subject, no pod
  role able to read under `people/`, and the plane's delete-only policy widened;
* `session.register`, `session.seal-report` and `session.presign` on the plane, with the
  conditional epoch bump that fences two devices resuming at once;
* `session.erase` extended to destroy every object version under the prefix and the key's
  metadata.

That is a storage and key-management change across three components with real cryptography
in it, and it is not something to half-build behind a checkbox. It is the next thing, and
it is server work first.

---

## Stage 4 — review, fleet health, and administration

Built, and it needed no server change: every method it calls already existed on the plane.

**Review** is a queue over `sessions.list(origin: trigger | a2a, needs_review: true)`,
grouped by what fired each run and ordered by what went wrong — `budget_exhausted` and
`llm_error` first, then anything waiting on a person, then most recent. A row shows when it
fired and who fired it, how it ended, what it cost, the event that started it, and the two
actions somebody actually takes: answer what it is stuck on, and mark it reviewed. Nothing
replays a log — the plane's index already carries status, done reason, cost and how many
approvals are open, so a hundred unattended runs cost one request. A session is opened only
when somebody answers an approval on it, in `read` mode, over the same `InlineApprovals`
the inbox uses.

**Administration** is six panels over the `admin.*` methods and nothing else:

| panel | what it is |
| --- | --- |
| Fleet | profiles with their pods, capacity, conditions, versions and bundle adoption; drain a pod |
| Bundles | every version of a channel, one version in full with its adoption, publish and retire |
| Teams | spend against budget, grants, administrators, membership (read-only, always) |
| Automation | service principals and triggers, with each trigger's runs |
| Audit | who changed what, with the diff keyed by the path it changed |
| Settings | every platform setting with where its value came from, and the four identity checks |

Three rules run through all of it.

**The navigation is asked for, not inferred.** `platform_admin` is a claim, but the other
role — `team_admin` — is in no claim a client can read. So `admin.overview` is the probe: it
is the cheapest administrative read, it is scoped to whatever the caller administers, and a
person who administers nothing is refused. Refused is an answer, not an error, and the
navigation is simply not offered.

**One public method per action, and the audit row it produced is shown.** An admin screen
that says "saved" is asking to be believed; one that reads back the record it just wrote is
not. `AfterTheChange` does that after every write.

**Irreversible means typing the thing's own name.** Draining a pod, retiring a version,
revoking a grant, rotating a secret, disabling a principal, deleting a trigger — each asks
for the identifier, which is the same rule the platform applies to a model calling those
methods over MCP.

### The two that are about a specific promise

**Publishing.** Validate and publish are two questions and are two buttons. Validate asks
whether the document is publishable and changes nothing; publish makes it the current
version. Keeping them apart is what lets the plane's refusal — `invalid_params` with one
sentence per problem in `data.errors` — be rendered against the document rather than
against an action that already half-happened. After a successful publish the question stops
being "did it publish" and becomes "did it reach the pods", so adoption is polled every two
seconds until every pod on the channel reports the new hash.

**A secret is shown once.** `create` and `rotate` are the only answers that ever carry one,
and the listing has no such field. So it lives in one component's state for exactly as long
as the panel showing it is open, and the panel says plainly that the only way to see one
again is to rotate — which is a different secret.

### Known limitations

- **Not exercised against a real plane.** Every shape here was read from the plane's own
  `Admin.API` table and its `Admin` functions, which is the same source the CLI and the MCP
  tools are generated from — but no call has been made against a running plane, because
  nobody has completed a sign-in on the live deployment yet.
- **No tests.** The admin surface is a rename layer over methods the server tests already
  cover, and there is no fake plane in this repository that implements `admin.*`. That is
  the gap: a stubbed `AdminApi` would test the rename and nothing else, and a fake plane
  worth having is a day's work.
- **Profiles are read-only.** `admin.profile.put` and `admin.profile.delete` are in the
  client and reachable from no screen: a profile is a Kubernetes resource, editing one from
  a form means rendering a spec editor, and `admin.provisioning.mode` may mean the write
  becomes a commit for review rather than a change. It deserves its own screen.
- **Team membership and A2A runs.** Membership is read-only by design. A2A sessions appear
  in Review, but with no run behind them there is no event to show.
