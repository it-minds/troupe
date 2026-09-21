# Running the throughput test

The bench dials a Troupe worker directly, with tokens it mints itself. That works
because a worker verifies session tokens offline against a JWKS on disk; hand it a JWKS
you hold the private half of and it will accept your tokens exactly as it would the
plane's. This is for measuring, never for a deployment.

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
  ghcr.io/objective-mj/troupe-worker:dev

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
BENCH_SIGNING_KEY=keys/signing-key.json BENCH_POD_ID=bench-0 \
BENCH_CLIENTS=20 BENCH_PROMPTS=10 pnpm bench
```

| variable | default | meaning |
| --- | --- | --- |
| `BENCH_MODE` | `worker` | `worker` dials `BENCH_WS` with self-minted tokens; `plane` goes through `BENCH_PLANE` with `BENCH_PLANE_TOKEN` and `BENCH_PROFILE` |
| `BENCH_WS` | `ws://localhost:4000/v1/socket` | the worker |
| `BENCH_CLIENTS` | 5 | concurrent clients, one session each |
| `BENCH_PROMPTS` | 20 | prompts per client, one in flight at a time |
| `BENCH_WORKSPACE` | `/workspace` | per-client sessions are created under `<workspace>/c<n>` |
| `BENCH_OUT` | `bench-results` | where the JSON goes |

Keep prompts per client under 40, or raise the session's `max_turns`: the default turn
budget ends a session in a way that looks exactly like a throughput problem.

`packages/bench/src/trace.ts` connects once, sends one prompt and prints every frame;
use it when something in the run above does not add up.
