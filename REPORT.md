# Stage 1 — report

> **Historical.** Each section below is the evidence for a stage as it stood when that
> stage was finished. On 2026-09-14 this repository became the remote alone: the client
> apps, the packaged binary, its installers and the CI jobs that built them were deleted
> (`DECISIONS.md` 319-324). Test counts, release names and `scripts/build-local` runs
> recorded here were true when they were written and are not re-run.

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

# Stage 2 — report

Stage 2 is **delivered**. All thirty-five done items pass. This section says how each
was checked, and what was found on the way.

`mix check` is green: 585 tests, zero warnings, formatted, credo clean, boundaries clean.
Five of the suites need real infrastructure and say so loudly when it is absent — a kind
cluster for the operator and enrolment tests, PostgreSQL for the plane's, MinIO and
OpenBao for the worker's, and a second OTP node for the two-replica ones.

```
$ scripts/kind-up && helm upgrade --install troupe charts/troupe -n troupe-system --create-namespace
$ scripts/dev-up && MIX_ENV=test mix ecto.migrate
$ mix check
3695 mods/funs, found no issues.
boundaries ok: 4 rules, no violations
Result: 66 passed     # troupe_protocol  (13 against real OpenBao and MinIO)
Result: 51 passed     # troupe_operator  (6 against a real cluster)
Result: 119 passed    # troupe_plane     (9 against a real API server, 3 across two nodes)
Result: 178 passed    # troupe_core
Result: 40 passed     # troupe_gateway
Result: 74 passed     # troupe_worker    (all against real MinIO, OpenBao and PostgreSQL)
Result: 22 passed     # troupe_tui
Result: 35 passed     # troupe_ctl
```

## The platform

**1. `helm install` on kind, and two profiles Ready.** `charts/troupe` ships the three
CRDs, the operator, its RBAC, a default `TroupePolicy` and the admission policies. The
cluster test creates `dev` and `ux`, waits for `Ready`, and asserts every object the
architecture lists — namespace, ServiceAccount with automount disabled, StatefulSet on
`OnDelete`, headless Service, a Service and an Ingress per pod at
`<ordinal>-<profile>.workers.<domain>`, NetworkPolicy, PodDisruptionBudget, and a claim
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

**5. Killing one of two plane replicas.** Two real replicas — the second a separate OTP
node — behind a Service that picks a backend per connection and does not move ones
already established, because a real Service does not either. The worker's control link
comes back on the survivor well inside ten seconds; the session attached to that worker
keeps its tree, its epoch and its sealed head across the failure and runs another turn
afterwards; and creates keep being placed by the same `:global` actor from the surviving
replica.

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

**10. Scaling down with a live session.** The plane marks the pod draining so every
replica stops placing on it, the worker waits for the running turn rather than killing
it — a turn halfway through a tool call has an OS process attached and a model call
already paid for — and only then seals, archives, uploads and erases. The plane checks
its own index before agreeing the pod is empty. Then the volume is deleted and the
session comes back on ordinal 0 with its full history and its workspace, which is the
moment a skipped step would have shown. A turn that will not finish is cancelled at the
drain timeout and everything before it survives.

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

**30. Old logs still mean what they meant.** Every released version records log fixtures
and the fold each produces, and every build replays all of them and compares. The hash is
taken over a witness of the durable event types the agent's replay acts on — read out of
the source by a test, so a clause added there without one here is caught rather than
becoming a blind spot. Snapshots carry their format and the build that computed them, and
one from another build, in an older format, that will not decode, or whose bytes are
damaged is discarded for a full replay that produces exactly the same fold.

**34. The restore drill.** `scripts/pitr-drill` takes a base backup, creates a restore
point, writes a session that is durable in object storage and recorded in the index,
restores PostgreSQL to before it, and rebuilds:

```
$ ./scripts/pitr-drill
==> 3. A session written after the restore point
seeded drill-after-backup-1789141447 into object storage
recorded drill-after-backup-1789141447 in the index
==> 4. Restore to the point before it
LOG:  recovery stopping at restore point "troupe_drill_1789141447"
the restored database has 0 row(s) for drill-after-backup-1789141447 (expected 0)
==> 5. Rebuild from object storage
found 1, rebuilt 1, skipped 0, failed 0
==> 6. Nothing was lost
drill-after-backup-1789141447 after the rebuild: 1 row(s), epoch 3, head sha256:drill
```

The ledger accepts each gateway request id exactly once and a repeat is a success rather
than an error, because a worker replaying a queued report has done nothing wrong.
Reconciliation compares by request id — the only identifier both systems share — and
reports drift in three directions without ever repairing it.

## What writing the tests found

Four things that were wrong and would not have been found by reading the code.

**A confinement bug, caught before it was committed.** The first mount-table resolver
reinterpreted absolute paths relative to a mount root, turning `/etc/passwd` into a file
inside the workspace. The existing workspace tests caught it; `Workspace.absolute?/1` is
now public so both paths apply one rule.

**A running session's workspace was never archived.** The seal interval bounded what a
lost volume costs in *history*; nothing bounded what it cost in *files*, so a pod deleted
mid-session came back with a full log and an empty tree. Now archived on its own interval,
skipped when a cheap fingerprint says nothing changed.

**Every WAL archive was failing silently.** The dev PostgreSQL's archive volume was
root-owned and PostgreSQL archives as `postgres` — 748 failed archive commands, and
point-in-time recovery with nothing to recover *through*. Found by writing the drill and
running it, which is what a drill is for.

**A flaky test that was reading a projection it had not waited for.** `SummaryTest` read
the fold straight after seeing the agent go idle, but a projection is a subscriber like
any other and the order `Events.publish/2` reaches subscribers in is not defined. It
flaked twice in full runs before being fixed.

## What is not in this stage

Stage 3's admin panel and self-service provisioning, and stage 4's collaboration and
client-hosted tools. The seams they need are in place: `Troupe.Plane.Harness` is the
context an admin API and a `troupe admin` CLI will both go through, and the gateway's
server-to-client request path is the one `tool.invoke` will use.

---

# Stage 3 — report

Stage 3 is **delivered**. All eight done items pass.

`mix check` is green. Two of the suites need infrastructure beyond the development
services and say so loudly when it is absent: a kind cluster with the chart installed,
and PostgreSQL for the plane.

```
$ scripts/kind-up && helm upgrade --install troupe charts/troupe -n troupe-system --create-namespace
$ scripts/dev-up && MIX_ENV=test mix ecto.migrate
$ mix check
boundaries ok: 4 app rule(s), 1 module rule(s), no violations
```

## The panel

**1. Profiles, pods, conditions and load, and a killed pod within two seconds.** Driven
with `Phoenix.LiveViewTest` against the real endpoint and the real routes, because the
parts of a panel that break are the ones a unit test of the LiveView module would skip:
the mount that decides who you are, the session the socket carries, the redirect somebody
with no role gets. Eighteen tests, including that a pod going unhealthy is on the page
within two seconds, that a team admin sees only their granted profiles and is not offered
the drain button, and that erasing takes two clicks.

## Provisioning

**2. Direct mode, and what the plane's credential cannot do.** A profile created through
the panel becomes a `WorkerProfile` the operator reconciles. The RBAC is confirmed by
asking the API server:

```
$ kubectl auth can-i create workerprofiles --as system:serviceaccount:troupe-system:troupe-plane -n troupe-system
yes
$ kubectl auth can-i create pods --as system:serviceaccount:troupe-system:troupe-plane -n troupe-system
no
$ kubectl auth can-i create secrets --as system:serviceaccount:troupe-system:troupe-plane -n troupe-system
no
$ kubectl auth can-i create namespaces --as system:serviceaccount:troupe-system:troupe-plane -n troupe-system
no
```

The same for `deployments`, `statefulsets`, `serviceaccounts`, `roles`, `rolebindings`,
`escalate`, and the subresources somebody would reach for next — `pods/exec`,
`pods/log`, `pods/attach`, `pods/portforward`.

**3. GitOps mode.** The same manifest is committed to a fixture repository and the state
is `Pending` until the operator's `observedGeneration` catches up. A test parses the
committed YAML back and asserts it is the document direct mode would have applied — two
modes producing different profiles would be a trap rather than a choice.

**4. A grant reaches a member without re-logging in.** The profile appears in `me` and
`profiles.list` the moment the grant is written, and in the next minted token. The token
already in their hand is *not* retroactively widened, because a token is a claim about
the moment it was minted; what it may do is decided per request against the grants as
they stand.

**5. `SecretMissing`, and no value anywhere.** A profile referring to a secret the cluster
does not have reports the condition with the reference named, and clears it when the
secret appears. The value never reaches the custom resource or the StatefulSet — both
carry the reference and the kubelet does the rest.

## Roles

**6. What each administrator sees.** A `team_admin` sees their team's sessions, spend and
granted profiles and no others; a `platform_admin` sees everything. Neither can fetch
session content — not as a check applied at the edge, but because the admin context has
no function that returns it, and a test asserts no function is even *named* as though it
might.

## Parity

**7. Three surfaces, one context.** `Troupe.Plane.AdminParityTest` enumerates
`Troupe.Plane.Admin` and asserts every function has both an admin API method and a
`troupe admin` command, that no method names a function that does not exist, and that the
arities line up. `mix troupe.boundaries` grew module-level rules and the first one asserts
a LiveView calls nothing but `Plane.Admin` — it found three real violations the moment it
was written.

## Audit

**8. Who changed what.** Every administrative change writes a row with the actor and a
diff over the fields that moved; a refused change writes nothing. `troupe admin audit`
lists it, narrowable by actor, kind and subject.

## What writing the tests found

**The audit trail was lying about the most interesting changes.** `Audit.diff` used
assignments as comprehension filters, which drops the element when the value is `nil` —
so every field set from nothing or cleared to nothing was silently absent. It also
compared a struct's atom keys and a form's string keys as different fields. Found by the
profile editor's preview saying "no changes" to a change.

**The plane could not read `TroupePolicy`.** The panel validates against it for fast
feedback, and in a cluster that check could never have run. The chart gained a read-only
`ClusterRole`. Found by asking the API server rather than reading the RBAC file.

**`kubectl auth can-i get pods/log` does not ask about `pods/log`.** The slash form is
answered as though it said `pods`, which the plane *can* get — so the RBAC test would have
passed while proving nothing. Subresources need `--subresource`, and the answer is the
last line because `kubectl` writes warnings to the same stream.

**A cluster test left the admission binding owned by the wrong field manager**, so
`helm upgrade` failed afterwards with a conflict on `.spec.matchResources`. The suite now
restores it as Helm would, and sweeps profiles left by interrupted runs on the way in —
each one is otherwise reconciled for as long as the cluster lives.

**`SecretMissing` was made to force `Ready: False`**, which merges two facts the spec
separates and made every fixture profile in the cluster suite go unready at once.
Separated, and the fixtures now create the secret they name.

## What is not in this stage

Stage 4: several harnesses on one session, and client-hosted tools. The seams are in
place — the gateway's connection can send requests as well as receive them, and
`Troupe.Tool` already takes values as well as modules, which is what the MCP adapter uses.


---

# Stage 4 — report

Stage 4 is **delivered**. All five done items pass.

Several clients can now attach to one session and see one order; presence reaches them
and cannot reach the log; a harness can offer tools that run on its own machine, after a
consent step the person actually sees, and losing that harness costs the tools and not
the turn.

Two things had to be built underneath before the fifth done item could be attempted at
all: the WebSocket transport `PROTOCOL.md` has promised since stage 0 and nothing served,
and the configuration a worker release needs to boot into anything but an empty
supervision tree.

```
$ scripts/kind-up && helm upgrade --install troupe charts/troupe -n troupe-system --create-namespace
$ scripts/dev-up && MIX_ENV=test mix ecto.migrate
$ scripts/build-images troupe_worker
$ mix check
4314 mods/funs, found no issues.
boundaries ok: 4 app rule(s), 1 module rule(s), no violations
Result: 83 passed     # troupe_protocol
Result: 42 passed     # troupe_operator  (one of them five clients on a real pod)
Result: 192 passed    # troupe_core
Result: 55 passed     # troupe_gateway
Result: 30 passed     # troupe_tui
Result: 45 passed     # troupe_ctl
Result: 190 passed    # troupe_plane
Result: 83 passed     # troupe_worker
```

720 tests. Twenty-eight of them need infrastructure and say so loudly when it is absent:
a kind cluster with the worker image loaded, PostgreSQL, MinIO, OpenBao, and a second OTP
node.

## The five done items

### 1. Two harnesses, 100 inputs each, one order

```
$ mix test apps/troupe_gateway/test/troupe/gateway/collaboration_test.exs
Result: 7 passed
```

Two clients with distinct principals each send a hundred inputs as fast as their
connection allows, on separate connections, into one session. Each has a collector
process of its own, because "both observe the identical order" is a claim about two
independent receivers rather than one list read twice.

All two hundred are accepted exactly once. The durable sequences the two clients
collected agree over the prefix they have both reached — one client being a few events
behind the other is lag, not disagreement — and the sequence numbers are one contiguous
run, so neither is agreeing about an order it has holes in. Every `input_accepted` names
the client that sent it, and every acknowledgement carries back the `command_id` the
client rendered optimistically against.

`input_queued` is a separate test, because the interesting case is the one that is easy
to get wrong: an input sent while the agent is busy is announced **once**, not once per
state transition.

### 2. Presence reaches other clients and never appears in the durable log

Same file. `presence.set` reaches the other attached client with the subject, the state
and the agent; the event has no `seq` and is marked ephemeral; a fresh client replaying
from the beginning sees presence events and every one of them has no `seq`, so no replay
could contain one. The server's own log agrees.

Joining and leaving are the connection's business and are announced where a subscription
is taken out and dropped, so a client that crashes still leaves.

The enforcement is structural: `Gateway.Presence` calls `Events.publish_ephemeral/4` and
has no path to `Session.Log` at all.

### 3. A client-hosted tool, served by its registrant, logged, tainting the session

```
$ mix test apps/troupe_gateway/test/troupe/gateway/client_tools_test.exs
Result: 8 passed
$ mix test apps/troupe_core/test/troupe/session/client_tools_test.exs
Result: 14 passed
```

Harness A registers a tool. The first attempt has no consent and is refused with the
challenge, the prompt and the tool names to show. The second carries what the person
confirmed and is accepted. The agent's call arrives at A as a server-to-client
`tool.invoke`, A answers, and `tool_call_completed` carries A's answer. B — attached to
the same session, with the same scopes, and with a mailbox of its own so that "B was
never asked" is a claim about B — never receives the request.

B's **summary** shows the taint, which is the done item's own wording: a participant
watching the summary stream rather than the detail stream still finds out.
`tools_registered` and `session_tainted` are both in the log.

Registration without consent is refused four ways, and each is a different way to have
got it wrong: no challenge at all; an invented one; one issued to another connection; one
issued to another subject; and one covering different tools than the registration names.

### 4. A registrant that disconnects mid-call

Same file. A disconnects without answering. The agent has an error result naming the
disconnection **inside ten seconds** — the tool timeout is three minutes, and waiting it
out for news that has already arrived would be a hung turn — and carries on to another
model turn. `tools_unregistered` is logged with the reason, and there is no longer any
such tool for B to invoke.

The immediacy comes from `Connection.terminate/2` answering every outstanding
`tool.invoke` with `:disconnected`. `ClientTools` hears about the registration through
its own monitor, but it cannot unblock a tool task already waiting on an answer.

### 5. Five clients over a WebSocket on kind

```
$ scripts/build-images troupe_worker
$ mix test apps/troupe_operator/test/troupe/operator/latency_cluster_test.exs

input.send -> input_accepted, 5 clients over a WebSocket on kind
  samples 150
  p50     6ms
  p95     9ms
  p99     11ms
  max     11ms

Result: 1 passed
```

A real worker pod on kind — the release image, a Service, a readiness probe — reached
through `kubectl port-forward`, with five `Troupe.Protocol.Client`s attached over
`ws://…/v1/socket`. What is measured is the path a person feels: the frame out, Bandit,
the relay to the connection, the scope check, the session actor's mailbox, the durable
append, the fan-out, and the frame home. **p95 of 9ms against a budget of 100.**

Each client drives a session of its own with one input in flight. Five clients hammering
one session would measure how long a queue behind a busy agent takes to drain, which is a
property of the model's speed rather than of the transport.

Reproduced on a second consecutive `mix check`: p50 6ms, p95 10ms, p99 14ms.

## What had to be built first

**The WebSocket transport, on both ends.** `PROTOCOL.md` has specified
`wss://<host>/v1/socket` since stage 0 and the operator's Ingress and both probes have
pointed at port 4000 since stage 3. Nothing served it: every listener was raw NDJSON on
4100. A client could not have attached to a pod through an Ingress and kubelet's probes
were failing against a port with nothing behind them.

`Gateway.Web` is the router — `/health/live`, `/health/ready`, and the upgrade — and
`Gateway.Web.Socket` relays frames to an ordinary `Gateway.Connection`. On the client
side `Protocol.Client.Transport` puts the same seam under `Protocol.Client`, so a laptop
reaching a pod and a laptop reaching its own daemon are one client with one handshake.

**A worker pod's configuration.** `runtime.exs` had blocks for the operator, the plane
and the daemon and none for the worker, so the release booted an empty supervision tree.
It now reads what the operator has been setting since stage 3, and the operator sets
`TROUPE_WORKER_AUTOSTART` so that it means something.

**The connection supervisor on a pod.** Both listeners hand sockets to
`Gateway.Connections` and every command goes through `Gateway.Commands`; on a pod nobody
started either, because they belong to `Gateway.Daemon`, which a pod does not run. The
first real attach to a real pod found it immediately.

**The Dockerfile.** It had never built. `mix deps.compile` in the dependency layer tries
to compile `troupe_core` before any of its source has been copied — in an umbrella the
siblings are path dependencies — and the base image tag was a year stale.

## The harness side

```
$ mix test apps/troupe_tui/test/troupe/ui/tui_connectors_test.exs
Result: 8 passed
```

The TUI reads personal MCP servers from `$XDG_CONFIG_HOME/troupe/mcp.json`, where a
`credential_ref` names an environment variable so the file holds a reference and the value
stays in the shell that started the client. Nothing is offered by attaching. `/connect`
lists them; `/connect notes` prints what the session asked and registers nothing;
`/connect yes` registers. A `tool.invoke` is served in a task against the person's own
server, and the session's identity travels as `_meta` — an identifier for the server's
logs — and never as an authorisation.

The test runs a real MCP server on loopback and asserts on what that server was asked,
because a stubbed client would prove only that the stub was called.

## Measured

```
$ mix test apps/troupe_worker/test/troupe/worker/latency_test.exs

measured against a real object store and key manager

  seal lag        median 5ms     max 7ms     (5 turns)
  activation warm median 296ms   max 671ms   (5 activations)
  activation cold median 363ms   max 417ms   (5 activations)
```

A second run gave 4ms, 312ms and 357ms. The warm maximum is the first sample of the run
and is noise; the medians are the numbers to read.

**Seal lag** is how long a durable event exists only on a pod's volume — the window in
which losing the volume loses the event, and therefore the size of the promise that a
session survives its pod. Measured from the append that ends a turn to the sealer's
report, which the sealer makes *after* the upload.

**Activation** is measured twice. *Warm* has the workspace archive still on this pod's
volume; *cold* has nothing, so every byte comes from object storage, is decrypted, and the
log is replayed. Both are dominated by the key fetch and the manifest round trip rather
than by the payload, which is why they are closer together than one might expect at this
size; a large workspace would widen the gap.

The **Bonny spike**, which the spec asked for before stage 2 began, came out in Bonny's
favour: Bonny 1.5 and `k8s` 2.8 compile and run on Elixir 1.20 / OTP 28, so the fallback
of hand-written watch-and-reconcile GenServers was never needed. The reconciler is still
self-contained rather than a pipeline step, because a pass can be started by an event, by
the resync, or by one of the operator's own objects being deleted, and all three want the
same thing to happen (DECISIONS 37, 38).

## Deviations

Every judgment call in this stage is DECISIONS 175–198. The ones that change something a
reader of the spec would otherwise expect:

* **DECISIONS 177** — a `command_id` is generated for inputs that arrive without one (a
  watch trigger, a seeded task), so every input in the log has the same shape.
* **DECISIONS 182** — a client-hosted tool asks by default. The consent was to offering
  the tool, not to every call the model makes with it.
* **DECISIONS 186** — the taint is added to the summary projection by the fold rather than
  declared in its empty map, so every recorded fixture hash still holds and no upcaster is
  needed.
* **DECISIONS 191** — a worker with no plane configured does not start the link at all.
* **DECISIONS 196** — the latency done item gives each of its five clients a session of
  its own, for the reason above.
* **DECISIONS 197** — the latency probe reaches its pod through `kubectl port-forward`
  rather than an Ingress; kind installs no ingress controller, and adding one would put
  nginx's latency in the number.

## What writing the tests found

**`input_queued` would have fired three times per input.** `gen_statem` re-delivers a
postponed event on *every* state change, and `thinking -> acting` is a state change.
Everybody watching would have been told the same input was queued once per transition.

**The 200-input test capped itself at forty.** A session's default turn budget is forty
turns, which is a guard against a runaway agent and not against a busy conversation. The
first run looked exactly like a throughput problem.

**A close could discard what arrived with it.** A refused handshake writes the refusal and
then closes, and both land in one read; the client threw the bytes away and reported
`:closed`. Every rejected connection read as "closed" and said nothing about why — which
is what it did when the cluster probe's token was refused for `lifetime_too_long`, a real
refusal hidden behind a useless one.

**A frame is not a line.** The connection waits for a newline and a WebSocket frame does
not carry one, so the handshake sat in the read buffer until it timed out. The two
framings now meet in exactly two places, symmetrically.

**Nothing on a pod started the gateway's connection supervisor.** Both listeners have
always handed their sockets to it. Nothing had ever attached to a real pod, so nothing
had ever found out.

**A test that subscribed after sending.** `PlaneDownTest` waited for an `agent_state` that
had already been published: the turn was over before the subscription existed, and
`agent_state` is ephemeral so there is no replay to catch up on. It passed until the extra
durable append shifted the timing by a few milliseconds.

## Known limitations

**Stage 1.** The CI workflow is written and has never run; there is no remote to run it
on. Everything in it that can run locally does.

**Stage 2.** Live migration of an *active* session between pods is out of scope: a session
moves by going dormant and coming back. A `NetworkPolicy` cannot express a hostname, so
the FQDN egress rules are a wide standard policy plus a precise `CiliumNetworkPolicy`
where Cilium is present — written down rather than hidden.

**Stage 3.** Break-glass access to session content does not exist, by design. GitOps mode
writes a commit and waits; nothing in Troupe applies it.

**Stage 4.**

* **Presence is per-connection, not per-person.** Somebody attached from two machines
  appears twice and leaves once per connection. The protocol carries the subject, so a
  client can collapse them; nothing here does it for them.
* **A client-hosted tool does not survive dormancy.** The registration lives with the
  connection, and a session that goes dormant and comes back has no connection to reach.
  The harness re-offers on reattach, which is a client behaviour rather than a protocol
  one, and the TUI does not do it yet.
* **`tool.invoke` has one timeout, the tool's.** There is no per-connector budget, so a
  slow personal server spends the full tool timeout before the agent hears about it. A
  disconnection is immediate; slowness is not.
* **The latency number is from one node.** kind on a laptop is one kubelet and one
  network namespace; a real cluster adds an Ingress hop and a scheduler. The number is a
  floor rather than a service level.
* **The worker image runs with no plane in the probe.** The measured path is client to
  session actor, which is what the done item asks about, but a pod that is also sealing,
  uploading and reporting has work this does not account for.
* **The GUI harness, remote triggers and A2A are not built.** Section 13 of
  `ARCHITECTURE.md` says what each would cost; the client SDK works from any process that
  can receive messages, and nothing in the protocol assumes a terminal.


# Stage 5 — report

A profile now carries its skills and MCP servers, and every session created on it has
them from its first turn; a session can be created, prompted and left to run with
nobody attached, by a service principal a team owns, and reviewed from a list the plane
can answer without reading a log; and another agent can hand a profile a task through
the A2A facade and get an answer back. The three plans in `docs/plans/` are the design;
this is what was built against them and what proves it.

Everything below was run in a container with PostgreSQL, OpenBao (transit and KV v2)
and MinIO beside it, on 13 September 2026, from a working tree that compiles with
`--warnings-as-errors`, passes `credo --strict`, `troupe.boundaries` and
`troupe.schema.diff`. Nothing here has run on a Kubernetes cluster; the tests that need
one skipped loudly, exactly as they did on the pristine tree, and the failures below are
the same set on both.

```
$ mix compile --warnings-as-errors        # clean
$ mix credo --strict                      # found no issues
$ mix troupe.boundaries                   # boundaries ok: 5 app rule(s), 1 module rule(s), no violations
$ mix troupe.schema.diff                  # schema unchanged: 73 documents
Result: 92 passed             # troupe_protocol   (+9: the bundle contract)
Result: 193/205 passed        # troupe_core       (baseline 180/192: same 12 need bubblewrap or reaper)
Result: 48/57 passed          # troupe_gateway    (baseline identical: 9 need kill, git worktrees, reaper)
Result: 93/94 passed          # troupe_worker     (one timing flake in PlaneLinkTest; passes alone, twice)
Result: 236/245 passed        # troupe_plane      (the 9 enrolment tests need a TokenReview)
Result: 35/47 passed          # troupe_operator   (the same 12 need a cluster)
Result: 45 passed             # troupe_ctl
Result: 30 passed             # troupe_tui
Result: 45 passed             # troupe_a2a        (new)
```

## What had to be built first

**One document, three readers.** The bundle's content was a free-form map of which one
key was ever read. `Troupe.Protocol.Bundle` is now the contract the plane validates at
publish, the worker validates again before materialising, and the panel renders:
schema 1 with agents, skills and MCP servers, schema 0 for what was published before.
The agent-definition parser moved with it into `troupe_protocol` as
`Troupe.Protocol.AgentDefinition`, because the plane has to parse a definition without
depending on `troupe_core`, and core now builds its struct from the same parse.

```
$ mix test apps/troupe_protocol/test/troupe/protocol/bundle_test.exs
Result: 9 passed
```

**An error code the protocol never had.** The plane refused an over-budget create with
`Error.new(:budget_exhausted, …)` since stage 2, and `Troupe.Protocol.Error` had no such
code — a `FunctionClauseError` waiting for the first team to run dry, which no test had
made happen. `budget_exhausted` is `-32014` now, in the error table and in
`PROTOCOL.md`, and the test that trims a slice to what a team has left is the test that
found it.

## The done items

### 1. A session on a profile has the bundle's agent, its skills and its MCP tools

```
$ mix test apps/troupe_plane/test/troupe/plane/bundles_test.exs
Result: 15 passed
$ mix test apps/troupe_worker/test/troupe/worker/bundles_test.exs
Result: 7 passed
$ mix test apps/troupe_core/test/troupe/skills_test.exs
Result: 11 passed
```

Publishing a document with a definition that does not parse, a skill without its
`SKILL.md`, an MCP host outside the cluster policy, or a credential that looks like a
value rather than a name is refused with the reason, and nothing is announced. A
well-formed one is stored with a `summary` so listings do not decode four megabytes,
announced to every pod on the channel as a hash, and fetched by hash over the control
channel; a hash that does not match what was fetched is refused. The worker writes
`bundles/<hash>/` once and never rewrites it; a version a pod never saw is fetched for
the session pinned to it and does not become current. The heartbeat carries the newest
hash, so `bundles.adoption` reports the truth instead of every pod stale.

A definition loaded from the bundle has `source: :bundle` and sits between the built-ins
and the config directory. An agent that lists skills gets one line per skill in its
prompt; the `skill` tool returns the `SKILL.md` body and the file list, and answers
`not_found` for a skill the definition does not list; `skills:/` is a mount kind whose
mode is forced read-only, and `mounts_resolved` records it beside the others.
`session_created` now carries `kind`, `bundle_version` and `origin`; `agent_started`
carries `bundle_version`.

### 2. Publish version 2; a session activated afterwards moves, one still running does not

This is stage 2's done item 11 and 29, unchanged in shape and now reachable with a real
document: `Bundles.resolve/2` still pins at creation and upgrades at activation with
`config_upgraded`, and the tests that proved it in stage 2 still pass with schema 1
content. What is new is that the upgrade changes what a session *has*, because the
definition and the skills come from the pinned directory.

### 3. MCP hosts reach egress and credentials reach pods

```
$ mix test apps/troupe_operator/test/troupe/operator/resources_test.exs
Result: 33 passed
```

A profile with two MCP servers, one with a `secretRef`, produces `TROUPE_MCP_SERVERS` as
one JSON variable and one `secretKeyRef` env var, `optional: true`, under the name the
bundle's `credential_ref` gave it; the secretless server gets no variable. A wildcard
in `allowedEgress` renders as a Cilium `matchPattern`, an exact name as `matchName`. On
publish and on retire the plane writes the channel's servers into every profile's
`spec.mcpServers`, which is how the operator learns of them; the admission policy already
folded MCP hosts into its egress check and was left alone.

### 4. `session.create` with a prompt and no client runs the first turn, once

```
$ mix test apps/troupe_worker/test/troupe/worker/unattended_session_test.exs
Result: 4 passed
$ mix test apps/troupe_core/test/troupe/session/unattended_approvals_test.exs
Result: 2 passed
```

The plane passes `prompt`, `agent`, `terms` and `origin` in `session.activate`; the
worker seeds the prompt as the first task and the fake provider records one request. A
second activation of the same session does not repeat it, because the agent seeds only
when the log has no input. `terms.approvals: deny` logs `approval_requested` and an
`approval_decided deny` with a system actor, and the model reads a denial rather than
waiting for a person who is not there. `terms.max_turns` and `wall_clock_seconds` become
the session's budget.

### 5. A principal can create on its profiles and nothing else

```
$ mix test apps/troupe_plane/test/troupe/plane/harness_test.exs
Result: 23 passed
$ mix test apps/troupe_plane/test/troupe/plane/web_test.exs
Result: 14 passed
```

`POST /auth/exchange` with a client id and secret answers the same token a person gets,
with `kind: "service"`; the principal's `session.create` on its profile is accepted and
on any other is `forbidden`; `admin.overview` is `forbidden`; disabling the principal
makes its next call `unauthenticated`. Sessions it creates carry its subject as owner,
so cost and retention are its team's and every input in the log names it.

### 6. Status the plane can list, and a review that costs no replay

```
$ mix test apps/troupe_plane/test/troupe/plane/control_test.exs
Result: 14 passed
```

A worker's `session.status` lands on the row — status, done reason, pending approvals,
cost — fenced by epoch, and `session.dormant` carries the same fields and releases the
team's budget reservation, which its documentation had always claimed. `sessions.list`
filters on `origin`, `trigger`, `status` and `needs_review`; a row written before
origins existed reads as a person's. `session.review` marks a run seen and audits it.

### 7. A trigger fires once per key, is capped, and the scheduler fires on the minute

```
$ mix test apps/troupe_plane/test/troupe/plane/triggers_test.exs
Result: 14 passed
```

`trigger.fire` twice with one idempotency key creates one session and returns the same
run; a second live run over the concurrency cap is recorded as `skipped` with no session;
the prompt template resolves `{{event.issue.key}}` and renders a missing path as
nothing; the cron parser answers the five-field forms and the scheduler, given a clock,
fires a due trigger exactly once and leaves one that is not due alone. The plane
creates the session through the same `Harness.call` a person's client uses, so every
grant, budget and policy check applies to a trigger.

### 8. A task is a session, an artifact is a published file, input-required is an approval

```
$ mix test apps/troupe_a2a/test/troupe/a2a/card_test.exs      # Result: 4 passed
$ mix test apps/troupe_a2a/test/troupe/a2a/tasks_test.exs     # Result: 20 passed
$ mix test apps/troupe_a2a/test/troupe/a2a/stream_test.exs    # Result: 7 passed
$ mix test apps/troupe_a2a/test/troupe/a2a/artifacts_test.exs # Result: 5 passed
```

Against a stub plane and a fake worker over a real WebSocket: the card for a profile
lists the bundle's skills and its version; `message/send` creates a session with
`origin.kind: a2a` and returns the session id as the task id; `tasks/get` maps row
status onto A2A states; a decision part on a waiting task becomes `approval.respond`,
free text is refused with a hint; an artifact whose bytes do not hash to its id is a
502; a second caller's task is not found; a stream survives a token refresh and
resubscribes from the last sequence the caller saw; the stream cap answers 429.

## The client path, after all of it

The worker image was rebuilt from this tree and the GUI repository's bench run against
it, twenty clients by ten prompts on the fake model: 200 of 200 turns, p95 of 6.9 ms
from `input.send` to the end of the turn, about 1,070 turns a second. The same numbers
as before the stage, which is the point of measuring them.

## Deviations

Each is a numbered entry in `DECISIONS.md`, 221–286. The ones a reader of the plans
would look for:

* **`config.updated` still carries `mcp_servers` for one release**, so a worker from
  the previous image keeps working against a plane from this one.
* **Cron is UTC only.** There is no time-zone database in `mix.lock` and this stage did
  not add a dependency for it; a non-UTC `tz` is refused at `trigger.put`.
* **Budget is re-reserved at activation**, the complement of releasing it at dormancy.
* **`session.grant` pushes `acl.changed` and mirrors the row; it does not append
  `acl_granted` to the log**, because the pod is the only writer of a session's log and
  the push is the ACL mechanism the worker already had.
* **The plane has no push channel to harness clients**, so status changes are columns
  and filters, not a `session_status` event; `fleet` remains the worker's topic.
* **Principal secrets are salted SHA-256**, compared in constant time, because adding a
  password-hashing dependency for a 256-bit random secret buys nothing.
* **The A2A facade's task id is the session id** and it stores nothing; a restart
  recovers everything from `sessions.list`.
* **Push notifications are not built**, and the card says so.

## What writing the tests found

* The `budget_exhausted` error above.
* `Bundles.adoption/2` had always reported every pod stale, because nothing on the
  worker populated the `bundle_hash` claim the plane compared against.
* The operator's `SecretMissing` check reads Secrets in `troupe-system`, while a pod's
  `secretKeyRef` resolves in `troupe-w-<profile>`, so the condition can disagree with
  the pod for the LLM secret as well as for MCP ones. Not changed here: the cluster
  suite creates its secret in `troupe-system` and the operator's RBAC reads there; it
  needs a decision and a cluster run, and it is the first item for the next stage.
* `PlaneLinkTest`'s "reports made while the plane is down are delivered when it returns"
  waits ten seconds for a reconnect and, once in a full run, did not get one; alone it
  passes every time. Left as it is and named here rather than widened.

## Known limitations

* **Nothing has run on a cluster.** The chart lints and renders with the small values
  and with the facade enabled, the operator's resources are unit-tested, and the
  cluster-only tests skip. The end-to-end done items — a pod fetching a bundle from a
  real plane, a principal's cron firing on kind, LiteLLM's gateway calling the facade —
  are the next run of `scripts/remote-up`.
* **`cost_micros` is always zero** in `session.status`, because the summary the worker
  folds has no cost yet; the column and the wire are there for when it does.
* **The panel's bundle editor is structured on the way out and JSON on the way in.**
  The Agents, Skills and MCP pages the plan describes are the CLI's directory publish
  plus a validating textarea for now.
* **Hatchet workflows are not in this repository.** The plane's `trigger.fire` is what
  they call; the in-plane scheduler covers cron without them.
* **A2A field names** follow the specification as of mid-2026 and a handful are noted
  as uncertain in `DECISIONS.md`; the conformance run against LiteLLM's client is where
  any difference will show.

---

# Stage 6 — token accounting

`cost_micros` has been on the wire, in a column and in `session.status` since stage 5,
and it has always been zero. It is not zero any more. A team can be told what it spent,
by session, by model and by person; a session's status carries a cost a review queue can
show without reading a log; and the nightly reconciliation against the gateway now has
something to reconcile.

Part 1 of `docs/plans/stage-6.md` is the design. Nothing else in that plan is built.

Everything below was run on 13 September 2026 in a container with PostgreSQL, OpenBao
and MinIO beside it, from a working tree that compiles with `--warnings-as-errors`.

```
$ mix compile --force --warnings-as-errors   # clean
$ mix credo --strict                         # 5459 mods/funs, found no issues
$ mix troupe.boundaries                      # boundaries ok: 5 app rule(s), 1 module rule(s), no violations
$ mix troupe.schema.diff                     # schema unchanged: 73 documents
$ mix format --check-formatted <changed>     # clean
```

## What was already there, and what was missing

Almost all of it was built and nothing connected it. `usage_records` was append-only and
unique on the gateway's request id; `Ledger.record/1` treated a repeat as a success;
`TeamBudget` kept the running total in process state; the plane handled `usage.record` on
the control channel; `Reconcile` compared a window against the gateway. And
`Troupe.Worker.Plane.Link.usage/2` — the one function that would have fed all of it —
had no callers, in any app, in any test.

What was missing was upstream of that: `Troupe.LLM.Response` had nowhere to put a
gateway's request id or its price, the HTTP adapters threw the response headers away,
and the `llm_response` event carried two integers.

## The done items

### 1. A turn is a ledger row with the gateway's own id and price

```
$ mix test apps/troupe_core/test/troupe/llm/gateway_test.exs \
           apps/troupe_core/test/troupe/session/usage_test.exs \
           apps/troupe_core/test/troupe/log/fold_test.exs
Result: 31 passed
```

`Troupe.LLM.Gateway` reads `x-litellm-call-id` and `x-litellm-response-cost` from the
response, in the shared `finish/1` of both HTTP adapters, and parses the amount with
integer arithmetic over the digits — `8.87` is `8_870_000` micros and not `8_869_999`,
which is what `String.to_float/1` would have made it. A gateway that says nothing leaves
both empty, which is recorded as tokens with no cost rather than guessed at.

`llm_response` now carries `model` and `gateway`, and `Troupe.Session.Usage` is the one
function that turns that event into a ledger row — used by the live path for a single
event and by the catch-up path for a list, so the two cannot disagree. An event written
before this release folds to its real tokens, a cost of zero and a request id of
`seq:<session>:<n>`.

### 2. A pod holds what it owes in a table it may lose

```
$ mix test apps/troupe_worker/test/troupe/worker/usage_test.exs \
           apps/troupe_worker/test/troupe/worker/usage_flow_test.exs
Result: 15 passed
```

`Troupe.Worker.Usage` is a named public ETS ordered set keyed by `{session_id, seq}`.
A `Task` calling `put/2` leaves the collector's mailbox empty, which the test asserts
with `Process.info(pid, :messages)` — the property the whole shape exists for. A plane
that refuses keeps every row; a watermark behind what was sent keeps the rows above it;
the interval drains without anyone asking; and the twenty-thousand-row cap drops and
counts what it dropped.

`usage_flow_test` is the end-to-end one, against real MinIO and OpenBao: a session runs
two turns on the fake provider, and the batch that goes out carries the same request ids
and a cost the session's own summary agrees with. Then the two failure shapes — the
plane refusing, and the collector losing its table — and in the second, a fresh
collector with an empty table folds the log again from the plane's watermark and
produces exactly the two rows.

### 3. The plane records a batch once, and says how far it got

```
$ mix test apps/troupe_plane/test/troupe/plane/usage_test.exs \
           apps/troupe_plane/test/troupe/plane/reconcile_test.exs
Result: 22 passed
```

`usage.batch` over the control channel: two records land, the team's spend moves, and the
answer is `%{"recorded" => 2, "duplicates" => 0, "usage_seq" => 6}`. The same batch again
is `%{"recorded" => 0, "duplicates" => 1, "usage_seq" => 4}` and the total does not move.
A retry of an older batch is still recorded and is told the watermark it did not set. An
`owner_subject` the pod put in the payload is ignored in favour of the row's. A record
with no gateway id is refused and nothing is written. A charge dated an hour in the
future is dated now, so a report can still see it.

`Ledger.breakdown/3` groups a window by model, by owner or by session; `Ledger.Cache`
remembers it for a minute and `TeamBudget` throws it away on the way past, which the test
proves by reading a zero, recording, and reading the new number. Reconciliation gained an
`unmetered` category so a pre-gateway call is not reported as a call billed twice — and
does not make a clean comparison dirty.

### 4. The suites, before and after

```
troupe_core        214/226   (before 193/205: the same 12 need bubblewrap or reaper, plus one known load-only flake)
troupe_worker      109       (before 94)
troupe_plane       248/257   (before 236/245: the same 9 need a TokenReview)
troupe_gateway     48/57     unchanged
troupe_a2a         45        unchanged
troupe_ctl         45        unchanged
troupe_tui         30        unchanged
troupe_operator    35/47     unchanged
```

Forty-eight tests added; every pre-existing failure is the same one it was.
`Troupe.Agent.DelegationTest`'s restart-intensity test failed once in a full run and
passes alone — the flake already named in stage 5's report.

## What writing the tests found

* **`Map.pop/2` returns `{value, rest}`.** The batch handler had `{attrs, seq}` and would
  have handed the ledger a sequence number as its attributes. Elixir's type checker
  caught it at compile time, through the `||` that could then never run.
* **A charge dated in the future is invisible.** The first `breakdown` test failed because
  a fixture timestamped `10:00` was ahead of a container clock reading `00:32`, and
  `occurred_at < to` excluded it. That is not a test problem: a pod with a fast clock
  would write charges no window query would ever return. The plane clamps to now, and
  there is a test for it.
* **The fixture fold hash moved, exactly as expected.** The summary projection gained
  `cost_micros`, so every recorded fixture folded differently.
  `mix troupe.fixtures.record` refuses to overwrite a recorded version, and it is right
  to: a recorded hash is evidence of what a *released* Troupe produced. There are no
  release tags, so 0.2.0 is the in-development set, and it was re-recorded with a new
  `metered_turn` fixture beside `simple_turn` so both an event with a gateway and one
  without stay covered.
* **Two indexes already existed.** The migration tried to create
  `usage_records_team_id_occurred_at_index` and `usage_records_session_id_index`, both of
  which stage 1 created with the table. The migration is one column now.

## Known limitations

* **Nothing has run on a cluster**, which is still the first item on the list. The
  end-to-end test uses real object storage and a real key manager, and a fake plane.
  *(No longer true as of R1j below: it runs on one now, and the first thing it found was
  that no worker could enrol on one. The sentence stands as what was true when written.)*
* **No rollup pipeline and no retention job.** Raw records and a cached aggregate answer
  everything at this volume. The decision this stage owes the next one is the row count
  at which that stops being true.
* **`x-litellm-response-cost` on a streamed response is assumed, not verified.** It was
  the one open question in the plan and the answer given was that cost is streamed. If a
  deployment turns out to send it only on buffered responses, the tokens are still
  recorded and `Reconcile` reports the cost as unmetered — the design degrades to the
  pre-gateway case rather than losing the call.
* **The panel shows spend and does not let anyone act on it.** A team's page carries what
  it spent, what is reserved and the top five models. There is no per-session drill-down
  and no export.
* **The bench was not re-run.** What the turn path gained is one `:ets.insert/2` on a
  path that already does an `fsync` per event, so the cost should be immaterial — but
  "should be" is not a measurement, and the 1,070 turns a second in stage 5's report is
  the last number that was actually taken.

## The admin surface — a fourth rendering, and real configuration

**What was claimed.** That `Troupe.Plane.Admin` is one context with several renderings and
that parity between them is checked rather than remembered; that the console configures the
platform rather than displaying it; and that a setting an operator owns can be changed
without a deploy.

**What was done.**

*A fourth surface.* `POST /mcp` offers the same method table as MCP tools, on the same
bearer token as `/rpc`, dispatched through the same context. `Troupe.Plane.AdminParityTest`
now asserts every context function has an API method, a CLI command **and** a tool, that
every method carries a summary and every argument a description, and that every destructive
method names an argument that must be confirmed. 13 tests in
`apps/troupe_plane/test/troupe/plane/admin_mcp_test.exs` cover the handshake, the schemas
and the confirmation — including that a destructive call without confirmation leaves the
profile in place, which is the assertion that matters.

*Settings that decide something.* `platform_settings` is an override table read through
`Troupe.Plane.Settings`; `Provision.mode/0`, `Admin.actor_for/1` and `Login`'s group claim
read through it, so changing the provisioning mode or the platform admin group takes effect
on the next request rather than at the next rollout. 15 tests prove the ordering that makes
it safe — a stored value overrides the deployment, a reset goes back to the *deployment's*
value and not to this release's default, a value that does not parse falls back rather than
crashing, and a secret is never in the answer.

*A console that configures.* The profile editor renders the whole `WorkerProfile` spec
rather than four fields of it; Overview leads with an attention list sorted worst-first;
Teams edits every field a team has, with a budget bar and the figures beside it. A new
Settings page shows every setting with its value, where that value came from, what changing
it does and when it takes effect — and will not let the group that decides who administers
be saved until a check has passed for the value in the field.

**What it cost to find.** Two real defects, both found by writing the tests rather than by
running the console. `Identity.enable_team/2` put an atom key into a map that arrived from
JSON, which Ecto refuses to cast — so enabling a team with any attributes at all worked from
the panel and raised from the CLI and the API. And `Audit.diff/2` compared only top-level
keys, so every profile change was recorded as one twenty-line object becoming another.

**What is not claimed.** Identity and Integrations are not their own screens; the erase
dialog is a two-step confirmation and not the typed identifier the design specifies; Audit
has no integrity tab. `docs/plans/admin-surface.md` lists what is owed.
---

# R0 and R1 — the floor, in part

What `docs/brief-remote.md` calls R0 and the first parts of R1. Two of R1's five pieces
are built and proven; the rest is named at the end of this section with what is left of
each, because a package listed as done that is not is worse than a package listed as
owed.

## R0 — the corrections

`docs/plans/stage-6.md` §3e cited `tui/connectors.ex:5-8` for an app that was deleted;
it now names the three modules `session_tainted` actually lives in, and the distinction
it draws — a server a *client* registered versus one an *admin* published — is unchanged
and still correct.

`docs/plans/README.md` did not carry the sentence the brief quotes, so the correction was
made where the claim still lives: a preamble saying that the five plans below are history
where they name `apps/troupe_tui` or `apps/troupe_ctl`, and that what carries the
protocol's proof now is `apps/troupe_gateway/test/conformance/conformance.py`.
`DECISIONS.md` 325 records why that was the right shape rather than editing the plans.

`placement.ex:35`'s comment is untouched, as instructed: it is the sentence that
justified the design R3 changes, and it goes in R3's commit.

## A toolchain, before anything that had to be run

Nothing below could be proven on the machine this was written on, which had no Erlang,
no Elixir and no Zig. `dev/toolbox/` builds the three `.tool-versions` names, plus
`inotify-tools` and `bubblewrap` — the difference between the watch and sandbox done
items being proven and being skipped — and `scripts/toolbox` runs a command in it,
joined to the network `scripts/dev-up` already creates.

```
$ scripts/dev-up
postgres  postgres://troupe:troupe@localhost:55432/troupe_plane_dev
minio     http://localhost:59000  (console :59001, troupe / troupe-secret)
openbao   http://localhost:58200  (dev root token: troupe-dev-root)

$ scripts/toolbox elixir --version
Erlang/OTP 28 [erts-16.4.0.5] [source] [64-bit] [smp:32:32] [jit:ns]
Elixir 1.20.4 (compiled with Erlang/OTP 28)

$ scripts/toolbox bwrap --dev-bind / / --unshare-pid echo SANDBOX_OK
SANDBOX_OK
```

The configuration is not forked: `config/config.exs` names `localhost:55432`,
`localhost:59000` and `localhost:58200`, and the container's entrypoint carries those
three loopback ports to the compose network with `socat` rather than keeping a second set
of values in step. `_build` and `deps` are named volumes, because a Linux build and a
host build cannot share either. CI is unchanged and still installs the toolchain
directly.

**Five tests do not pass in a container and are not made to.**
`Troupe.Agent.ResilienceTest`'s OS-pid cancellation test and four gateway tests that
spawn or `kill -9` a daemon (`AutospawnTest`, `RestartTest`) fail here and pass on a
Linux runner. They failed before any of this work — checked by stashing it and running
them again on the same container — and `DECISIONS.md` 328 says so rather than weakening
them until they pass somewhere they were not written for.

## R1a — trigger revisions

A run named a mutable row; it now names an immutable, content-addressed revision.

**Generalised beyond the scheduler**, which is the brief's second correction. The hash
covers the trigger *document* — profile, agent, principal, template, terms, visibility,
review, notify, concurrency and the `source` document itself — and nothing in it says how
a firing arrived. `Triggers.fire/4` resolves once, at the top, and every path reaches it:
the scheduler, `trigger.fire` on `/rpc`, `admin.trigger.run`, and the seven sources
`RELEASE.md` W2 adds. The scheduler learned nothing new.

The four done items in `stage-6.md` §4, and three more the design implies:

```
$ scripts/toolbox mix test apps/troupe_plane/test/troupe/plane/triggers_test.exs
Result: 21 passed
```

| claim | test |
| --- | --- |
| Editing a template creates revision 2; the previous run still reports revision 1 and its text | "an edit makes a revision; the previous run still reports the one it ran" |
| Editing back to the original creates no third revision | "editing back to the original text makes no third revision" |
| Every pre-existing run points at a reconstructed revision 1 | the migration's backfill, and `reconstructed` on the row |
| A firing that overlaps an edit names exactly one revision | "a firing that overlaps an edit names exactly one revision" |
| Switching a trigger off is not a change to what a run would be | "switching a trigger off is not a change to what a run would be" |
| The hash is over the document, so a webhook and a schedule of the same wording differ | "the hash is over the document, not over the row" |
| A run renders from its revision and says which in the listing | "a run renders from its revision, and says which in the listing" |

The session a trigger makes carries `origin.revision` — the hash — so a session found six
weeks later says which wording made it without a join through the run.
`admin.trigger.revisions` is new on the admin API and in `PROTOCOL.md`.

## R1b — entitlements below the profile

`stage-6.md` §2's five done items, and the pod half of them.

```
$ scripts/toolbox mix test apps/troupe_plane/test/troupe/plane/entitlements_test.exs
Result: 12 passed

$ scripts/toolbox mix test apps/troupe_core/test/troupe/skills_test.exs
Result: 15 passed
```

| done item | where it is proven |
| --- | --- |
| A grant with no rows behaves exactly as today | "a grant with no rows offers exactly what the bundle has", plus the existing grant tests unchanged |
| A team entitled to one of two skills gets one in `profiles.list`, one prompt line, `not_found` for the other | "shows one of two skills in the offering…", "narrows the skills a profile may consult, and the prompt says so", "a skill outside the set is not found, exactly as one the profile omits" |
| An agent the team may not run is refused at `session.create` with the names it could have had, before placement or budget | "refuses an agent the team may not run, before placing or budgeting" — which asserts the empty session list and no push, not merely the error |
| A session's set is recorded, and re-resolved on a publish | "is told its set, and the set is what the log will record"; `session_created` and `config_upgraded` both carry `entitlements` |
| A `deny` row beats an `allow` row for the same name | "a list that says allow and deny for one name stores the deny", and `Entitlement.resolve/2`'s doctests |

Two things the plan left to be decided and `DECISIONS.md` 336–337 record. One row per name
is what the unique index holds, so a submitted list saying both collapses to the deny
before it is written; deny-wins then applies to rows that arrive *together* without having
been written together, which is the real case — the union across a person's teams. And a
listing is that union while a session gets one team's set, because a session belongs to
one team and an intersection in a listing would hide something a person can have.

## R1c — one sealer, and a second tenant in the key store

`Sealer` and the `Context` it needs moved from `troupe_worker` into `troupe_protocol`,
beside `Storage`, `Cipher` and `Snapshot`. A move, not a fork: there is one
implementation, and a session sealed by one host restores on the other because there is
nothing else it could be sealed by. The sealer no longer knows how events reach it —
`:subscribe` is a function the host passes in, because the protocol cannot call back into
core, and because getting events into storage is what the process is *for*.

```
$ scripts/toolbox mix troupe.boundaries
boundaries ok: 3 app rule(s), 1 module rule(s), no violations

$ scripts/toolbox bash -c 'cd apps/troupe_worker && mix test'
Result: 109 passed
```

`Troupe.KMS.path/2` takes an owner — a team, or `{:person, subject}` — and R1's fourth
done item is proven against a real OpenBao with real tokens rather than against this
code's belief about it:

```
$ scripts/toolbox mix test apps/troupe_protocol/test/troupe/kms/open_bao_test.exs
Result: 13 passed
```

* *a pod's KMS token cannot read a key under `people/`* — "a pod cannot read a key under
  people/, and a person cannot read one under teams/", with a token carrying
  `Policy.worker/2`, refused by OpenBao;
* *a person's token cannot read one under `teams/`* — same test, with a token carrying the
  person policy, refused both for another person's key and for a team's;
* *the plane's token can delete metadata under both* — "the plane can destroy metadata
  under both subtrees, and read neither", which also asserts the two reads are forbidden
  first.

**One defect found by writing those tests.** A subject is opaque and `idp|ada` is what
Auth0 puts in `sub`. That is a fine path segment and an invalid request target, so a
person's key failed at the HTTP client with `:invalid_request_target` and never reached
OpenBao. A key path is a *logical* path — the policy matches it unencoded and the store
files the secret under it — so the encoding belongs in the adapter, segment by segment.
Team paths were unaffected because a team name is `[a-z0-9-]`, which is why it survived
until a person's key was written.

## R1d — the capability that un-gates the client

R1's fifth done item.

```
$ scripts/toolbox mix test apps/troupe_gateway/test/troupe/gateway/daemon_test.exs
Result: 22 passed
```

"private_sessions is false until the daemon can name a person" connects unlinked, asserts
`false`, links an identity, reconnects and asserts `true`. It is computed at every
`initialize` rather than compiled in, and a worker always answers `false` — a private
session is sealed under its person's own key in a subtree no pod credential can reach.
`PROTOCOL.md` §3 now carries the server capability table this was missing.

## R1e — two of the three log fixes

`../troupe-gui/docs/plans/local-and-private-sessions.md` §7 lists three. Two are done and
the third was already there — `session_created.data` has carried `kind` and `owner` since
stage 5.

```
$ scripts/toolbox mix test apps/troupe_core/test/troupe/session/reopening_test.exs
Result: 4 passed
```

*A session is created once and opened many times, and the log now says so.* `resume/2` is
`start_session/1` with a session id, so every reopen appended a second `session_created`.
`session_resumed` — in the schema since stage 2, never emitted — carries `dormant_ms` and
`moved`, and `moved` is the field Cursor's warning is about: a snapshot preserves disk and
nothing else.

*A resume whose recorded directory is gone falls back to the restored tree.* Narrowly:
only a session that names itself, only to `<state>/workspaces/<id>`, and only when that
directory already exists. The fourth test asserts the case that must still fail — neither
the directory nor a restored tree — because a fallback that invented a directory would be
doing quietly the thing `Workspace.new/1` refuses to do.

Writing the first of these corrected a comment that had been approximate since stage 1:
`session_created` is not the first event in the file and never was. The tree starts before
it is appended and its own `agent_started` is already in. What it *is* is the event that
says what the session is, which is the claim a rebuild depends on.

## R1f — credentials that belong to a person

`stage-6.md` §3, and the one part of R1 where every interesting claim is a negative one.
So the tests stand the real mechanism up — the plane signs through transit, OpenBao's JWT
auth verifies against the transit key's public half, the policy it issues is templated on
the subject — rather than asserting what this code believes it sends.

```
$ scripts/toolbox mix test apps/troupe_plane/test/troupe/plane/person_credentials_test.exs
Result: 6 passed

$ scripts/toolbox mix test apps/troupe_core/test/troupe/mcp_test.exs
Result: 11 passed

$ scripts/toolbox bash -c 'cd apps/troupe_plane && mix test test/troupe/plane/control_test.exs'
Result: 18 passed
```

| done item | where it is proven |
| --- | --- |
| A profile-mode server behaves exactly as today | `credential_mode` defaults to `profile`; every existing bundle, projection and MCP test passes unchanged |
| A person-mode server with no connection returns `not_connected` with a hint, and the session continues | "answers not_connected, readably, when nobody has connected it" — which also asserts nothing was sent, and that it is `{:ok, …}` rather than an error |
| After a grant and a direct write, the call succeeds and the event records `identity: "person:<subject>"` | "grants an assertion and never a value" writes through the real key manager with a client-exchanged token; "sends the owner's credential, and only for the call" and "says which identity a call would go out as" prove the call and the event |
| A pod holding session A's assertion is refused the slot of session B's owner | "reads that person's slot and is refused everybody else's", refused by OpenBao — and "refuses a session this pod is not holding", refused by the plane, which is the half a key manager cannot decide |
| The plane's logs and audit rows contain no credential value | no value reaches the plane: `grant` takes none and answers none, asserted directly on the answer |
| A bundle setting both a `secretRef` and `person` mode is refused at publish, with the reason | "a server with a Secret and a person's credential is refused at publish" |

**Two things deviate from the plan, both in the same direction.** `me.connections.grant`
answers an assertion rather than a key-manager token, because a token the plane minted is
a token the plane held; and there is no `me.connections.revoke`, because removal uses the
same grant and the plane's policy has no `delete` under a person's connections at all.
`DECISIONS.md` 375–376.

**What is not claimed.** The path from `me.connections.grant` through a real key manager
into a real tool call is proven in two halves rather than one: the grant and the write
against OpenBao, and the call and its event against a mock MCP server with the lookup
injected. Joining them needs a pod, a plane and a key manager at once, which is the
cluster suite's job and not yet done.

## R1g — a deprovision that takes effect

Not in the plan, and found by asking what `User.active` was for. SCIM wrote it. Nothing
read it. A person the identity provider had deprovisioned could sign in, call every
method, and go on doing so — and `Login` wrote `active: true` on *every* login, so the
deprovision lasted exactly until its subject next authenticated.

Three doors, because they are three doors and not one.

| door | what was wrong | what it does now |
| --- | --- | --- |
| Signing in | reactivated whoever it authenticated | refused, and never reactivates. Only somebody nobody has ever deactivated is created active, which is what a deployment with no SCIM means by the word |
| The harness | nothing checked | checked on every call rather than at the door, because a plane token outlives the moment it was issued. It reads the row: the provider's decision reaches us through SCIM, and nothing re-reads a claim |
| `kms.assertion` | nothing checked | refused for a deactivated owner |

The third is the one that mattered. A running session needs nobody to sign in, so
refusing at the harness alone would have left a deprovisioned person's credentials
reachable by any pod for as long as anything they had started kept running —
indefinitely, since a pod refreshes its own token. Refused there, the window is the pod's
existing key-manager lease and no longer.

```
$ scripts/toolbox bash -c 'cd apps/troupe_plane && mix test test/troupe/plane/deactivation_test.exs'
Result: 3 passed

$ scripts/toolbox bash -c 'cd apps/troupe_plane && mix test test/troupe/plane/control_test.exs'
Result: 19 passed
```

**What is deliberately not done.** A deactivated person's sessions keep running. What a
session may still do is the session's question — its history is the team's, and a person
leaving is not a reason to lose it — and what it may do *as them* is the one closed here.
Stopping them is a policy decision with an owner, and `RELEASE.md` W2 already has the
shape of it for service principals. `DECISIONS.md` 380–384.

## R1h — a session that belongs to a person

`../troupe-gui/docs/plans/local-and-private-sessions.md` §4 and §5, the server half. The
plane learns that a private session exists and how far it has got; it does not learn a
profile, a team, a pod or a byte.

```
$ scripts/toolbox bash -c 'cd apps/troupe_plane && mix test test/troupe/plane/private_sessions_test.exs'
Result: 14 passed

$ scripts/toolbox bash -c 'cd apps/troupe_plane && mix ecto.rollback --to 20260915000014 && mix ecto.migrate'
== Migrated 20260915000014 in 0.0s   # down
== Migrated 20260915000014 in 0.0s   # and up again
```

| done item | where it is proven |
| --- | --- |
| A private session's row has no team, no profile and no pod | "creates a row with no team, no profile and no pod" reads the row, not the answer |
| …and cannot have one, by any path | "the database refuses the shape even when nothing else does" — the changeset refuses it *and* a raw `INSERT` that skips every line of Elixir raises on the check constraint |
| Registration is idempotent and a seal does not rewind | "is idempotent on the id, and a seal only moves forward": a retry is one session, and an older `last_seq` replayed after a restart is not a rewind |
| Two devices resuming at once: one wins, the other is told | "one claim wins and the loser is told on its next seal" — both send `epoch: 1`, one moves it, and the loser's *seal* is refused `stale_version` while the winner's succeeds |
| One list shows both kinds, and either alone | "separates a person's own sessions from their team's": `sessions.list` with no filter returns both, `kind: "private"` returns the one |
| A private session is nobody else's | "a private session is nobody else's, team or not" — absent from another person's listing and `not_found` to `session.get` |
| A laptop with no credential seals, lists and reads back | "a laptop seals, lists and reads back through the plane's signatures": `Storage.seal_segment` and `read_segment` through `ObjectStore.Signed`, against the real MinIO |
| …and the plane cannot read what it signed for | the same test reads the object with the plane's own credential and finds ciphertext: the marker string is absent and `Cipher.open/3` with any other key fails |
| A signed URL expires | "a signature stops working when it expires" — signed as of an hour ago with its five minutes, refused by MinIO with a 403; a fresh one is 200. The claim is the store's to make, not ours |
| Signing is confined to the session's own prefix | "signs only keys under this session's prefix" refuses another session's key, a `..` climb out of this one, and a bare key at the root |
| `mix troupe.index.rebuild` sees a private session | "a rebuild finds a private session without reading a byte of it" — epoch, sequence and head hash recovered from the plaintext manifest, with the segment's own metadata asserted *empty* |

**Two deviations from the plan, both recorded.** `origin.kind` stays what started a
session (`user`), and the private/team distinction is a column of its own — `origin.kind`
is validated against three values that answer a different question, and the new column is
where a filter and a check constraint can both reach it. And `visibility` was not reused:
it has defaulted to `private` since the first migration, so selecting private sessions on
it would have returned every unshared team session. `DECISIONS.md` 385–393.

**What writing it found.** `Index.attrs/4` fell back to a `default_profile` of `"unknown"`
for anything storage did not name. A private session cannot have a profile, so a rebuild
would have failed on precisely the sessions a rebuild exists for — silently, into a log
line. `DECISIONS.md` 399.

**What is not claimed here.** This is the plane's half: the transport, the fence, the row
and the signatures, against a real store and a real plane. The daemon's half is R1i
below; the second device — listing a private session there, verifying its chain, restoring
its workspace — is still owed.

## R1i — the daemon's end of a private session

`local-and-private-sessions.md` §4, the sealing half. A laptop holds neither of the two
credentials a pod holds and seals anyway.

```
$ scripts/toolbox bash -c 'cd apps/troupe_gateway && mix test test/troupe/gateway/private_test.exs'
Result: 9 passed

$ scripts/toolbox bash -c 'cd apps/troupe_gateway && mix test'
Result: 69/73 passed        # the four are the container's, named under The gate
```

| done item | where it is proven |
| --- | --- |
| A daemon with no object-storage credential writes a session into the cluster's bucket | "writes a session nobody else can read, through signatures it was handed" — `Storage.seal_segment` through `ObjectStore.Signed`, against the real MinIO, with every URL signed by the fake plane against the same bucket |
| …and nobody else can read it | the same test fetches the object with a keyed store and finds ciphertext: the marker string is absent, and `Cipher.open/3` with any other key fails |
| …and can read its own back | `read_segment` returns the events, which is the half that needs the session key |
| Listing works without a credential | `list_segments` through the signed store, which asks the plane |
| Every seal says how far the session has got | "every seal tells the plane how far the session has got": the row carries `last_seq`, the head hash the sealer computed, and the device |
| The manifest names a person, not a team | the same test: `kind: "private"`, `team: nil`, and `key_path` under `troupe/people/<subject>/sessions/<id>` |
| A device that lost the fence stops | "a device that lost the session stops sealing" — another device takes the row to epoch 2, this one reports epoch 1, is refused, and logs that it has stopped. The row is not merged |
| Claiming is conditional | "claiming bumps the epoch, and a second claim on the old one is refused" |
| The plane token is never written to disk | "the token is held in memory and never written to disk": a restarted `Plane` is unlinked and every call answers `{:error, :unlinked}` |
| A daemon with no plane runs local sessions and refuses private ones cleanly | "a session that cannot be registered is refused, and nothing is lost" |
| `session.create {private: true}` starts one, over a real socket | "a daemon nobody has linked creates the session and says it is not syncing" — the session is created and runs, `session_created` records `kind: "private"`, and `syncing` reports what it is *actually* doing rather than what was asked for |
| A local session is untouched by any of it | "a local session has no sealer, and stopping one is a no-op" |

**What writing it found.** `Sealer` wrote `team: context.team` straight into the plaintext
manifest, and a private session's owner is `{:person, subject}` — a tuple, which `Jason`
refuses. The first private session a daemon ever sealed would have crashed its sealer on
the manifest, after the segment had gone up. `Context.kind/1` and `Context.team_name/1`
answer both, and the kind is what stops a rebuild inventing a profile.
`DECISIONS.md` 404.

**What is not claimed, precisely.** The gateway may not depend on `troupe_plane` — a
boundary rule — so the test cannot mint an assertion, because minting one is signing.
`Private.start/2` takes the exchange as `:key_manager` and the test passes one that
answers a token; the exchange itself is proven in the plane's suite, against a real
OpenBao JWT mount. Joining the two halves needs a pod, a plane, a key manager and a laptop
at once, which is the cluster suite. Nor is the far side of it built: no restore runs on a
second device, and there is no directory binding. `session.create {private: true}` starts
a sealer and `session.archive` seals it, which is the near half.

## R1j — the suite that needs a cluster

`stage-6.md` §5. This is the package `REPORT.md` has been owing since stage 3, and the
first thing to say about it is that it worked: the harness exists, it runs, and within an
hour of existing it had found four defects nobody could have seen without it.

**What was built.** `mix troupe.e2e` runs `apps/troupe_operator/test/e2e/**`, tagged
`:e2e` and excluded from `mix test` always rather than conditionally. It refuses any
kubeconfig context but `kind-troupe-dev` unless told twice, because a suite that deletes
pods is one `KUBECONFIG` away from doing it somewhere real. `Troupe.E2E.World` is the
world: it attaches to a cluster `scripts/remote-up` built and never makes one, it speaks
`kubectl` rather than the `k8s` library the operator uses — a second road to the same API
server, so a wrong RBAC rule is visible — and it mints real ServiceAccount tokens from the
real API server. `scripts/e2e` is the laptop's way in, because `mix` lives in the toolbox
container and the cluster lives on Docker's `kind` network. A `cluster` job runs it on
`main` and on tags and uploads the plane's and the operator's logs on failure.

**The first four bugs arrived before the suite had a single passing test**, simply from
installing onto a cluster that had never had one. They are in the table at the end of this
section with the five that came after.

One of the five is a wrong tool rather than a bug: `kubectl rollout status` was waited on
for a worker StatefulSet, which is `OnDelete` on purpose — a rollout that evicted a pod
holding a session would end the session — and `rollout status` has nothing to say about
anything but `RollingUpdate`.

```
$ scripts/remote-up
==> 8. Where things are
  plane      http://plane.localtest.me:30080
  identity   http://dex.localtest.me:30080/dex   (ada@example.test / troupe)
  workers    ws://<n>.dev.workers.localtest.me:30080/v1/socket
```

**And then the suite failed, which is the point of it.**

```
$ scripts/e2e
  1) test ... enrols on that profile (Troupe.E2E.EnrolmentTest)
     right: {:error, %{"message" => "invalid_params", "data" => %{"reason" =>
              "{:token_review_failed, %K8s.Client.APIError{message: \"Unauthorized\"}}"}}}
Result: 0/4 passed
```

The plane's `TokenReview` was refused by the API server, so no worker could enrol at all.
**The cause was the second of my own fixes above.** Making the plane's ServiceAccount a
`pre-install` hook cured the fresh install and broke every upgrade: Helm deletes and
recreates a hook resource on each run, which gives it a new UID, and a ServiceAccount's
UID is inside every token the kubelet has already handed to a running pod. The upgraded
plane's projected token was silently invalidated. It logged nothing. Workers simply never
appeared. The migration now has an account of its own, held by nothing that outlives the
Job.

**The first diagnosis was wrong, and the way it was wrong is worth keeping.** It read:
*the RBAC is correct and the token works by hand, so the request is going out without it.*
The "works by hand" was `kubectl auth can-i --token=…` against a kubeconfig holding a
client certificate — which authenticated with the certificate and answered `yes` about the
wrong identity entirely. Presented with no other credential
(`kubectl --server --certificate-authority --token`), the same token is refused. A passing
response is not proof that the thing you meant passed; that rule applies to the person
reading the suite as much as to the suite.

## The claims, and what each is proven by

```
$ scripts/e2e
Result: 16/17 passed        # the one is egress, below
```

| claim | fault or witness |
| --- | --- |
| A pod enrols as the profile its namespace names | The plane's fleet listing and the API server's pod list name the same pod — two roads to one fact, rather than one road twice |
| …and cannot claim another | `default/default`, a real token the real API server minted for the right audience, refused after a real `TokenReview`; and the worker's own account projected for the API server rather than the plane, refused as a replay. Both sit beside a positive in the same describe, so neither is satisfied by a plane that refuses everything |
| A pod fetches its bundle by hash and materialises it once | The same content published twice is one directory, asserted by inode and mtime on the pod's disk — a plane's belief about what it sent is not evidence |
| A running session keeps its version; the next one moves | v2 published while a session runs; `session.get` now says which version each is pinned to |
| A session survives its pod being deleted | `kubectl delete pod`, then the log read off the *replacement* over a real WebSocket: an event whose `prev_hash` is the pre-fault head, and every link in the chain checked |
| An MCP credential is a `secretKeyRef`, optional when absent | Four hops no unit test sees together, proven both ways: absent, the pod runs and the variable is unset inside it; present, it is filled in |
| A cron trigger fires on the minute, as a principal, once | A wall clock nobody stubbed, a principal that is not a person, and runs grouped by idempotency key — a run for the *next* minute is correct, and a plain count would call it a double fire |
| A2A `message/send` reaches a pod through the facade | Three deployments, an ingress, the identity provider's token exchanged at the plane, and a session the plane has a row for |
| `helm upgrade` leaves a running session running | The pod's uid and restart count and the session's epoch, because a test that checked only for "still active" would pass on a pod that had been replaced and the session restored |
| Cilium egress admits the bundle's host and refuses everything else | **Not proven.** See below |

**Egress is written, correct, and fails here.** It is a TCP connection the pod attempts,
never a lookup of the policy object — and writing it that way is what found that *no
`remote-up` cluster has ever enforced network policy*. kind's own CNI implements pod
networking and ignores every NetworkPolicy, so the operator's egress rules were accepted
by the API server and enforced by nothing, while `kubectl get networkpolicy` showed a tidy
list.

`scripts/remote-up` now installs Cilium, which is what the chart's `CiliumNetworkPolicy`
is addressed to, with `kubeProxyReplacement` because without it Cilium does not implement
`hostPort` and the ingress quietly stops answering. On this machine that is still not
enough: under Docker Desktop, Cilium starts, reports `policy-enabled: both` for the worker
endpoint, shows the policy Valid — and passes everything, the plane and the object store
included. Everything it says is right and nothing it does is, which is the exact shape
this suite exists to catch.

So `TROUPE_KIND_CNI` defaults to `cilium`, and `default` gets a usable local cluster. The
egress test fails on both, deliberately: a fallback costs a red test and never a false
green. CI's kernel is where this one is settled.

**The brief's two extra claims are not written, and cannot be yet.** A forked session's log
naming its parent's head needs `session_forked`, which is R5; a session sealed by a
non-Kubernetes worker restoring on a pod needs a second provisioner, which is R6. They are
in the table so that those packages land them.

## What the cluster suite found

Nine defects, every one of them invisible to anybody whose cluster already works.

| what | why nobody saw it |
| --- | --- |
| A temp file handed to `kubectl` by a path only one of the two processes understood | Windows hosts only |
| The namespace pre-created without the metadata Helm needs to adopt it | First install only |
| The migration hook running before its own ServiceAccount | First install only |
| …and the fix for that invalidating every running pod's token on upgrade | Upgrades only, and silently |
| `llm-credentials` created only when a key was set, so "workers start but cannot reach a model" was a pod that does not start at all | Always, and the sentence had been false for as long as it had existed |
| `required: true` declared on forty admin arguments and enforced on none — a missing one was a 500 on a public endpoint | Any caller omitting any of them |
| A profile permanently full: the placement actor's count drifted upward and only reloaded for a pod it had never seen | After any pod restart — and *caused* by the dormancy fix earlier on this branch |
| The worker's persistent volume mounted and unused: bundles, segments and workspaces written to the container's ephemeral layer | Always. Nothing was lost; everything was re-fetched on every restart |
| A policy violation put into an error as an Elixir tuple, which `Jason` refuses | Any profile outside policy: a 500 with an HTML body instead of the limit's name |

Two of those were mine, made earlier on this branch. That is the argument for the package
in one line: both fixes were right in the unit suite and wrong on a cluster, and nothing
short of a cluster was going to say so.


## A flake that was a defect

`ControlTest`'s "a pod that restarted gives up the sessions the plane still thought it was
holding" failed about two runs in three, before any of this work.

`Sessions.dormant/1` passed `worker_id: nil` through `put_fields/2`, which drops nils on
purpose — a pod reporting three of four lifecycle fields must not blank the fourth — so
it was silently discarded. A dormant session went on naming the pod it was no longer on
until something else happened to call `Placement.release`, and the test was racing that.
Every other reader filters on `state == "active"`, which is why it took a test asserting
the row directly to see it. `read_only/1` had the same hole.

```
$ for i in 1 2 3 4 5; do scripts/toolbox bash -c \
    'cd apps/troupe_plane && mix test test/troupe/plane/control_test.exs' | grep Result; done
Result: 16 passed
Result: 16 passed
Result: 16 passed
Result: 16 passed
Result: 16 passed
```

## The gate

Every step of `mix check`, plus the schema diff, against the tree as it would be
committed — not against the working tree, because `mix format` run inside a Linux
container rewrites a Windows checkout to LF and `Consistency.LineEndings` then has a
hundred-odd things to say about a difference `git add` undoes. `docs/developer/local-setup.md`
§1.1 has the incantation.

```
$ scripts/toolbox mix format --check-formatted
ok

$ scripts/toolbox bash -c 'MIX_ENV=test mix compile --force --warnings-as-errors'
Generated troupe_a2a app

$ scripts/toolbox mix troupe.boundaries
boundaries ok: 3 app rule(s), 1 module rule(s), no violations

$ scripts/toolbox mix troupe.schema.diff
schema unchanged: 73 documents

$ # credo, against the tree as it would be committed
$ git add -A && TREE=$(git write-tree) && git reset
$ scripts/toolbox bash -c "... git archive $TREE ... mix credo --strict"
5706 mods/funs, found no issues.
credo exit=0
```

```
$ scripts/toolbox mix test
==> troupe_protocol
Result: 99 passed (2 doctests, 97 tests)
==> troupe_operator
Result: 39 passed, 31 excluded        # the 17 e2e are excluded from `mix test` always
==> troupe_plane
Result: 409 passed, 9 excluded
==> troupe_core
  1) test cancellation cancel kills a shell command and its grandchild, verified by OS pid
Result: 231/232 passed (3/3 doctests, 1/1 property, 227/228 tests)
==> troupe_gateway
  1) test ten concurrent clients spawn exactly one daemon
  2) test a stale lock left by a killed client does not block start-up forever
  3) test an idle session stops its tree, and subscribing serves history without starting one
  4) test kill -9 with three sessions: all come back, the mid-turn one interrupted
Result: 69/73 passed (2/2 properties, 67/71 tests)
==> troupe_worker
Result: 109 passed
==> troupe_a2a
Result: 45 passed
```

1001 of 1006 in the unit suite, and 16 of 17 on a cluster.

The five are the container's, named above and in `DECISIONS.md` 328: one OS-pid
cancellation test and four that spawn or `kill -9` a daemon. They failed before any of
this work, on the same container, with this work stashed. The one is egress, which fails
on any cluster that does not enforce network policy and so on every cluster this machine
can run. CI is where both are settled, and nothing here changes what CI runs.

## What R1 still owes

| piece | what is left |
| --- | --- |
| Private sessions, the second device | Creating and sealing one is done and proven on both sides, including through a real daemon socket. What is left is the other end: listing a private session on a second device, downloading and verifying its chain, restoring the workspace tar, and the resume-here / bind-to-directory choice. |
| The cluster suite (`stage-6.md` §5) | Eight of the ten claims pass on a real cluster. Egress is written and fails on any cluster that does not enforce, which is every one this machine can run — it is settled on CI. The brief's two extra claims need `session_forked` (R5) and a second provisioner (R6), and land with those packages. |

Personal credentials are done, bar the end-to-end join named in R1f. Deprovisioning was
not in the plan and is done.

R2 through R9 are untouched.

# R5 — sessions people share

Three pieces: a fork, a share, and presence on a topic of its own. `RELEASE.md` numbers
this W3; the brief numbers it R5.

## R5a — a fork copies, and the copy is the argument

The brief's literal shape is a child whose chain opens at `seq: 0` and whose reader folds
the parent's chain to the fork point and the child's after it. That is a reference, and two
rules already in the design refuse one.

* *A fork is a new session for budget, retention, key and erasure.* A child that had to be
  opened with its parent's key does not have a key of its own in the sense that matters.
* **Erasing a parent leaves the child readable** — done item 3. Erasure destroys the
  parent's objects *and its key*, so a reference breaks on the one operation that must never
  take something else with it.

The brief already says the *workspace* is copied into the child's own prefix. Symmetry did
the rest: the events are too. `Troupe.Sessions.Fork.copy/3` reads the parent's live segments
under the parent's key, opens the child's chain with `session_forked`, and reseals the
parent's events up to `seq` under the child's key with the child's own numbering.

Resealing moves the numbering and nothing else. Each copied event keeps its type, data,
timestamp, actor and agent path; what the original numbering was is in `session_forked`,
which carries the parent's id, the seq forked at and the parent's head hash there.

`DECISIONS.md` 520–529.

```
$ scripts/toolbox mix test apps/troupe_protocol/test/troupe/sessions/fork_test.exs --trace
  * test the copy takes the parent's events up to seq and no further
  * test the copy opens with session_forked, which is where the lineage is written
  * test the copy verifies as a chain of its own
  * test the copy keeps what each event said and changes only its numbering
  * test the copy at no seq at all is a fork at the head
  * test the parent is not written to, and does not learn it was forked
  * test the parent can be erased and the child is still readable
  * test what the child may run is what the parent's session_created recorded, not what is on offer now
  * test what the child may run is nil where the parent recorded nothing, which is not the same as nothing
  * test what a child may run is what the parent recorded, narrowed by what the team has now
  * test what a child may run is nil on either side meaning no restriction, and not an empty set
  * test what a child may run keeps a kind only one side mentions, from whichever side mentions it
  * test the workspace comes from the nearest archive at or before the fork point
  * test the workspace is absent rather than invented when the parent has none before the point
  * test refusals a reason nobody defined
  * test refusals a seq the parent never reached
  * test refusals a parent with no history
  * test refusals forking a session into itself
Result: 18 passed
```

Against real MinIO, not a double: what the layout does with versioning and listings is the
behaviour being relied on.

**The plane's half.** `session.fork` is `session.create` with three columns — it pays its
own budget, gets its own key, is placed like anything else. The pod does the copying,
because it is the only place both keys are ever in memory; the plane names a session and a
number and never sees an event. The instruction rides on `session.activate` rather than a
push of its own, because the copy has to land before the tree starts — a manager restoring
an empty log writes a fresh `session_created` at seq 1 and the copied chain arrives second.

```
$ scripts/toolbox mix cmd --app troupe_plane mix test test/troupe/plane/harness_test.exs
Result: 33 passed
```

The eight new ones there are `session.fork`: the row, the instruction that reaches the pod,
the fork point written down rather than left to drift, a point the parent has not sealed,
control rather than a view, a reason nobody defined, a session nobody may see, a lineage a
client tried to claim for itself, and an import.

## R5b — a share is a link that carries a role

The ACL answers *who is allowed here*, by subject, and it is the right answer when the
person has an account and you know which one. A share answers the other question — *send
them this* — with three properties an ACL entry does not have: it ends, it is revocable on
its own, and it is a secret the plane keeps only a salted digest of.

**Refused at mint, never at use.** That the sharer holds the session, that the role is not
`admin`, that the team allows steering, that the expiry is inside the ceiling — all settled
when the link is made. Redemption asks only what is true of the share.

`DECISIONS.md` 530–540.

```
$ scripts/toolbox mix cmd --app troupe_plane mix test test/troupe/plane/shares_test.exs
Result: 12 passed
```

Done item 6 — *a link the team's grant would not admit is refused at mint, not at use* — is
`test is bounded by the team's ACL, through the ladder`, which also shows the converse: a
team that turns steering on makes `control` shareable at the next request rather than the
next edit.

## R5c — presence, on a topic of its own

`presence:<id>` beside `fleet` and `session:<id>`. No `seq`, never persisted, and the first
thing shed when a client stops reading — and shedding it is now a decision about one
subscription rather than something that touches the session's stream.

```
$ scripts/toolbox mix cmd --app troupe_gateway mix test test/troupe/gateway/presence_test.exs
Result: 7 passed
```

Done item 7 is both halves of one test file: `two clients see each other within 500 ms`, and
`presence stops entirely and the durable order is identical on both clients` — the latter
against a socket nobody reads, with a healthy client watching the same two topics beside it,
comparing `{seq, type, data}` lists.

**A real bug came out of it.** Following a session was registered once per *subscription*
rather than once per connection, so a client watching a session and its presence — or one
session at two levels — was in the fan-out twice and received everything twice; and because
`Registry.unregister/2` drops all of a process's entries for a key, dropping one subscription
would have silenced the other. Latent before; the presence topic made it routine.
`Troupe.Events.subscribe/1` is idempotent now and the connection unregisters only when
nothing else still wants the session. `DECISIONS.md` 543.

## The done items

| # | claim | proven by |
| --- | --- | --- |
| 1 | a fork renders parent and continuation as one transcript, and both chains verify independently | `fork_test` — *takes the parent's events up to seq and no further*, *verifies as a chain of its own* |
| 2 | a fork of a session whose team lost an agent still cannot run it | `fork_test` — *narrowed by what the team has now* |
| 3 | erasing a parent leaves the child readable | `fork_test` — *the parent can be erased and the child is still readable* |
| 4 | a private session imported into a team names the private one, and the original is unchanged | **partly** — see below |
| 5 | a watch link cannot send input, a prompt link can, and both appear in the session's log | **partly** — see below |
| 6 | a link the team's grant would not admit is refused at mint, not at use | `shares_test` — *bounded by the team's ACL, through the ladder* |
| 7 | presence within 500 ms; with the queue saturated it stops and the order is identical | `presence_test` — both halves |

## What is not proven here, and why

**Done item 4, the copy half.** An import is `reason: "import"`, and the plane refuses to
ask a pod to make it. A private session's key lives under a path no pod role covers, so no
pod can read the parent whatever it is told to do — the copy belongs to the device that
holds the key. The plane's half is the same as any other fork and is tested: the row carries
the lineage, the child is a team session, the activation carries no fork instruction, and an
import is refused if it does not say which profile it lands on. The client half is the TUI's
and is not in this repository. `DECISIONS.md` 529.

**Done item 5, the "cannot send input" half.** A redeemed share becomes an ordinary session
token at an ordinary role, which is the whole of why there is no share mirror on the pod.
That a `viewer` token cannot steer is already asserted — `collaboration_test`, *an observer
cannot steer* — and is not re-asserted for a token that arrived by link, because it is the
same token. The `share_created` event reaching the session's own log is proven at the push:
`harness_test`, *the pod is told, by id, with no secret in what crosses the wire*.

**The `troupe ctl verify` CLI.** Done item 1 names it. `Event.verify/1` is what the CLI
calls and is what the test calls; the CLI wrapper over a forked pair is not exercised here.

**The cluster.** None of R5 has run on kind. The plane image there is behind R3's later
fixes, R4 and the CI work as well.

## What R2, R3 and R4 still owe this report

This report stops at R1 and resumes at R5. R2 (the webhook and principal work, the budget and
policy ladders, the in-system MCP server), R3 (capacity) and R4 (teams linking to groups) are
built, committed and covered by their own tests, and none of them is written up here. Their
decisions are recorded in `DECISIONS.md`, through to 519; what is missing is this
document's half — the
command output beside each done item.

---

# R8 — the console

## R8a — coverage is asserted, and it produced the backlog

Rule 4 first, because it is the one that stops the console drifting behind the API again
and because it derives the rest of R8 from the code rather than from the document.

`Troupe.Plane.Admin.Console` records, per context function, the screen somebody reaches it
from — **where it is reached today, not where the design says it belongs.** A map of the
plan would pass a coverage test while the button did not exist, which is the exact failure
the test exists to catch. `Troupe.Plane.ConsoleCoverageTest` reads each screen's own source
and fails on a placement the screen does not keep.

Debt is named in two lists that may only shrink: `owed/0` for a method with nowhere to be,
`unbuilt/0` for a screen with nothing of its own yet. The test fails when an entry becomes
satisfied, so closing a gap forces the entry to be deleted.

Its first run named five methods and six screens. Two were closed in the same commit:
`team_enable` on Teams, and `trigger_revisions` on Triggers (done item 5).

## R8b — Policy, and the ladder made visible

Rule 1 and done item 3.

`Live.Settings` becomes `Live.Policy` at `/admin/policy`, keeping `/admin/settings` as the
address it had. The coverage map loses its `policy: Live.Settings` exception rather than
gaining a second one, and the rung chip is a layout component — the ladder is a property of
the value, not of one page.

The effective-configuration view is a table of every rung: the value in force, the rung that
decided it, the ceiling a team may not pass, and one column per rung holding what that rung
said. The winning cell is marked and **says "in force" in words**. A team picker adds the
third rung.

### The three rungs, in a browser

Seeded so the three disagree in the order they disagree in life — the team asks for ninety
days while the platform has no opinion, and the platform then narrows to thirty:

    setting                      in force  decided by  ceiling  deployment  platform       team
    default_erase_after_days     30        platform    30       365         30 · in force  90

Read from the rendered page at `http://localhost:4001/admin/policy` with the team picker on
`delivery`, against a plane serving out of `scripts/dev-up`'s Postgres.

### The refusal quotes the floor

`refusal/1` on the Teams screen already matched the ladder's error — it carries
`reason: "a lower rung may only narrow"` — so the flash said the rule and not the number.
The rule is the half an administrator has worked out from being refused. The clause that
quotes the ceiling now goes first:

    erase_after_days: 200 is wider than 30, which the platform decided. A lower rung may
    only narrow, so ask for less here or change it there.

### The gate

    $ ./scripts/toolbox mix test apps/troupe_plane/test/troupe/plane/panel_test.exs \
        apps/troupe_plane/test/troupe/plane/console_coverage_test.exs
    Finished in 42.5 seconds (0.3s async, 42.2s sync)
    Result: 46 passed

    $ ./scripts/credo
    Checking 444 source files (this might take a while) ...
    6547 mods/funs, found no issues.

    $ ./scripts/toolbox mix troupe.boundaries
    boundaries ok: 3 app rule(s), 1 module rule(s), no violations

Three of those tests are new and are done item 3: the winner and both losers with their
values, the refusal with the floor quoted, and the deployment rung listed as read-only
rather than omitted.

## What R8 still owes

`owed/0` holds `profile_delete` and `budget_explain`. `unbuilt/0` holds review, identity,
integrations, provisioners, budgets and connections. Done items 2, 4, 6, 7, 8, 9 and 10 are
open.

## R8c — Budgets, and which ceiling binds

Done item: the Budgets screen of `control-panel.md`, and `budget_explain` leaves `owed/0`.

Every team's ceiling with the spend against it, and a second panel that asks all three
rungs and names the one that would refuse first. A rung with no ceiling has `:unlimited`
remaining and never binds — absence means everything, and a person with no personal cap
must not be reported as the reason their session was refused.

### What the browser showed that the tests did not

Read from the rendered page at `http://localhost:4001/admin/budgets`, for a team that had
spent nothing:

    delivery    unlimited / 500.00 this period     spent: unlimited    reserved: unlimited

`money/1` reads a zero as *no ceiling*, which is right for a ceiling and wrong for a spend
— and `amount/1`, whose every caller renders a spend or a reservation, went through it. The
same word was on Overview and on Teams. After the fix, the same page:

    delivery    0.00 / 500.00 this period          spent: 0.00         reserved: 0.00

And the explanation, for `grace@example.test` in `delivery`:

    the team's ceiling is what refuses first, with 500.00 left.
      this person's own cap, in every team   person   · no ceiling here
      the team's ceiling  [binds first]      team     · 500.00 left     0.00 / 500.00
      the platform's, or the deployment's    platform · no ceiling here

### The gate

    $ ./scripts/toolbox mix test apps/troupe_plane/test/troupe/plane/panel_test.exs \
        apps/troupe_plane/test/troupe/plane/console_coverage_test.exs \
        apps/troupe_plane/test/troupe/plane/console_assets_test.exs
    Finished in 52.3 seconds (0.3s async, 51.9s sync)
    Result: 58 passed

    $ ./scripts/credo
    6572 mods/funs, found no issues.

Five of those are new: every team's ceiling with its figures, which rung binds and the two
that do not, a rung with no ceiling reported as nothing refusing, and — walking Overview,
Teams and Budgets — no amount anywhere rendering as the word `unlimited`.

## R8d — Provisioners, and the grant that is refused

Done item 8, and the last of R6's own done items: *a profile on an SSH provisioner is
marked unenforced, and granting it to a team without `allow_unenforced_workers` is refused
with the missing guarantee named.*

Four names rather than one word, everywhere. "Unenforced" is not a useful thing to tell
somebody deciding whether their team's work may run on somebody's build box.

### The refusal, against a running plane

`design` has no permission; `laptops` is on the SSH provisioner:

    grant without permission: {:error,
     %Troupe.Protocol.Error{
       code: -32004,
       message: "forbidden",
       data: %{
         profile: "laptops",
         provisioner: "ssh",
         missing: ["admission_policy", "network_policy", "fqdn_egress",
          "disruption_budget"],
         team: "design",
         reason: "this substrate does not provide admission_policy, network_policy,
           fqdn_egress, disruption_budget; a platform admin must allow unenforced workers
           for this team first"
       }
     }}

And nothing was granted, which a refusal that only logged would have missed.

### Both directions of the flag

A team admin setting it for themselves is refused rather than having the value dropped.
Clearing it while the grant it allowed still stands is refused with the profiles named,
because the check at grant time exists to make "granted, and not allowed" impossible and
clearing the flag afterwards would have produced that state by the back door.

That second test found a defect in the check itself: `Enum.find_value/2` reads a `false`
result as *not found*, and `false` is exactly the value being looked for, so clearing the
flag was indistinguishable from an update that never mentioned it. Both checks were
silently unarmed against the one case they exist for.

### The gate

    $ ./scripts/toolbox mix test apps/troupe_plane/test/troupe/plane/provisioner_test.exs \
        apps/troupe_plane/test/troupe/plane/console_coverage_test.exs \
        apps/troupe_plane/test/troupe/plane/admin_parity_test.exs
    Finished in 8.3 seconds (0.2s async, 8.0s sync)
    Result: 42 passed

    $ ./scripts/toolbox mix test apps/troupe_plane/test/troupe/plane/panel_test.exs
    Result: 41 passed

    $ ./scripts/toolbox mix troupe.schema.diff
    schema unchanged: 77 documents

    $ ./scripts/toolbox mix troupe.boundaries
    boundaries ok: 3 app rule(s), 1 module rule(s), no violations

    $ ./scripts/credo
    6602 mods/funs, found no issues.

## R8e — Connections, and the one identity a session has

Done item 9: *Connections lists a personal credential's owner and the session's owner as
two names, and an administrator's attempt to read the credential is refused.*

The screen exists for one sentence people otherwise discover the hard way: a person-mode
server reaches out as the session's **owner**, fixed at activation. Two people attached are
two actors behind one subject. So the session table's column is headed `calls go out as`
rather than `owner` — the consequence, not the field.

### What it shows, against a running plane

    jira
    Slot jira, on dev. The value lives in the key manager under each person, at a path the
    plane's own policy cannot read.

    Not connected
      ada@example.test    nothing in this slot, or the key manager could not be asked.
      grace@example.test  nothing in this slot, or the key manager could not be asked.

    You cannot read or remove any of these. There is no method for either — not a
    permission this screen declines to use.

    Whose identity each session carries
    session    team      profile  calls go out as    state
    s-demo-1   delivery  dev      ada@example.test   active

### The refusal is that there is no method

The mechanism half is already proven against a real OpenBao by
`Troupe.Plane.PersonCredentialsTest`: the plane's own credential cannot read a slot even
knowing exactly where it is. The console half is asserted structurally —
`Troupe.Plane.Connections` exports exactly `assertion`, `connected?`, `grant` and
`known_slot`, and the coverage test fails on a fifth. A method that could fetch a value
fails the build rather than needing a refusal somebody remembered to write.

### The gate

    $ ./scripts/toolbox mix test apps/troupe_plane/test/troupe/plane/console_coverage_test.exs \
        apps/troupe_plane/test/troupe/plane/panel_test.exs
    Result: 58 passed

    $ ./scripts/credo
    6615 mods/funs, found no issues.

    $ ./scripts/toolbox mix troupe.boundaries
    boundaries ok: 3 app rule(s), 1 module rule(s), no violations

## R8f — Audit's integrity tab

Done item 7: *Audit's integrity tab verifies the record chain and names the first bad row
when one byte is flipped.*

The trail had no chain. Each row now carries a digest of its own content and of the row
before it, over canonical JSON and excluding `prev_hash` — the same `Canonical.hash/1` and
the same rule the session log has used since W1, so a verifier recomputes the chain from
stored data alone.

### One byte, changed behind the application

Against a running plane, in `psql`:

    UPDATE audit_events SET subject_id = 'desiqn' WHERE action = 'team.update';
    UPDATE 1

The console, on the next check:

    A row does not verify   [altered]
    checked 3 chained · 6 written before the chain existed and covered by nothing
      · back to 2026-09-17 19:50:02.485511Z

    team.update on desiqn by martin@objective-mj.com, at 2026-09-17T19:50:02.513640Z.

    It says its digest is b7c5fc54cac5 and its content hashes to d0fa09c38409. Everything
    before this row still verifies; nothing after it can be trusted until this is
    explained.

`Troupe.Plane.AuditChainTest` does the same thing in the suite, and also deletes a row from
the middle — which is a *different* answer, `:chain_broken`, because the repair differs: one
row was rewritten, or one is missing.

### What it does not claim

Rows from before the migration are counted as unchained and left alone. Computing hashes
for them now would produce a trail claiming to be verified back to its first row when
nothing verified it. Looking at the page found the same mistake in the wording: with six
such rows and none chained, the panel said *"The chain verifies — 0 rows"*. It now says
nothing is chained yet, and that the chain starts at the next change somebody makes.

### The gate

    $ ./scripts/toolbox mix test apps/troupe_plane/test/troupe/plane/audit_chain_test.exs
    Result: 5 passed

    $ ./scripts/toolbox mix test apps/troupe_plane/test/troupe/plane/panel_test.exs
    Result: 48 passed

    $ ./scripts/toolbox mix troupe.schema.diff
    schema unchanged: 77 documents

    $ ./scripts/credo
    6635 mods/funs, found no issues.
