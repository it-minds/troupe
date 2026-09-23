# troupe-gui

The graphical client for [Troupe](../../README.md), and the ground work every other
client will stand on. It lives at `clients/gui` in the Troupe repository, beside the
platform it talks to, and gets no private door into the server for it: it speaks
[`PROTOCOL.md`](../../PROTOCOL.md) over a WebSocket, the same as the TUI and the Python
reference client.

Three packages in one pnpm workspace:

| package | what |
| --- | --- |
| `packages/client` | `@troupe/client` — the protocol in TypeScript. JSON-RPC 2.0 over WebSocket, the plane's HTTP surface (discovery, device-grant login, `/auth/exchange`, `/rpc`), and a `SessionView` that folds events and turns "send a prompt, wait for the turn" into a promise. Runs in a browser or Node; no dependencies. |
| `packages/bench` | `@troupe/bench` — the throughput test. N clients, one session each, K prompts each, every milestone timed. |
| `apps/desktop` | The GUI. Vite + React, on the design system in [`docs/design/`](docs/design/DESIGN.md). Signs in through the plane (or, in local-only mode, talks to the daemon on this computer and nothing else), shows one list of every session — the team's on worker pods and the person's own on the daemon in front of them — streams a session, answers approvals, reviews what ran unattended, and administers the platform for whoever may. The bundle is plain web; the Tauri shell in [`src-tauri/`](apps/desktop/src-tauri) loads it unchanged and adds the things a browser cannot do — see [`src/shell.ts`](apps/desktop/src/shell.ts). |

## The path a client takes

```
GUI ── GET  /.well-known/troupe ──────────► plane          discovery, no auth
GUI ── POST device_authorization_endpoint ► identity provider
GUI ── POST token_endpoint (poll) ────────► identity provider   → id_token, refresh_token
GUI ── POST /auth/exchange {id_token} ────► plane          → plane token (≤ 15 min)
GUI ── POST /rpc  session.create ─────────► plane          → {endpoint, token(aud = pod), session_id}
GUI ── WS   wss://<pod>/v1/socket ────────► worker         initialize → subscribe → input.send → events
```

The plane is never in the data path of a live session. Only the last hop is a socket;
everything before it is ordinary HTTP. `PlaneClient` covers the first five lines and
`TroupeConnection` + `SessionView` the last.

Things the client library knows that the protocol document does not say loudly:

* One JSON-RPC message per text frame, no trailing newline, binary frames close the socket.
* `initialize` must be the first message; the token goes in `params.auth.token` because a
  browser cannot set the `Authorization` header on an upgrade.
* The acknowledgement of `input.send` is not the effect. The effect is the durable
  `input_accepted` event carrying your `command_id`.
* A text-only answer ends the turn with an *ephemeral* `agent_state` of `idle` and no
  durable marker. Ephemerals may be dropped under load, so `SessionView.prompt` also
  polls `session.get` once the model has answered with `end_turn`.
* Command ids are made unique across clients with a random prefix, not just per connection.
* `auth.expiring` arrives two minutes before the pod token expires; renew with `token.mint`
  on the plane and `auth.refresh` on the same socket — never by reconnecting.

## Run it

```sh
pnpm install
pnpm build                       # builds @troupe/client, typechecks the rest
pnpm dev:local                   # the GUI on this computer's daemon alone: no plane, no sign-in
```

### On this computer alone — the default way to develop

```sh
pnpm dev:local                   # then open the address Vite prints
pnpm dev:local --port 5185       # anything after the name goes to Vite
```

`pnpm dev:local` starts a daemon and the GUI in *local-only* mode against it: no plane,
no identity provider, no key, and nothing sent anywhere. The app opens on the session
list; start a session in the `demo` directory it prints, and the answers come from the
daemon's scripted `fake` provider reading `script.json` in the same place — one step per
model call, per agent under `routes` (`Troupe.LLM.Fake`), from the top for each new
session.

It needs `troupe-daemon` installed (`install.ps1`/`install.sh` at the repository root,
or `scripts/install-local.ps1` from a checkout); `TROUPE_DAEMON_BIN` names another. The
daemon it starts is a second instance of that install, with its own state, config and
`daemon.json` under `TROUPE_DEV_HOME` (a directory in the system's temp by default), so
it never touches the daemon you work with, its sessions or its keys. It stops by itself
ten minutes after the last client leaves, and the next `pnpm dev:local` starts it again.

The *Local only* switch is on *This computer*. Turning it off puts the sign-in screen
back, with "Use this computer only" as its third door; a stored plane sign-in survives
the round trip.

### Against a fake deployment, with nothing else installed

```sh
pnpm fake                        # an identity provider, a worker and a plane, on loopback
pnpm dev                         # then sign in to the plane URL `pnpm fake` printed
```

`pnpm fake` starts the same identity provider, plane and worker the test suite runs
against, seeded with three sessions, one of them stopped on an approval. Signing in needs
no clicking: a browser is sent to the provider and straight back as Alice, and a device
code approves itself. Three
prompt prefixes drive the scripted agent: `approve: <command>` asks for an approval,
`big: <label>` returns a tool result too large to inline, and `quiet: …` answers without
streaming. The plane answers `me.client_defaults` with an organisation gateway, so *Use
organisation defaults* on the models panel has something to fill in;
`NO_CLIENT_DEFAULTS=1 pnpm fake` is an organisation that has set nothing.

### Your own daemon beside the fake plane

The fake deployment has no daemon, and `pnpm dev:local` has no plane. To see both halves
of the one list — a team session and a session on this computer, with questions, the
budget question, streamed reasoning and the harness's notes — run the real
`troupe-daemon` with its scripted model, which is how its own smoke tests and the TUI's
client tests drive it:

```sh
# 1. the daemon: install it (install.sh / install.ps1 at the repository root; --no-tui
#    for the daemon alone) or build it in ../../apps/troupe_daemon with
#    `MIX_ENV=prod mix release troupe_daemon`
# 2. a workspace whose model is the script
mkdir -p ~/demo/.troupe && cat > ~/demo/.troupe/config.yaml <<'YAML'
provider: fake
fake_script: /home/you/demo/.troupe/script.json   # absolute: resolved by the daemon, not the workspace
model: fake-model
auto_approve: true
max_turns: 2          # so the budget question appears on the third turn
YAML
cat > ~/demo/.troupe/script.json <<'JSON'
{"routes": {"root": [
  {"reasoning": "Let me look first.", "text": "One question before I change anything.",
   "tools": [{"name": "ask_user", "input": {"question": "Formal or casual?",
             "options": [{"label": "formal"}, {"label": "casual"}]}}]},
  {"text": "Noted."},
  {"tools": [{"name": "finish", "input": {"summary": "done"}}]}
]}}
JSON
# 3. run it, and read where it listens
troupe-daemon run &
cat "${XDG_RUNTIME_DIR:-$HOME/.troupe/run}/troupe/daemon.json"   # %LOCALAPPDATA%\troupe\daemon.json on Windows
# 4. tell the browser build once, then the usual two
echo 'VITE_TROUPE_DAEMON=<ws.port>:<ws.token>' > apps/desktop/.env.local
pnpm fake && pnpm dev      # sign in to the fake plane; "This computer" is already connected
```

Then *New session* in `~/demo`. The desktop application skips step 4: it reads
`daemon.json` itself and starts `troupe-daemon run` when nothing is listening. Steps are
the daemon's `Troupe.LLM.Fake` script: `text`, `tools`, `reasoning`, `stop`
(`max_tokens` / `refusal`) and `error`, one step per model call, per agent under `routes`.

### Against a real deployment

Two allowlists, not one:

* the plane's `TROUPE_CORS_ORIGINS` must contain the GUI's origin — `http://localhost:5173`
  in development, or the origin it is served from;
* **the identity provider must allow that origin too.** The device grant is spoken to the
  provider directly, so a deployment that adds the GUI to the plane and stops there signs
  in as far as discovery and then fails. In Dex this is the public client's
  `redirectURIs`/allowed origins; in Authentik it is the application's allowed origins.

A browser cannot tell a page *why* a cross-origin request failed, so the GUI says both
possibilities and names the origin to add. It is not guessing at the cause; it cannot
know it.

## Testing

```sh
pnpm test                        # the client's 77 and the app's 4, below
pnpm first-token                 # sign-in to first streamed token, against the fakes
pnpm tokens:check                # fails if the generated design tokens are stale
```

The client's tests cover stage 1 and 2's done items, PKCE, the fold, the fleet store and
model settings, on Node's runner. The app's, in `apps/desktop/test`, render the app
itself in jsdom under Vitest against the fake daemon on a real socket, and record every
request the page makes: in local-only mode, with a plane sign-in stored and every screen
visited, the daemon is the only thing it talks to. They also walk the third door,
switch local-only off and on without losing the stored sign-in, and fall back to this
computer when the plane does not answer.

`packages/client/test/support` is a deployment that implements the protocol rather than
imitating a screen: a real WebSocket, a hash-chained log, replay from a cursor with a
closed boundary, a device grant that answers `slow_down` and rotates its refresh token,
token expiry with `auth.expiring` and `auth.refresh`, blob range caps, and approvals
where the first answer wins. `browserFetch` puts a browser's same-origin policy in front
of Node's `fetch`, so the CORS behaviour is tested here rather than assumed. `daemon.ts`
is the other half: one token for the whole machine, several sessions live on one socket,
directories it owns, an actor that changes when an identity is linked, and model settings
it keeps without ever answering with the key.

What none of it proves is the *server's* half. [docs/e2e.md](docs/e2e.md) has the suites
that run against a real plane and a real worker; CI runs the plane suite against a plane
built from the same commit.

## Shipping it

The GUI is one static bundle behind nginx. There is no server here — it is a protocol
client, so what ships is HTML, CSS and JavaScript, and every call goes from the browser
to the plane or to a worker. Nothing in the image holds a secret or needs telling
anything at runtime.

It ships with the platform, not as a release of its own. The image is built from this
directory alone, with it as the whole Docker context:

```sh
docker build --build-arg TROUPE_GUI_BASE=app -t troupe-gui .
```

and the platform's chart, [`charts/troupe`](../../charts/troupe), serves it: its `gui:`
block, on by default, is a Deployment, a Service, a NetworkPolicy and an Ingress at
`gui.basePath` on the plane's own host (root Decision 670). There is no chart and no Helm
release of the GUI's own; a team that uses another client sets `gui.enabled: false` and
points `plane.appUrl` at it.

CI is the root [`ci.yml`](../../.github/workflows/ci.yml): its `gui` job typechecks, tests
and builds this workspace, `gui-e2e` runs the client against a plane built from the same
commit, and `images` builds and pushes `troupe-gui` beside the server images on every
push to `main`, tagged `sha-<short>`. **A release deploys itself** (root Decision 669):
`scripts/release <version>` opens a pull request that changes `VERSION`, and merging it
promotes the images — this one included — to that version, attaches the desktop
installers the root [`release.yml`](../../.github/workflows/release.yml) builds, and rolls
the whole chart onto production with the root [`scripts/deploy`](../../scripts/deploy).
A push to `main` that does not change `VERSION` deploys nothing. See the root README's
[Releasing and deploying](../../README.md#releasing-and-deploying).

### Where it is mounted

`TROUPE_GUI_BASE` is baked in at build time, because Vite writes it into every asset
URL — an image built for `/app/` cannot be served at `/`. The chart's `gui.basePath` must
match it (CI builds with the repository variable `GUI_BASE`, default `app`); the Ingress
strips the prefix so the container stays ignorant of where it is.

**Serving the GUI at a path on the plane's own host is worth preferring**, and it is the
shape the chart gives it. Same origin means no CORS allowlist to keep in step, no second
DNS record, no second certificate, and a sign-in whose redirect URI is the address people
already have. The plane's Ingress owns `/`, the GUI's owns `/app`, and nginx routes the
more specific path. The GUI's Ingress uses the plane's `tlsSecretName` and asks
cert-manager for nothing — two Ingresses on one host share one certificate — and the
chart refuses `gui.basePath: /`, because the root of that host is the plane's.

### Check the digest, not the tag

A tag that already exists in the registry plus `imagePullPolicy: IfNotPresent` means the
node keeps the image it has — and since the Deployment's spec did not change, no pod is
restarted. `helm upgrade` reports success and the old code carries on serving. This is
not hypothetical; it happened on this cluster. The root `scripts/deploy` prints every
pod's running digest for that reason, and CI never publishes a floating tag.

## Design

[`docs/design/DESIGN.md`](docs/design/DESIGN.md) is the system,
[`docs/design/themes/`](docs/design/themes/THEMES.md) is it as data — three themes from
one token contract — and `example.dc.html` is every surface in one file.
`apps/desktop/src/tokens.css` and `apps/desktop/src/mark.ts` are **generated** from
`docs/design/themes/*.tokens.json` by `pnpm tokens` and committed; do not edit them.

Three rules carry most of the weight, and a change that breaks one of them is a bug:

* **The reserved colour is a job, not a mood.** `--waiting-*` marks work that has stopped
  and needs a person. Nothing else in the product may use it — not branding, not links,
  not warnings. Which hue it is depends on the theme; what it means never does.
* **Structure comes from hairlines and alignment**, not from cards, shadows or gradients.
* **A status is a glyph *and* a word.** Colour is never the only carrier of meaning.

**Themes.** Signal (the default), Footlight and Limelight, each in light and dark. A
person picks one on first sign-in and can change it in Appearance; it is `data-theme`
and `data-mode` on the document root and nothing else. Every theme exposes exactly the
same token names — a component reads `--waiting-solid` and never a hex, and never
branches on a theme. A theme that needs a new token name is a redesign, not a theme, and
`pnpm tokens` refuses to build one.

## The throughput test

A worker with no plane, no object store and the scripted `fake` model is the right
thing to measure a *client* against: the path from a frame to the session actor and
back, without a model's latency in the way. It runs as one Docker container:

```sh
# an ES256 key pair and its JWKS (packages/bench/src/devToken.ts mints the tokens)
node -e '...'                    # see docs/bench.md for the full incantation
docker run -d --name troupe-bench-worker -p 4000:4000 \
  -v "$PWD/keys:/etc/troupe:ro" --tmpfs /workspace:uid=1000,gid=1000 \
  -e TROUPE_WORKER_AUTOSTART=true -e TROUPE_PROFILE=bench -e TROUPE_POD_ORDINAL=bench-0 \
  -e TROUPE_JWKS_PATH=/etc/troupe/jwks.json -e TROUPE_PROVIDER=fake -e TROUPE_MODEL=fake \
  -e TROUPE_FAKE_SCRIPT=/etc/troupe/fake.json -e TROUPE_STATE_HOME=/workspace/.state \
  -e TROUPE_SESSIONS_PER_POD=64 -e RELEASE_DISTRIBUTION=none -e ERL_FLAGS="+Q 65536" \
  ghcr.io/objective-mj/troupe-worker:dev

BENCH_SIGNING_KEY=keys/signing-key.json BENCH_POD_ID=bench-0 \
BENCH_CLIENTS=20 BENCH_PROMPTS=10 pnpm bench
```

Each client opens its own socket and its own session (five clients on one session
would measure the model's serialisation, not the transport) and sends its prompts
one at a time. Every prompt is timed from just before `input.send` to the ack,
`input_accepted`, the first `llm_delta`, the durable `llm_response` and the end of
the turn. Results are printed and written as JSON under `bench-results/`.

Measured on 2026-09-12, Docker Desktop on a Windows laptop, worker image built from
`troupe-remote@2f85e39`, fake model:

| clients × prompts | connect+init p50 | input_accepted p50 / p95 | llm_response p50 / p95 | turn end p50 / p95 | turns/s |
| --- | --- | --- | --- | --- | --- |
| 5 × 20 | 13 ms | 0.6 / 1.3 ms | 1.1 / 3.7 ms | 1.3 / 9.1 ms | ~900 |
| 20 × 10 | 44 ms | 0.9 / 2.1 ms | 3.7 / 5.6 ms | 4.1 / 7.2 ms | ~1000 |

All 300 turns completed; the fake model answers instantly, so these numbers are the
harness and the transport, not a model. `BENCH_MODE=plane` runs the same test through a
plane (`BENCH_PLANE`, `BENCH_PLANE_TOKEN`, `BENCH_PROFILE`); that path has not been
measured yet because it needs Postgres, OpenBao and an identity provider behind it.

## Layout of the client package

```
packages/client/src
  types.ts        protocol shapes (open objects: v1 is additive)
  connection.ts   TroupeConnection — open, initialize, call, events, tool.invoke, auth.refresh
  plane.ts        PlaneClient — discovery, device grant, exchange, the harness API over /rpc
  auth.ts         AuthSession — signing in, and staying signed in. The only persisted secret
  session.ts      SessionView — subscribe, the replay cursor, commands, blobs, files, prompt()
  attach.ts       SessionAttachment — one session's socket kept alive across expiry and drops
  transcript.ts   the fold: events → a transcript. Pure, and the reason two clients agree
  fleet.ts        FleetStore — one list from however many sources there are
  daemon.ts       DaemonClient — the machine in front of you: one socket, many sessions
  config.ts       model settings: the shapes, and what an empty field in the form means
  admin.ts        the plane's administrative surface, one call per method

apps/desktop/src
  shell.ts        the whole contract between the web bundle and a desktop shell
  hooks.ts        React bindings over the stores above; no protocol knowledge
  theme.ts        which theme and mode this person reads in; the only place that knows
  tokens.css      generated from docs/design/themes/*.tokens.json — do not edit
  mark.ts         the mask's geometry, generated from the same files — do not edit
  views/          SignIn · Sessions · Session · Approval · Approvals · Files · Review
                  Local (Models) · Admin (Fleet · Bundles · Teams · Automation · Audit · Settings)
```

`SessionView` owns the cursor and `SessionAttachment` swaps the socket underneath it, so
a pod token running out is invisible: the plane mints a new one, `auth.refresh` hands it
over on the connection that is already open, and a turn in progress never notices. If the
socket does go, the view resubscribes from the last `seq` it actually processed and the
server closes the boundary — no gap, no duplicate.
