# Stage 1 — report

Sessions have moved out of the TUI process and into a daemon. Every client reaches
them through one protocol and nothing reaches them any other way.

`mix check` — compile with warnings as errors, format, credo strict, boundaries, the
whole suite — is green, and the suite ran five consecutive times without a flake.

```
$ mix check
boundaries ok: 4 rules, no violations
Result: 31 passed (2 doctests, 29 tests)          # troupe_protocol
Result: 127 passed (3 doctests, 1 property, 123 tests)   # troupe_core
Result: 35 passed (2 properties, 33 tests)        # troupe_gateway
Result: 22 passed                                 # troupe_tui
Result: 20 passed                                 # troupe_ctl
```

235 tests. The packaged binary builds and runs: `scripts/build-local` produces a 19 MB
`troupe-0.2.0-linux_x86_64`, and a headless run through it spawns a daemon on demand,
writes its file through the tool, runs its shell command through `reaper`, and a second
client lists the session from the same daemon.

---

## The ten criteria

### 1. The xref boundary checks fail CI on violation

```
$ mix troupe.boundaries
boundaries ok: 4 rules, no violations

$ # with one line added to troupe_tui: `def peek(id), do: Troupe.events(id)`
$ mix troupe.boundaries
troupe_tui must not depend on troupe_core (the TUI is a protocol client and gets no private access)
    Troupe.UI.BoundaryProbe calls Troupe
troupe_tui must not depend on troupe_core (not declared in mix.exs)
    Troupe.UI.BoundaryProbe calls Troupe
** (Mix) 2 boundary violation(s)
exit=1
```

The task reads the compiled beams' import chunks, so it sees what an app *calls*, not
what its `mix.exs` claims. Both are checked.

### 2. The Python stdlib client, in CI, against a daemon with the Fake provider

`clients/python/conformance.py` initializes, lists the fleet, subscribes from `seq` 0,
sends input, answers an approval, and verifies the hash chain with `hashlib` — in the
standard library, with no access to this source.

```
$ mix test apps/troupe_gateway/test/troupe/gateway/python_client_test.exs --trace
  * test the Python reference client initializes, lists the fleet, replays, steers, and approves (371.2ms)
Result: 1 passed
```

What the client reported:

```json
{"server": "troupe-daemon", "principal": "user",
 "scopes": ["observe", "control", "admin"],
 "fleet": ["20260911T091340-IGc-rQ"], "head_seq": 5, "replayed": 5,
 "approval": {"call_id": "call_1", "tool": "needs_approval"},
 "tool": "needs_approval", "chain_ok": true}
```

### 3. `mix troupe.schema.diff`

Compatible on an added field; fails on each of the four breaking changes.

```
$ mix troupe.schema.diff                     # added optional field
schema compatible: 0 new document(s), 1 with added fields

$ mix troupe.schema.diff                     # removed field
  events/user_input.json: field dialect was removed or renamed
** (Mix) 1 breaking schema change(s).                                    exit=1

$ mix troupe.schema.diff                     # renamed field
  events/user_input.json: field source is now required; older clients do not send it
  events/user_input.json: field origin was removed or renamed
** (Mix) 2 breaking schema change(s).                                    exit=1

$ mix troupe.schema.diff                     # changed type
  events/user_input.json: field source changed type from %{"type" => "integer"} to %{"type" => "string"}
** (Mix) 1 breaking schema change(s).                                    exit=1

$ mix troupe.schema.diff                     # newly required field
  events/agent_done.json: field reason is now required; older clients do not send it
** (Mix) 1 breaking schema change(s).                                    exit=1
```

A separate test folds a real session's log and validates every event against the
schema its type claims, so the published table cannot drift from the code that emits
the events.

### 4. Property: random disconnects and reconnects yield the log exactly

```
$ mix test apps/troupe_gateway/test/troupe/gateway/replay_property_test.exs --trace
Result: 2 passed
```

One fixed log, cut at randomly generated points; each time the client reconnects from
the last `seq` it actually *processed* and the reassembled stream must equal the log,
seq for seq and hash for hash.

### 5. A detail subscriber that never reads

```
$ mix test apps/troupe_gateway/test/troupe/gateway/backpressure_test.exs --trace
  * test a detail subscriber that never reads costs the agent nothing (489.6ms)
  * test a subscriber far enough behind on durable events is told to resync (3581.4ms)
Result: 2 passed
```

A raw socket, subscribed at `detail` and then never read from. The test waits until
ephemerals are actually being dropped before it measures, then requires turn latency
within 10% of baseline, the connection's memory and mailbox bounded, and the
subscription still live. With a small durable bound it receives `resync_required`
naming the topic and the last `seq` delivered.

### 6. `kill -9` with three sessions, and dormancy

```
$ mix test apps/troupe_gateway/test/troupe/gateway/restart_test.exs --trace
  * test kill -9 with three sessions: all come back, the mid-turn one interrupted (3851.3ms)
  * test an idle session stops its tree, and subscribing serves history without starting one (2727.3ms)
Result: 2 passed
```

A real daemon in a real OS process, killed with a real `SIGKILL` while one of three
sessions is inside a tool call. After the restart all three are listed, the mid-turn
one reports `"status": "interrupted"` — read from the log, before anything has been
restarted — and the `llm_request` count does not move while the session is listed,
fetched and replayed. It moves when new input arrives, and the interrupted tool call
is closed off as an error rather than re-run.

### 7. Ten concurrent clients spawn exactly one daemon

```
$ mix test apps/troupe_gateway/test/troupe/gateway/autospawn_test.exs --trace
  * test ten concurrent clients spawn exactly one daemon (759.9ms)
  * test a client that asks not to spawn one gets told there isn't one (1.2ms)
  * test a stale lock left by a killed client does not block start-up forever (869.9ms)
Result: 3 passed
```

Ten clients race for an `O_EXCL` lock; the launcher script counts its own invocations
from outside the VM (exactly one), and all ten report the same `server_info.instance_id`
— which the counter alone would not prove.

### 8. Worktrees

```
$ mix test apps/troupe_gateway/test/troupe/gateway/worktrees_test.exs --trace
  * test a second session in a live workspace gets its own worktree on troupe/<slug> (166.6ms)
  * test worktree.remove refuses a dirty tree without force, and obeys it with force (125.0ms)
  * test a clean worktree is removed without force (151.2ms)
  * test worktree: never keeps the second session in the repository itself (250.4ms)
Result: 4 passed
```

Real `git` against a real repository, and `git rev-parse --abbrev-ref HEAD` in the new
worktree agrees with what `session.create` said.

### 9. Approvals in three sessions, through HQ

```
$ mix test apps/troupe_tui/test/troupe/ui/hq_test.exs --trace
  * test three sessions blocked on approvals all show up in HQ, and answering resolves them (1456.4ms)
  * test a second client answering an already-decided approval gets approval_resolved (76.3ms)
  * test the fold drops an approval once the session says it was resolved (2.4ms)
Result: 3 passed
```

HQ never opens a session: it lists all three approvals from `fleet` plus the history it
replays at start-up. A second client answering an already-decided approval gets an
`approval_resolved` event naming who got there first, and the session records one
decision and one tool run.

### 10. The same `command_id` twice

```
$ mix test apps/troupe_gateway/test/troupe/gateway/daemon_test.exs --only describe:idempotency
  * test idempotency the same command_id twice produces exactly one effect (46.0ms)
  * test idempotency a replayed command is honoured across connections (253.2ms)
Result: 2 passed, 19 excluded
```

The ledger claims the id *before* running the command, so two concurrent deliveries of
the same retry cannot both pass the check.

---

## What is not in this stage

Stages 2–4 are untouched: `troupe_worker`, `troupe_plane` and `troupe_operator` exist
as empty applications with their boundaries already enforced. Remote transport is
specified in `PROTOCOL.md` and not implemented; `initialize` reports
`"capabilities": {"remote": false}`.

The CI workflow is written and has never run — there is no remote to run it on. The
parts of it that can run locally have: `mix check`, `mix troupe.boundaries`,
`mix troupe.schema.diff`, the Python conformance test, and a local Burrito build with a
smoke test of the resulting binary.

---

# Stage 2 — progress

Stage 2 is **largely delivered**. Thirty-two of its thirty-five criteria pass in full
and one in part; three are not built yet. This section says which, and what is left.

`mix check` is green: 553 tests, zero warnings, formatted, credo clean, boundaries
clean. Four of the suites need real infrastructure and say so loudly when it is absent —
a kind cluster for the operator and enrolment tests, PostgreSQL for the plane's, and
MinIO and OpenBao for the worker's.

```
$ scripts/kind-up && helm upgrade --install troupe charts/troupe -n troupe-system --create-namespace
$ scripts/dev-up && MIX_ENV=test mix ecto.migrate
$ mix check
3531 mods/funs, found no issues.
boundaries ok: 4 rules, no violations
Result: 66 passed     # troupe_protocol  (13 against real OpenBao and MinIO)
Result: 51 passed     # troupe_operator  (6 against a real cluster)
Result: 109 passed    # troupe_plane     (9 against a real API server, 3 across two nodes)
Result: 168 passed    # troupe_core
Result: 40 passed     # troupe_gateway
Result: 62 passed     # troupe_worker    (all against real MinIO, OpenBao and PostgreSQL)
Result: 22 passed     # troupe_tui
Result: 35 passed     # troupe_ctl
```

## The platform

**1. `helm install` on kind, and two profiles Ready.** `charts/troupe` ships the three
CRDs, the operator, its RBAC, a default `TroupePolicy` and the admission policies. The
cluster test creates `dev` and `ux`, waits for `Ready`, and asserts every object the
architecture lists — namespace, ServiceAccount with automount disabled, StatefulSet on
`OnDelete`, headless Service, a Service and an Ingress per pod at
`<ordinal>.<profile>.workers.<domain>`, NetworkPolicy, PodDisruptionBudget, and a claim
per granted team volume.

**2. A profile outside policy is refused, and nothing is created.**

```
$ kubectl apply -f bad-image.yaml
Error from server (Forbidden): ValidatingAdmissionPolicy 'troupe-worker-profile-policy'
denied request: image repository docker.io/someone/whatever is not allowed by TroupePolicy
```

The same for replicas, sessionsPerPod, CPU, memory, a declared FQDN, an LLM endpoint, an
MCP server, a storage class, and `orgMount` without an org volume. With the admission
binding removed, the operator refuses it instead, marks `PolicyViolation`, and creates
no namespace.

**3. Killing the operator mid-reconcile converges.** Three kills during a reconcile, then
exactly one of everything. Deleting a managed Service brings it back in under 30
seconds — the operator watches the objects it created, so the repair starts as the
deletion lands rather than at the next resync.

**4. A pod enrols as its own profile.** Enrolment is a `TokenReview` against a real API
server. A token from `troupe-w-ux` enrols as `ux` and cannot claim `dev`; a token minted
for the API server's audience is refused; so is one for another ServiceAccount, or from
outside a worker namespace. A pod past its fifteen-second lease is swept unhealthy and
stops being placed on.

**6. SCIM and a login agree.** A SCIM push creates users and groups and enabling a group
makes it a team; the same person arriving at login with SCIM off gets the same teams and
the same profiles. Membership is replaced on both paths, so leaving a group at login
removes the team it gave.

**7. `troupe login`, and exactly what you may see.** The device grant runs against the
identity provider; a test reads every request that crossed and asserts the plane received
the provider's token and nothing else — no refresh token, no device code. The refresh
token lands in a `0600` file; the session token is never written down. `sessions.list`
then returns exactly the sessions owned, shared by ACL, or visible through a team, and a
user in no enabled team sees an empty fleet and cannot create.

**8 and 9. Capacity and budget are decided once, across replicas.** Against a real second
node started with `:peer`: fifty creates split across two replicas fill a profile with
room for twenty exactly once, thirty get a capacity error, and no pod exceeds its cap.
Concurrent reservations never exceed a team's budget. Killing the replica holding an
actor loses nothing it had granted.

**11 and 29. Config bundles.** Publishing assigns the next version, hashes the content
canonically, and announces to every pod on that channel and no others; adoption is the
mismatch between the published hash and what each pod reports. A session is pinned at
creation and keeps its version while v2 is published around it. Activating on a retired
version upgrades, moves the pin, and appends `config_upgraded`. Revoking a team's grant
makes its sessions read-only: reads still work, activation is refused.

## Tokens and access

**12, 13 and 14.** Tokens are assembled by the plane and signed through OpenBao's transit
engine, so the plane holds no signing key and cannot export one. `aud` is the pod's
worker id: a token minted for a `ux` pod fails on audience at a `dev` pod. Workers verify
offline against a cached JWKS. `auth.expiring` warns two minutes out, `auth.refresh`
renews on the connection that is already open, and the next command past `exp` is
refused and the connection closes. A viewer's `input.send` and `approval.respond` are
forbidden while events keep flowing; a collaborator revoked by the plane is refused on
their next command, with the same token still in their hand.

**35. What each credential cannot do.** Against a real OpenBao with real tokens carrying
the policies the chart installs: the plane cannot read a session key of any team and
cannot write one, but can destroy metadata so erasure works; a profile's credential
reaches only its granted teams; a pod cannot destroy a key even of its own team.

## The worker runtime

**15, 16 and 17.** A session's roots are a mount table — `session:/`, `team:<name>/`,
`org:/` — recorded as a durable event and resolved by every file tool. The same table is
the bind list for the sandbox: `shell` runs under bubblewrap, and ten tests run real
commands to check that a read-only team volume fails a write with a read-only filesystem
error, that another team's volume and another session's workspace do not exist, that
`/tmp` is private, and that the process table has twenty entries rather than the host's
hundreds. `publish` and `import` are the only tools that cross, they ask by default, and
each copy is a durable event with source, destination and hash. A file written by `shell`
reaches subscribers as `fs_changed` in well under the second the done item allows, and
`fs.read` returns the same hash.

**18, 19, 24 and 33.** Sealing happens at every turn completion and at least every sixty
seconds, upload before report. `troupe verify` walks the chain offline and names the
first bad `seq`; the plane holds every sealed head as an anchor, contiguous. A pod whose
epoch has been passed refuses to activate — checked against the plaintext manifest before
anything is decrypted — and a running session that is fenced kills its sealer, stops and
discards its cache. Deleting a volume mid-session costs the unsealed tail and nothing
else; the session comes back elsewhere from object storage with its history and its
workspace. `Troupe.Plane.Index` rebuilds the whole index from storage with no key at all,
trusting segments over a manifest a ghost pod may have rewritten.

**20, 21 and 22.** Every LLM request carries owner, team, session and agent, checked
against a mock gateway that reads the bytes. With the plane stopped, an attached harness
completes its turn and sealing continues while the reports queue; creating and activating
fail with a named reason. An MCP server receives the service credential and nothing else
— the session travels as `_meta`, an identifier rather than a bearer of anything.

**25, 26, 27, 28, 31 and 32.** Ten thousand dormant sessions on one pod add zero
processes and no process memory. Reading a dormant session serves its full history with
zero `Agent.Server` processes and zero model calls. An approval asked before dormancy and
answered three days later brings the session back and continues from the call that was
waiting. Eight simultaneous activations produce one tree and one epoch. Above the low
watermark the pod evicts dormant caches least-recently-used and never an active
workspace. After `session.erase` the key is gone from OpenBao, nothing under the prefix
survives including prior versions in the versioned bucket, and a pod that was offline
applies the erasure when it enrols.

**23. No session content anywhere it should not be.** A recording TCP relay sits between
a worker and the plane; a marker string sent as session input appears nowhere in the
captured traffic, nor in the plane's row, nor in its anchors.

## Not yet, and why

- **5 in full.** A listener killed and restarted brings the worker's control link back in
  well under ten seconds, and reports made meanwhile are delivered. The two-replica form
  — kill one of two plane pods behind a Service — needs the cluster test rather than a
  single BEAM.
- **10.** Drain and scale-down with a live session: the plane stops placing, the turn
  finishes, the session goes dormant, the pod is removed, and deleting the PVC loses
  nothing. Every piece it rests on exists — draining is a `Fleet` flag, dormancy is
  proven, and activation elsewhere from object storage is proven — but the sequence is
  not yet driven end to end.
- **30.** Fixture logs from prior releases replaying to a recorded fold hash, and a
  corrupted snapshot falling back to a full replay.
- **34.** A PITR restore of the plane database followed by an index rebuild and a ledger
  reconcile. The database is configured for it (`scripts/dev-up` runs PostgreSQL with WAL
  archiving) and the rebuild half is proven; the drill is not.
