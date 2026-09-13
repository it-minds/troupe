# End to end, against real servers

[testing.md](developer/testing.md) lists, under *What is not tested*:

> **The server's half.** Every assumption in the right-hand column above; a kind or
> Kapsule run is what would check it.

This is that, without a cluster. `test/support` is a plane, a worker and an identity
provider written in this repository: they prove the client behaves correctly when a
server behaves as `PROTOCOL.md` says, and they agree with the client by construction. A
real server does not, and what it can disagree about is what matters — event shapes, what
a replay actually sends, whether `TROUPE_CORS_ORIGINS` really decides who gets an answer,
and whether the idempotency ledger really collapses a command sent twice.

Both suites skip unless their environment variables are set, so `pnpm test` stays
runnable anywhere and CI is unchanged.

---

## A whole plane

`dev/plane-stack.yml` is Postgres, OpenBao with the transit key, Dex and the plane image
in one compose project, on ports of its own. **No Kubernetes and no Elixir toolchain**:
the plane runs from a published image and migrations run as a release eval before it
serves.

```sh
docker compose -f dev/plane-stack.yml up -d --wait --wait-timeout 240
# or a particular build:
TROUPE_PLANE_IMAGE=rg.fr-par.scw.cloud/troupe/troupe-plane:0.2.14 \
  docker compose -f dev/plane-stack.yml up -d --wait

cd packages/client
TROUPE_E2E_PLANE=http://localhost:4020 \
  node --test --import tsx --test-reporter=spec test/e2e.plane.test.ts

docker compose -f dev/plane-stack.yml down -v
```

The one fiddly part is the issuer. It has to mean the same thing to the test on the host
and to the plane inside the compose network, so it is `dex.localtest.me` — which resolves
to 127.0.0.1 publicly — and the plane is given an `extra_hosts` entry pointing that name
at the Docker host. Anything else and either the client cannot reach the device endpoint
or the plane cannot fetch the keys to verify what it issued.

Dex's device flow is driven headlessly — a code post, a login post, and a redirect chain
— so "sign in" is a test rather than something somebody has to sit through.

| test | what only a real plane can show |
| --- | --- |
| discovery names a provider a client can use | and that provider answers its own metadata |
| signs a person in with the device grant | the grant, end to end, against Dex |
| comes back from a stored refresh token | a relaunch with no second approval, and real rotation |
| keeps a refresh token and never a plane token | the invariant, against what was really written |
| answers only an origin on its allowlist | that `TROUPE_CORS_ORIGINS` is the setting `PlaneUnreachableError` should name |
| lists sessions into the fleet store | the shapes `rowFromPlane` parses |
| offers what a profile carries | `profiles.list`, before anything is created |
| refuses to place a session with no workers | the failure mode a view has to render |

**Not covered:** there is no worker in this stack, so `session.create` has nowhere to go —
the last test pins that as a stated refusal rather than a hang. A session placed *through*
a plane onto a real pod still wants a cluster.

## A real worker

A worker verifies session tokens offline against a JWKS on disk, so a JWKS whose private
half you hold is accepted exactly as the plane's would be. For testing only; a client
never signs its own token against a deployment.

```sh
mkdir -p keys && cd keys
node -e '
const { generateKeyPairSync, createHash } = require("crypto");
const fs = require("fs");
const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const pub = publicKey.export({ format: "jwk" });
const priv = privateKey.export({ format: "jwk" });
const canonical = JSON.stringify({ crv: pub.crv, kty: pub.kty, x: pub.x, y: pub.y });
const kid = createHash("sha256").update(canonical).digest("base64url");
fs.writeFileSync("jwks.json", JSON.stringify({ keys: [{ ...pub, kid, use: "sig", alg: "ES256" }] }));
fs.writeFileSync("signing-key.json", JSON.stringify({ ...priv, kid }));
'
printf '{"steps":[{"text":"Hello from the fake model, in a few words."}]}' > fake.json
cd ..
```

```sh
# On Git Bash for Windows, prefix with MSYS_NO_PATHCONV=1 so container paths survive.
docker run -d --name troupe-e2e -p 4010:4000 \
  -v "$PWD/keys:/etc/troupe:ro" --tmpfs /workspace:uid=1000,gid=1000,size=512m \
  -e TROUPE_WORKER_AUTOSTART=true -e TROUPE_PROFILE=bench -e TROUPE_POD_ORDINAL=e2e-0 \
  -e TROUPE_JWKS_PATH=/etc/troupe/jwks.json \
  -e TROUPE_PROVIDER=fake -e TROUPE_MODEL=fake -e TROUPE_FAKE_SCRIPT=/etc/troupe/fake.json \
  -e TROUPE_STATE_HOME=/workspace/.state -e TROUPE_SESSIONS_PER_POD=64 \
  -e TROUPE_HTTP_PORT=4000 -e RELEASE_DISTRIBUTION=none -e ERL_FLAGS="+Q 65536" \
  ghcr.io/objective-mj/troupe-worker:dev
docker exec troupe-e2e sh -c 'mkdir -p /workspace/e2e'   # it will not invent directories

cd packages/client
TROUPE_E2E_WS=ws://localhost:4010/v1/socket \
TROUPE_E2E_KEY="$PWD/../../keys/signing-key.json" \
TROUPE_E2E_POD=e2e-0 \
  node --test --import tsx --test-reporter=spec test/e2e.worker.test.ts
```

Sessions are attached through `SessionAttachment`, so the reconnection and token-renewal
policy under test is the one that ships; only `open` and `mint` are pointed at the worker
instead of at a plane.

| test | what only a real worker can show |
| --- | --- |
| negotiates the protocol this client speaks | the real `initialize` result, its scopes and principal |
| folds a real turn into a transcript | `fold`, over event shapes this repository did not invent |
| times a real turn, and returns when it ends | guards the regression where a turn waited out its timeout |
| collapses a command id sent twice | the real idempotency ledger, which is what makes a retry after a drop safe |
| resumes from the cursor after the socket dies | a real replay, with no gap and no duplicate |
| lists and reads the real workspace | real paths, and the `sha256:` hash `fs_changed` carries |

## What running these found

Three, none of which the in-repository servers had caught:

* **`prompt()` left its status poller running.** When a turn ended durably, the
  `session.get` loop kept going over a connection nobody was waiting on; its next call
  rejected when that socket closed, into a promise with no handler, which Node reports as
  an uncaught error inside whatever happens to be running. It now stops with the same
  signal that stops the waiters.
* **`close(1006)` is not a close an application may send.** 1006 is what a real drop
  *reports*; sending it throws. The private range is what a test should use.
* **Waiting on `status` after killing a socket is a race.** A close event arrives a turn
  of the loop after the socket stops working, so `status` still reads `live` for a moment
  — and `connecting` has already been seen once, on the way in. The unambiguous signal is
  that `SessionAttachment` replaces its `conn` when it reconnects.
