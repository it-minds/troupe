# Running the throughput test

The bench dials a Troupe worker directly, with tokens it mints itself. That works
because a worker verifies session tokens offline against a JWKS on disk; hand it a JWKS
you hold the private half of and it will accept your tokens exactly as it would the
plane's. This is for measuring, never for a deployment.

A worker with no plane, no object store and the scripted `fake` model measures a
*client*: the path from a frame to the session actor and back, without a model's latency.
It runs as one Docker container, dialled with tokens the bench mints itself
(`packages/bench/src/devToken.ts`). The sections below are the key pair, the `docker run`,
the run and its variables.

Each client opens its own socket and its own session (five clients on one session would
measure the model's serialisation, not the transport) and sends its prompts one at a
time. Every prompt is timed from just before `input.send` to the ack, `input_accepted`,
the first `llm_delta`, the durable `llm_response` and the end of the turn. Results are
printed and written as JSON under `packages/bench/bench-results/`.

## 1. A key pair and a JWKS

```sh
mkdir -p keys && cd keys
node -e '
const { generateKeyPairSync, createHash } = require("crypto");
const fs = require("fs");
const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const pub = publicKey.export({ format: "jwk" });
const priv = privateKey.export({ format: "jwk" });
// RFC 7638 thumbprint: the plane and the worker both compute `kid` this way.
const canonical = JSON.stringify({ crv: pub.crv, kty: pub.kty, x: pub.x, y: pub.y });
const kid = createHash("sha256").update(canonical).digest("base64url");
fs.writeFileSync("jwks.json", JSON.stringify({ keys: [{ ...pub, kid, use: "sig", alg: "ES256" }] }));
fs.writeFileSync("signing-key.json", JSON.stringify({ ...priv, kid }));
'
cat > fake.json <<'JSON'
{"steps": [{"text": "Hello from the fake model. A few sentences, so the client sees a stream of deltas rather than one word."}]}
JSON
cd ..
```

## 2. A worker

```sh
docker run -d --name troupe-bench-worker -p 4000:4000 \
  -v "$PWD/keys:/etc/troupe:ro" \
  --tmpfs /workspace:uid=1000,gid=1000,size=512m \
  -e TROUPE_WORKER_AUTOSTART=true -e TROUPE_PROFILE=bench -e TROUPE_POD_ORDINAL=bench-0 \
  -e TROUPE_JWKS_PATH=/etc/troupe/jwks.json \
  -e TROUPE_PROVIDER=fake -e TROUPE_MODEL=fake -e TROUPE_FAKE_SCRIPT=/etc/troupe/fake.json \
  -e TROUPE_STATE_HOME=/workspace/.state -e TROUPE_SESSIONS_PER_POD=64 \
  -e TROUPE_HTTP_PORT=4000 -e RELEASE_DISTRIBUTION=none -e ERL_FLAGS="+Q 65536" \
  ghcr.io/it-minds/troupe-worker:dev    # built here by scripts/build-images troupe_worker; CI publishes no :dev

# one workspace per client; the worker will not invent directories
docker exec troupe-bench-worker sh -c 'for i in $(seq 0 63); do mkdir -p /workspace/c$i; done'
```

`TROUPE_POD_ORDINAL` is the worker id and therefore the token audience; a token minted
for any other `aud` is refused with `wrong_audience`. `ERL_FLAGS=+Q 65536` matters: the
BEAM sizes its port table from `RLIMIT_NOFILE`, which Docker sets absurdly high.

On Git Bash for Windows, prefix docker commands with `MSYS_NO_PATHCONV=1` so
`/etc/troupe` and `/workspace` are not rewritten into `C:/Program Files/Git/...`.

## 3. The run

```sh
BENCH_SIGNING_KEY="$PWD/keys/signing-key.json" BENCH_POD_ID=bench-0 \
BENCH_CLIENTS=20 BENCH_PROMPTS=10 pnpm bench
```

`pnpm bench` runs in `packages/bench`, so a relative path in a variable is read from there.

| variable | default | meaning |
| --- | --- | --- |
| `BENCH_MODE` | `worker` | `worker` dials `BENCH_WS` with self-minted tokens; `plane` goes through `BENCH_PLANE` with `BENCH_PLANE_TOKEN` and `BENCH_PROFILE` |
| `BENCH_WS` | `ws://localhost:4000/v1/socket` | the worker |
| `BENCH_SIGNING_KEY` | none; worker mode needs it | the private half of the JWKS the worker trusts, which the bench signs its tokens with |
| `BENCH_POD_ID` | none; worker mode needs it | the worker's id, `TROUPE_POD_ORDINAL`: the tokens' audience |
| `BENCH_CLIENTS` | 5 | concurrent clients, one session each |
| `BENCH_PROMPTS` | 20 | prompts per client, one in flight at a time |
| `BENCH_WORKSPACE` | `/workspace` | per-client sessions are created under `<workspace>/c<n>` |
| `BENCH_OUT` | `bench-results` | where the JSON goes, under `packages/bench` when relative |

Keep prompts per client under 40, or raise the session's `max_turns`: the default turn
budget ends a session in a way that looks exactly like a throughput problem.

`packages/bench/src/trace.ts` connects once, sends one prompt and prints every frame;
use it when something in the run above does not add up.

## 4. What it measured

Measured on 2026-09-12, Docker Desktop on a Windows laptop, worker image built from
commit `2f85e39` of the platform's former repository, fake model:

| clients × prompts | connect+init p50 | input_accepted p50 / p95 | llm_response p50 / p95 | turn end p50 / p95 | turns/s |
| --- | --- | --- | --- | --- | --- |
| 5 × 20 | 13 ms | 0.6 / 1.3 ms | 1.1 / 3.7 ms | 1.3 / 9.1 ms | ~900 |
| 20 × 10 | 44 ms | 0.9 / 2.1 ms | 3.7 / 5.6 ms | 4.1 / 7.2 ms | ~1000 |

All 300 turns completed; the fake model answers instantly, so these numbers are the
harness and the transport, not a model. `BENCH_MODE=plane` runs the same test through a
plane; that path has not been measured, since it needs Postgres, OpenBao and an identity
provider behind it.
