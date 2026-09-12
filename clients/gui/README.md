# troupe-gui

The graphical client for [Troupe](https://github.com/it-minds/troupe-remote), and the
ground work every other client will stand on. Nothing here has a private door into the
server: it speaks `PROTOCOL.md` over a WebSocket, the same as the TUI and the Python
reference client.

Three packages in one pnpm workspace:

| package | what |
| --- | --- |
| `packages/client` | `@troupe/client` — the protocol in TypeScript. JSON-RPC 2.0 over WebSocket, the plane's HTTP surface (discovery, device-grant login, `/auth/exchange`, `/rpc`), and a `SessionView` that folds events and turns "send a prompt, wait for the turn" into a promise. Runs in a browser or Node; no dependencies. |
| `packages/bench` | `@troupe/bench` — the throughput test. N clients, one session each, K prompts each, every milestone timed. |
| `apps/desktop` | The GUI. Vite + React. Signs in through the plane (or dials a worker directly), streams a session, answers approvals. The bundle is plain web; a Tauri or Electron shell would load it unchanged. |

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
pnpm dev                         # the GUI on http://localhost:5173
```

The GUI's **Plane** tab needs a running plane whose `TROUPE_CORS_ORIGINS` lists the
GUI's origin (`http://localhost:5173` in development). The **Worker (direct)** tab
needs only a worker or a local daemon and, for a worker, a token.

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
  connection.ts   TroupeConnection — open, initialize, call, events, tool.invoke, auth
  plane.ts        PlaneClient — discovery, device grant, exchange, /rpc helpers
  session.ts      SessionView — subscribe, replay cursor, waitFor, prompt()
```
