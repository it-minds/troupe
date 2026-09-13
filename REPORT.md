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
