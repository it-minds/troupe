# Troupe Remote — Architecture

This extends `../troupe/ARCHITECTURE.md`, which still describes one session tree in
one OS process. Everything it says about the agent state machine, the tool contract,
`reaper`, and the failure matrix is unchanged and not repeated here.

What changes is *where a session lives* and *who is allowed to see it*. A session used
to be owned by the process that drew the screen. It is now owned by a daemon, and the
screen is a client — one of several, possibly on another machine. This document is the
contract for that split.

Read it before changing anything under `apps/troupe_gateway/`,
`apps/troupe_protocol/`, or the client apps.

---

## 1. The umbrella

Four releases come out of one umbrella.

| App | In which release | What it is |
| --- | --- | --- |
| `troupe_protocol` | all | The wire: JSON-RPC framing, events, errors, the reference client, endpoint discovery. No sessions, no I/O beyond a socket. |
| `troupe_core` | `troupe`, `troupe_worker` | Sessions: the agent tree, tools, the log, the index. Unchanged in substance from stage 0. |
| `troupe_gateway` | `troupe`, `troupe_worker` | The daemon: transports, connections, subscriptions, scopes, idempotency. |
| `troupe_tui` | `troupe` | The terminal UI, as a protocol client. |
| `troupe_ctl` | `troupe` | The command line, as a protocol client. |
| `troupe_worker` | `troupe_worker` | Stage 2: a worker pod's link to the plane. |
| `troupe_plane` | `troupe_plane` | Stage 3: Phoenix, the harness API, the admin panel. |
| `troupe_operator` | `troupe_operator` | Stage 3: Kubernetes reconciliation. |

### 1.1 Boundaries

```
troupe_protocol ◄──── troupe_tui
       ▲        ◄──── troupe_ctl
       │        ◄──── troupe_plane
       │        ◄──── troupe_operator
       │
   troupe_core ◄──── troupe_gateway ◄──── troupe_worker
```

Three rules, enforced by `mix troupe.boundaries` and therefore by CI:

* **`troupe_tui` and `troupe_ctl` depend only on `troupe_protocol`.** The built-in
  clients get no private access. If the TUI can do something, a third-party client can
  do it too — not by policy, but because there is no other door. This is the rule that
  keeps the protocol honest, and it is the reason it is checked mechanically: a single
  convenient call into `Troupe.Sessions` would quietly make the TUI special, and
  nobody would notice for months.
* **`troupe_plane` never depends on `troupe_core`.** The plane does not run agents. It
  knows *that* a session exists and who may see it; it never holds one.
* **`troupe_operator` depends on neither.** It holds cluster privileges and has no
  public surface. Compromising the plane gets an attacker requests that still pass
  policy, not a cluster.

`mix troupe.boundaries` reads the compiled beams' import chunks rather than each
app's `mix.exs`, because the declared graph and the real one drift: Elixir will
happily compile a call into a sibling app whose beams sit in the same `_build`. Both
are checked — an undeclared call is a violation even when no rule forbids the pair.

---

## 2. Supervision

### 2.1 The daemon

```
Troupe.Gateway.Application            (children only when :autostart)
└── Troupe.Gateway.Daemon             Supervisor, rest_for_one
    ├── Gateway.Commands              idempotency ledger: command_id -> acknowledgement
    ├── Gateway.Connections           DynamicSupervisor, one process per client
    │   └── Gateway.Connection        GenServer, owns one socket
    ├── Gateway.Listener              accepts, hands sockets to Connections
    └── Gateway.Idle                  stops the daemon after a quiet period
```

`rest_for_one`, ordered by dependency: the ledger must outlive the connections that
consult it, connections must exist before the listener can hand them a socket, and the
idle watcher counts connections. A listener crash therefore restarts nothing below it
but does restart nothing above it either — there is nothing above it.

Sessions are **not** in this tree. They live in `Troupe.Application`, the core's own
tree, so the daemon can lose its listener, its connections, or all of them at once
without disturbing a running agent. A client is a subscriber; its death costs a
session nothing. That is the same property the stage-0 TUI had, moved up one level.

Each connection owns a `Gateway.Writer`, a process whose whole job is to call
`:gen_tcp.send/2`. That call blocks once the buffers fill, which is immediately for a
client that has stopped reading, and a connection that blocked there would grow its own
mailbox without limit while its backpressure logic — which lives in that process —
never ran. Writes are a `send/2` to the writer; the connection counts what it has
handed over and stops handing over more past its bounds.

### 2.2 A client

```
Troupe.Ctl.Application
└── Troupe.CLI                       the command; synchronous inside a binary
        │
        ├── UI.Headless              runs in the command's own process
        └── UI.TUI.Server            one linked process, owns a Protocol.Client
```

or, for `troupe daemon`:

```
Troupe.Ctl.Application
└── Troupe.Gateway.Daemon            named in config, resolved at runtime
```

`Troupe.Protocol.Client` is a GenServer that owns a socket and forwards events to its
owner as plain messages. It is deliberately unlinked: a refused connection is an
ordinary outcome a caller handles, not the caller's own exit. Reconnection is equally
deliberately the caller's job — only the caller knows the last `seq` it actually
*processed*, as opposed to the last one that arrived, and resubscribing from the wrong
one is how a client silently loses events.

`Troupe.Protocol.Daemon` finds the local daemon or starts one, serialising concurrent
starts with an `O_EXCL` lock file so ten terminals opening at once produce exactly one
daemon.

---

## 3. The wire

`PROTOCOL.md` is the normative document — it is written for someone implementing a
client with no access to this repository. This section covers only what a *reader of
this code* needs.

### 3.1 Transports

One framing, three transports:

| Transport | Where | Authentication |
| --- | --- | --- |
| Unix socket, NDJSON | `$XDG_RUNTIME_DIR/troupe/daemon.sock`, mode `0600` | the file permissions |
| Loopback TCP, NDJSON | where `AF_UNIX` is unavailable | a random token in a `0600` file |
| WebSocket, one message per text frame | stage 2, remote | a short-lived session token |

Whether `AF_UNIX` works is decided by *trying it*, not by reading `:os.type()`: it is a
property of the OTP build, so a Windows build that has it gets the better path
automatically.

### 3.2 Events

Durable events carry `seq`, `prev_hash`, `ts`, `actor`, `agent`, `type`, `v`, `data`,
and are the session. The hash chains each event to the previous one over canonical
JSON — keys sorted by code point, no insignificant whitespace — computed over the
event *without* its own `prev_hash`. A client can verify the log it was handed without
trusting the server that handed it over.

Ephemeral events (`llm_delta`, `progress`, `presence`, `summary_diff`) have no `seq`,
are never persisted, and may be dropped. Every completed model message also lands as a
durable `llm_response`, so dropping deltas loses nothing but smoothness.

`Session.Log` is the **only** publisher of durable events: it publishes what it has
just written, in the shape it wrote. An agent publishes ephemerals and nothing else.
Without that rule a subscriber sees each fact twice in two slightly different shapes,
and the difference only shows up under replay.

### 3.3 Subscriptions and backpressure

`subscribe` returns `head_seq`, replays durable events from the cursor, then switches
to live delivery with no gap and no duplicate at the boundary. The connection holds
the cursor, so the switch is a single decision in one process rather than a handshake.

A client that does not read is the interesting case. Two budgets, and the difference
between them is the whole policy:

* **Ephemerals** are refused once the client has more bytes outstanding than the
  outbound byte bound allows. That is the memory guarantee — the queue in front of a
  client that will not read cannot grow past it — and dropping deltas costs smoothness
  and nothing else.
* **Durable events** are never dropped to save memory; a client silently missing part
  of its session is the failure this whole design exists to prevent. They are queued
  regardless of bytes and counted, and once more of them are queued than the backlog
  bound allows, the subscription ends with `resync_required` and the last `seq`
  delivered.

Above a mailbox threshold the connection also makes one pass over its own mailbox,
collapsing ephemerals, so a flood becomes one fold rather than one write each.

Nothing in this path ever blocks the publisher. The agent's latency does not depend on
whether anyone is reading — which is asserted, not assumed: a test stalls a real socket
and requires turn latency within 10% of baseline.

### 3.4 The summary projection

Every session tree ends with `Session.Summary`, which folds the session into a compact
snapshot — per-agent state and profile, current todo, active tool, tokens, cost,
pending approvals, last error — and publishes diffs at most four times a second. A
fleet view watching twenty sessions cannot afford twenty detail streams and does not
want them. It is last in the tree on purpose: a projection that could restart an agent
by crashing would be worse than no projection.

### 3.5 Commands

A command is an acknowledgement, never an effect. `input.send` returns
`{"accepted": true}`; what the agent does about it arrives as events. This is what
makes several clients on one session coherent — they all learn what happened the same
way, from the log, rather than one of them learning it from a return value.

Every state-changing command carries a client-generated `command_id`.
`Gateway.Commands` claims it *before* running the command and remembers the
acknowledgement for 30 minutes, so a client that reconnects and retries something it
was unsure about gets the same answer and not a second effect.

### 3.6 Scopes

`observe` reads, `control` steers, `admin` administers. Checked once per method in
`Gateway.Dispatch` against the scopes granted at `initialize`, before anything else
happens.

---

## 4. Session lifecycle, locally

| State | Actor tree | What a subscribe does |
| --- | --- | --- |
| `active` | running | replays, then follows live |
| `dormant` | stopped | serves history from the log; starts nothing |
| `read_only` | stopped | as dormant; activating commands are refused |
| `erased` | gone | `not_found` |

The daemon shuts itself down after a configurable idle period with no clients and no
running sessions. A session goes dormant on its own idle timeout: the tree stops, the
log stays. The next *activating* command restarts the tree by folding the log.

`Troupe.Sessions.Index` holds the listing, and only metadata — workspace, profile,
lifecycle state, counters. Never content. "Live" means a tree that is actually
running: the index monitors each session's supervisor, so a crashed session leaves the
live view immediately and comes back from its log like any other dormant one. Anything
not live is read from disk, which is the copy that survives a restart anyway.

A restart restores every session from its log — but not its actor tree. Sessions come
back dormant and are served from their logs; the first activating command restores the
tree. Starting every session a user has ever had on every daemon start is not a
restoration, it is a stampede.

One that was mid-turn comes back **interrupted**: it makes no model call until an
activating command arrives, unless `resume_on_restart` says otherwise. Anything else
means a crash loop spends money and re-runs shell commands nobody is watching. Its
unfinished tool calls are then closed off as errors naming the interruption, because
the model needs a result for every call it made.

"Did the session come back, or did one agent crash?" is asked of `Session.Log`, whose
lifetime *is* the session tree's. A crashed agent inside a live session still finishes
what it started.

### 4.1 HQ

`troupe hq` is a `fleet` subscriber plus one `session.list`: every session the
principal can see, and every approval waiting on a person. An approval raised in a
session nobody has open is the one that silently stalls for an hour, and a client that
had to open a session to notice would never find it.

---

## 5. Worktrees

A second session in a workspace that already has a live one gets its own git worktree
on `troupe/<slug>`. Without it two agents edit the same checkout and each sees the
other's half-finished work as if it were the user's, which is worse than either of
them failing. `auto` branches only when the workspace is busy; `never` and `always`
are the escapes.

Removal refuses a dirty tree unless forced: uncommitted work in a worktree is usually
the only copy.

---

## 6. Blobs

A tool result over 16 KiB becomes `{"blob": "sha256:…", "size", "preview",
"truncated"}` and is fetched with `blob.get`, which supports byte ranges. Both the
`tool_call_completed` a client renders and the `tool_results` the model is sent carry
the reference; replay resolves it back to text, because the conversation a restarted
agent rebuilds has to be the one the model actually saw.

Blobs are stored under the session directory and deduplicated **within a session
only** — never across sessions. Cross-session dedup would make one session's storage a
probe for another's content, which is exactly the property the remote stages must not
have.

---

## 7. The operator

The operator is the only thing in Troupe with cluster privileges, and it has no public
surface at all. That separation is the point: the plane is internet-facing and may
write exactly two kinds of resource — `WorkerProfile` and `TeamVolume` — so
compromising it gets an attacker requests that still have to pass policy, not a
cluster.

### 7.1 Three custom resources, three owners

| Resource | Scope | Written by | Says |
| --- | --- | --- | --- |
| `TroupePolicy` | cluster | a cluster admin, never the plane | what any profile is *allowed* to ask for |
| `WorkerProfile` | `troupe-system` | the plane | what one pool of workers should be |
| `TeamVolume` | `troupe-system` | the plane | that a team has shared storage |

`WorkerProfile.spec.teams` is a **projection** of the plane's grants, not a second
source of truth: the plane derives it and rewrites it, and nothing else edits it.
Organisational state lives in the plane; infrastructure desired state lives in
Kubernetes; neither is authoritative for the other.

### 7.2 Policy is checked twice, on purpose

`TroupePolicy` is enforced at admission by a `ValidatingAdmissionPolicy` written in
CEL — so a profile outside policy never enters the API server — **and** again by the
operator, which marks it `PolicyViolation` and creates nothing.

Two checks for two different failures. Admission is the one that gives a person an
error at the moment they ask; the operator's is the one that still holds when
admission is unavailable, when the policy tightened after a profile was already
admitted, or when someone edits a resource with the policy CRD temporarily removed.
Neither is redundant, because neither covers the other's case.

### 7.3 What one profile becomes

`Troupe.Operator.Resources.for_profile/2` is a **pure function** from a profile and a
policy to the list of manifests that profile implies. That is where all the interesting
decisions live — naming, addressing, what egress is allowed — so they can be tested
without a cluster, and the reconciler is left with nothing but apply-and-compare.

For profile `dev` in namespace `troupe-w-dev`:

```
Namespace              troupe-w-dev
ServiceAccount         troupe-worker            automount disabled
StatefulSet            troupe-w-dev             OnDelete, one PVC per pod
Service (headless)     troupe-w-dev
Service + Ingress      dev-0, dev-1, …          <ordinal>-<profile>.workers.<domain>
NetworkPolicy          troupe-w-dev             default-deny, then exactly what is needed
PodDisruptionBudget    troupe-w-dev
PersistentVolumeClaim  team-<name>, org         one per granted team volume
```

The ServiceAccount's token is **not** automounted. The pod gets a *projected* token
with audience `troupe-plane` instead, which is what it presents when it enrolls — a
token scoped to one audience cannot be replayed against the Kubernetes API.

`updateStrategy: OnDelete` because a pod holds live sessions. Rolling it on an image
change would kill work in progress, so the profile reports `UpgradePending` and waits
for a drain — see the pod lifecycle below.

### 7.4 Egress

The NetworkPolicy is default-deny in both directions. Ingress comes only from the
ingress controller. Egress goes to exactly six places: the plane's control Service,
OpenBao, the object storage endpoint, the LLM endpoint, the profile's MCP servers, and
its git hosts — plus DNS.

Standard `NetworkPolicy` cannot express an FQDN, so with plain Kubernetes those become
CIDR rules and a documented gap. Where Cilium is present the operator additionally
writes a `CiliumNetworkPolicy` with `toFQDNs`, which is the rule the profile actually
asked for. The gap is recorded rather than hidden, because a policy that silently
allows more than it says is worse than one that admits what it cannot do.

### 7.5 Reconciliation

One reconciler process per `WorkerProfile` and per `TeamVolume`, under a
`DynamicSupervisor`, driven by watch events plus a periodic resync. Reconciliation is
level-triggered and idempotent: it reads the world, computes what should exist, and
applies the difference. A crash therefore means reconciling again from current state,
never replaying a sequence — which is why killing the operator mid-reconcile converges
instead of producing duplicates.

Leadership is a Kubernetes `Lease`. Only the leader reconciles.

---

## 8. The plane

The plane decides *what* may happen and *where*; it never sees what happens. Two
surfaces and one rule: no session content crosses either of them.

### 8.1 The control channel

Workers dial the plane's internal listener — never exposed through ingress — presenting
the projected ServiceAccount token mounted into the pod. The plane validates it with a
`TokenReview`, and the **namespace decides the profile**, so a pod can only enrol as
what it is. Nothing the worker says about itself is trusted for that.

Over the channel: heartbeats, the session *index* (ids, epochs, sequence numbers, head
hashes, byte counts), usage batches, and pushes the other way — activate, dormant,
fence, drain, erase, JWKS rotation, ACL changes. Every push is idempotent, because a
reconnect retries without knowing what landed.

`usage.batch` is the one call whose *answer* is the contract. A pod sends what a
session's model calls cost — one row per call, keyed by the gateway's own request id —
and is told back `usage_seq`, the highest log sequence the ledger has now recorded for
that session. The pod deletes what it was holding up to that number and, at the next
activation, folds its log forward from it. The column moves monotonically
(`greatest(current, offered)`), so a retry of an older batch cannot walk it backwards
and ask a pod to send what is already charged; and it is deliberately *not* fenced on
the epoch, because a pod that has since been fenced still made the calls it is
reporting, and refusing them would lose money rather than protect anything. §15 is what
this is for.

Config bundles are fetched, not pushed. `config.updated` names a channel, a version and
a hash; the worker asks `bundle.fetch {hash}` (or `{channel, version}`) for the document
and verifies the hash before materialising it. The heartbeat's `bundle_hash` is the
newest version the pod holds, which is what `bundles.adoption` compares against the
channel's current version — a pod holding a newer, since-retired version is ahead, not
behind.

A pod is attached to exactly one replica, and rarely the one a harness reached, so
pushes are *routed*: try locally, otherwise ask the other replicas, each of which
answers with a single registry lookup.

### 8.2 The harness API

`me`, `teams.list`, `profiles.list`, `sessions.list`, `session.get`, `session.create`,
`session.open`, `session.pin`, `session.erase`, `token.mint`. A fleet API: it lists what
you may use and hands you an endpoint and a token for a pod. Detail streams go straight
to the worker, which is what keeps the plane out of the data path of a live session.

`session.create` is a sequence of reservations, each of which must be given back if a
later one fails:

    row -> capacity (Placement) -> budget (TeamBudget) -> push to the pod -> token

The row comes first because reserving capacity *places* the session, and a placement is
a conditional write against the row rather than a note in a process — which is what
makes it survive the replica that made it.

`session.open` in `read` mode never activates: a session that woke up because somebody
looked at it would never stay dormant. In `activate` mode the conditional epoch bump is
the decision — exactly one caller wins it, places the session and pushes it to a pod,
and the others wait for that and are handed the same tree.

`profiles.list` says what a session on each profile will have before it is created:
the profile's `channel`, the current `bundle_version` and `bundle_hash`, the `agents` it
may start as (the bundle's primaries, then the built-ins it does not replace), its
`skills` with descriptions, and the names of its `mcp_servers`. `session.create` takes
an optional `agent` from that list; a name not on it is refused with the list, before
anything is placed or budgeted, and the accepted name reaches the pod in
`session.activate`.

`session.create` also takes what a session with nobody attached needs, and a person may
use too:

* `prompt` (≤ 64 KiB) — the first input, sent to the pod in `session.activate` and never
  stored by the plane. Only the first activation carries it; a later one replays the log,
  in which it is already the first input.
* `terms` — `budget_micros` (replaces the default slice, trimmed to what the team has
  left), `max_turns` (1–500), `wall_clock_seconds` (60–86400) and `approvals` (`wait`,
  the default, or `deny`; there is no `auto`). Kept on the row and sent on every
  activation, because the pod applies them to the tree it starts.
* `origin` — `{kind: user | trigger | a2a, …}`, `user` by default; kept on the row and
  recorded by the pod in `session_created.data.origin`.

Every check on these happens before the row exists, so a bad term costs nothing.

The listing carries what the worker reports over the control channel as
`session.status` and in its dormancy report — `status` (`idle`, `thinking`, `acting`,
`waiting`, `done`, `interrupted`), `done_reason`, `pending_approvals` and `cost_micros`
— plus `origin`, `terms`, `reviewed_by` and `reviewed_at`, so a review queue is a
listing and not a replay. `sessions.list` filters on `status`, `origin` (a kind),
`trigger` (a name) and `needs_review` (a trigger's or an A2A caller's session nobody has
marked reviewed). Status reports are fenced on the epoch like seal reports. There is no
plane-side push of these to harness clients: `/rpc` is request and answer, and the
`fleet` topic is the worker's.

Three more methods belong to this API rather than to administration: `session.grant`
(an owner or a team admin lets a subject in; mirrored in the ACL table and pushed to the
pod as `acl.changed`), `session.review` (anybody who can see a session marks it looked
at, on the row and on its run), and `trigger.fire` (a trigger's principal or a team
admin fires it with an idempotency key; the session is created through `session.create`
*as the principal*, so every check applies). Service principals — `svc:<team>/<name>`,
made by a team admin, resolving to a `%User{}` of `kind: "service"` whose only team is
its own — are how a trigger is a caller and not a feature; `Admin.actor_for/1` gives one
no role.

### 8.3 Tokens

JWTs assembled by the plane and signed through OpenBao's transit engine, so the plane
holds no signing key and cannot export one. ES256 over P-256; `kid` is the key's RFC
7638 thumbprint, so the plane and the workers agree on it with nothing kept in step.

`aud` is **the pod's worker id**. A profile has many pods, and an audience naming the
profile would make them interchangeable — which is exactly what a leaked token wants.
Workers verify offline against a cached JWKS, warn with `auth.expiring` two minutes
out, and accept `auth.refresh` on the connection that is already open.

The role in a token is a claim about the moment it was minted. Access is checked *again*
on every command against the ACL mirror the plane pushes, so a revoked collaborator is
refused on their next command even though their token still verifies.

---

## 9. A worker pod

### 9.1 One process per active session, none per dormant one

A pod is expected to be responsible for tens of thousands of sessions with almost all
of them asleep, so dormancy stops the session's manager rather than parking it.
Everything a dormant session *is* lives in object storage, and activation is the only
path back — which is also what makes relocation and PVC loss the same operation, since
neither has anything local to start from.

Within a pod, the manager is where serialisation comes from: two clients activating the
same session reach the same registered process, and the second gets the tree the first
started.

### 9.2 Sealing

A sealer per active session subscribes to its events, keeps the durable ones, and seals
a segment at every turn completion and at least every sixty seconds while anything is
pending. That interval is the whole durability promise: losing a pod's disk costs the
unsealed tail and nothing more.

Upload, *then* report. A segment the plane has been told about but that is not in
storage would let a rebuild claim history it cannot produce; a segment in storage the
plane has not heard of is merely un-anchored, and the next report fixes it. If the plane
is unreachable, sealing carries on and the reports queue.

### 9.3 Dormancy and fencing

Dormancy is: record it, seal, stop the tree, archive the workspace, upload, report,
erase. Erasing comes last and covers both the workspace *and* the local event log —
both are plaintext session content on a PVC, and by then every byte of them is in object
storage under a key the plane cannot read.

Epochs are minted by the plane alone. A pod whose epoch has been passed refuses to
activate at all — checked against the plaintext manifest, before anything is decrypted —
and a running session that is fenced kills its sealer, stops, and discards its cache.

### 9.4 The harness listener

The same gateway code the local daemon runs, with a third endpoint kind. A Unix socket
authenticates by its permissions, a loopback TCP endpoint by a token in a user-only
file, and a pod by a signed token whose audience names it — so the endpoint carries an
authenticator and a guard, and there is one protocol implementation rather than two that
drift.

### 9.5 Draining

Scaling down, restarting for a new image, and an admin drain are the same sequence.
The plane marks the pod draining — in the database, so every replica stops placing on
it, including the ones that never hear about this drain — and pushes. The worker waits
for running turns rather than killing them: a turn halfway through a tool call has an OS
process attached and a model call already paid for. The wait is bounded by the drain
timeout, the same number the pod's `terminationGracePeriodSeconds` comes from, and a turn
still running at the deadline is cancelled — costing the turn in flight and nothing
before it, because everything before it is sealed.

The plane then checks its own index before agreeing the pod is empty. A pod reporting
success while sessions are still assigned to it is exactly the case where believing it
would lose them.

### 9.6 Disk

A pod's caches are the only thing on its volume that grows without bound, so they are the
only thing given up when it fills: least recently used first, above the low watermark,
until back under. **Active workspaces are never evicted** — a cache is a copy of
something already in object storage and an active workspace is the only copy of work in
progress — and a pod that cannot get under the watermark says so and stays above it
rather than reaching for something it must not touch.

### 9.7 Erasure

The plane drives it and does not do it. It holds no credential that can read a session
key and none for object storage; a pod of the session's profile has both, so the plane
asks one. The key is destroyed **first**: once it is gone nothing under the session's
prefix decrypts — not the current objects, not the prior versions a versioned bucket
keeps, not a copy in a backup — so the deletion that follows is tidiness rather than the
security property. A pod that was offline when an erasure ran applies it on enrol,
before serving anything.

---

## 10. Reading old logs

Every durable event carries a schema version. `Troupe.Log.Upcast` brings an old one up
to the current version a step at a time — `1 -> 2 -> 3`, never `1 -> 3` — so adding a
version is one function rather than a revision of every older one. An upcaster may add
and rename, never drop: a replay has to produce what the session actually did.

The hash chain is not recomputed. `prev_hash` covers the event as it was written, and
upcasting changes the in-memory shape rather than the bytes, so a log from an old release
still verifies against what sealed it.

Each released version records fixtures under `test/fixtures/logs/<version>/` with the
fold each produces, and every build replays all of them. The hash is over a *witness* of
the durable event types the agent's replay acts on, because rebuilding an agent needs
things a log does not contain. A test reads the agent's replay clauses out of the source
and asserts the witness still covers them — a blind spot nobody knows about is worse than
a missing test.

Snapshots are cache and are treated like it: one carrying a format this build does not
write, a fold computed by a different build, or bytes that will not decode is discarded
for a full replay, which produces exactly the same fold.

---

## 11. The admin surface

### 11.1 One context, four surfaces

Every administrative action goes through `Troupe.Plane.Admin`, and the console, the admin
JSON-RPC, `troupe admin` and the admin MCP server are four renderings of that one context.
This is the Forbidden list's "any client, including our own TUI and panel, using anything
but public APIs" made structural: a LiveView that reached into `Fleet` or `Identity`
directly would be a private path into the plane, and a console with a button the CLI
cannot press would be a feature only one kind of operator has.

A test enumerates the context and asserts every function has an API method, a CLI command
and an MCP tool; the boundary checker asserts LiveViews call nothing else. Parity is
checked rather than remembered.

**The fourth surface is for a model.** `POST /mcp` is the same table of methods offered as
MCP tools, authenticated by the same bearer token as `/rpc` and dispatched through the same
context — so a model administers exactly what the person or principal whose token it holds
administers, and a refusal names the role it wanted. `troupe mcp` is a stdio bridge over
that endpoint, so a model can be wired to a plane without a token being pasted into a
configuration file:

    claude mcp add troupe -- troupe mcp

Two things the MCP surface adds that the others do not need. The method table carries a
**summary and a typed argument list** for every method, because a model has the tool
description and nothing else — the description is not documentation about the interface,
it is the interface, and the parity test fails a method that arrives without one. And a
**destructive tool takes a `confirm` argument** that must repeat the identifier exactly:
the erase dialog's rule, which the design gives as the model for everything irreversible,
applied to a caller with no dialog to read.

### 11.1a What the console configures

The console edits the whole of a `WorkerProfile` — scale, model endpoint and credential
reference, egress, per-pod disk, requests and limits, MCP servers, bundle channel — rather
than the four fields it started with. A field that names something outside Troupe carries
what it is for underneath it, in body text; a blank field is *absent* from the resource
rather than empty in it, because `storage: {size: ""}` overrides a CRD default with
nonsense; and nothing is applied until the diff has been read, computed by the same
function that writes the audit record.

There is one apply control rather than the design's two named buttons, because which of
the two happens is not the operator's choice — it is `provisioning_mode`. The button is
named for what will actually happen and the consequence is written above it.

### 11.2 Two roles, and what neither can do

`platform_admin` comes from an IdP group named in configuration — not assigned in Troupe,
because an admin role that Troupe could grant would be a way to escalate inside Troupe.
`team_admin` is assigned per team by a platform admin, and sees only that team.

Neither reads session content. Administration is about profiles, teams, budgets and
lifecycle state; reading what a session *said* requires being on its ACL, and there is no
break-glass. That is why the admin context has no method that returns events, and why the
session views it does have are the same metadata `sessions.list` returns.

### 11.3 Provisioning, two ways

**Direct** — the plane's ServiceAccount may create, update and delete `WorkerProfile` and
`TeamVolume` in `troupe-system`, and read `TroupePolicy`. Nothing else, which
`kubectl auth can-i` is asked to confirm rather than the RBAC being read and believed.

**GitOps** — the plane commits the same manifests to a repository and Flux applies them.
The panel shows `Pending` until the CR's `observedGeneration` catches up with the
generation that was committed, because a commit is not a deployment and showing it as one
would make a failed apply invisible.

Both modes use the same form, the same validation and the same audit trail. The panel
validates against `TroupePolicy` for fast feedback; admission and the operator remain
authoritative, because a panel that was the only check would be a check anyone could
bypass with `kubectl`.

### 11.4 Secrets

The panel stores and shows secret *references* — the name of a secret the cluster holds —
and never a value. A reference to a secret that is not there surfaces as `SecretMissing`
rather than as a pod that will not start for reasons nobody can see. It is reported and
not refused: the reference may be right and the secret on its way, and a profile that
would not reconcile until every secret existed could not be created before them.

### 11.4a Platform settings

Some of what a plane runs on is a *deployment's* decision and some is an *operator's*, and
both used to be environment variables. `Troupe.Plane.Settings` is a registry of the second
kind: a stored row **overrides** the deployment and never replaces it, so a setting with no
row reads whatever the plane was deployed with and resetting one deletes the row rather
than writing today's default into it. The deployment stays the floor, and the worst a bad
setting can do is be reset.

What made this worth building is the failure it repairs. A plane whose `platform_admin_group`
names a group nobody is in has no administrator, no console, and no way back except a Helm
change and a rollout — so the group that decides who may administer is changeable from
behind the break-glass door, and the field will not save until a check has passed *for the
value in the field*: how many people would administer this platform afterwards, and whether
you are one of them.

Settings that could shut the console — the issuer, the client id, the audience — are listed
with their values and are not editable, with the reason written next to them. Secrets are
listed and never shown; what is reported is whether one is set. Values are read through a
five-second cache, so a change is immediate on the replica that made it and within five
seconds everywhere else.

### 11.5 Audit

Every administrative change writes a row with the actor and a diff over the fields that
moved. Not a log line — a row, queryable, because the question an audit answers is asked
months later by somebody who was not there. A refused change writes nothing.

The diff is computed by the same function the profile editor renders its preview with, so
what the form promised and what the trail says cannot differ. It walks nested maps and
keys each change by its path — `spec.llm.model`, not `spec` — because a profile's whole
configuration lives under one field, and a diff that stopped at the top would report
changing a model name as one twenty-line object becoming another.

---

## 12. Several harnesses, one session

### 12.1 One order, and everyone sees it

Every input enters the session actor's mailbox, so the log order *is* the order. There is
no separate sequencing step and no clock involved: two people typing at the same moment
are ordered by which message the actor took first, and every attached client replays the
same log and sees the same answer.

An input that arrives while the agent is busy is postponed by `gen_statem` and produces a
durable `input_queued` — visible to everyone, because a person who typed something and
saw nothing happen needs to know whether it was taken. When the session accepts it,
`input_accepted` carries the author and the `command_id`, which is what lets a client
render optimistically and then reconcile against what actually happened rather than
guessing.

### 12.2 Presence is ephemeral, and structurally so

Joining, leaving, focusing an agent, typing: none of it is in the durable log. That is a
Forbidden-list item, and it holds because presence is published through
`Events.publish_ephemeral/4`, which has no path to `Session.Log` at all — not because
something filters it on the way out.

### 12.3 Client-hosted tools

A harness can offer tools that run on the person's own machine — a personal MCP
connection, usually — to a session it is attached to.

**Consent is a round trip, not a flag.** The worker issues `consent.challenge`, the
harness shows it to the user, and the registration carries what they confirmed. A
registration without it is refused. The point is that the person whose machine will run
the tool has seen the words, rather than a client having set a boolean on their behalf.

**The registering connection owns the tool.** `tool.invoke` is a server-to-client request
over that connection and no other, so a second client cannot invoke a tool it did not
register. The agent's tool task monitors the connection under the tool timeout: a
registrant that disconnects mid-call produces an error result and the agent carries on,
which is the same contract every other tool failure has.

**Every registration taints the session, visibly.** `session_tainted` is durable and the
summary carries it, because a tool running on somebody's laptop is something the other
participants are entitled to know about — and to decide about — rather than something
they find out from the transcript.

---

## 13. Kept possible, then built

The spec ruled three things out and asked that they stay reachable. Stage 5 built two
of them and the third is a client in the GUI repository:

* **Remote triggers** and **the A2A facade** are §14. Both turned out to be what §13 once
  promised: callers of the plane and the worker socket, with a service principal where a
  person used to be, and a few lifecycle facts the plane can now list.
* **A GUI harness** is `troupe-gui`, its own repository, speaking the protocol over a
  WebSocket to pods and, in its second stage, to the daemon on loopback. Nothing in the
  protocol assumed a terminal, and nothing had to change here for it.

---

## 14. What a profile carries, work nobody starts, and other agents

### 14.1 Bundles, skills and MCP servers

A bundle is the description of a profile beyond a model and file tools: agent
definitions, skills, and MCP servers, in one versioned, hashed, immutable document
(`Troupe.Protocol.Bundle`, schema 1; the earlier free-form map is schema 0 and reads as
MCP servers only). The plane validates it at publish — definitions parse, skills carry a
`SKILL.md`, MCP hosts are in the cluster's egress policy, a credential reference looks
like the name of an environment variable and not like a secret — and the worker
validates it again before applying it, because the plane's word is a hash, not a
promise.

A worker keeps every version it has been told about under `bundles/<hash>/`, written
into a scratch directory and renamed into place, so a session pinned to version 3 reads
version 3 however many have been published since. Agent definitions from the bundle
slot into the load order between the built-ins and the config directory, which on a pod
are empty by design, so the bundle is the effective source and `agent_started` names
the version. `profiles.list` renders the same document as what a session will have, and
`session.create agent:` picks one of its primaries.

Skills follow the Agent Skills convention: a directory with a `SKILL.md` whose
frontmatter is its name and description and whose body is instructions, beside any files
they refer to. They are disclosed progressively. An agent whose definition lists them
gets one line per skill in its system prompt; a `skill` tool — a tool *value*, as MCP
tools are — returns the body on demand and logs the call like any tool; the files are
readable through a `skills:/` mount that is read-only to every tool and to the sandbox.
A transcript therefore shows which skill was consulted and when, and a skill cannot
carry anything `shell` could execute from its own directory.

MCP servers have one source of truth, the bundle, and two consumers. Pods re-discover
tools on `config.updated`, apply the bundle's per-server `tools` allowlist at discovery
so an unlisted tool is absent rather than denied, and take `permission` as the tool's
default, which an agent definition may tighten. The operator learns of the servers
because the plane writes them into the `WorkerProfile` on publish: the hosts join the
egress destinations (Cilium rules now say `matchPattern` for wildcards, `matchName`
otherwise), and each server's `secretRef` — `troupe-mcp-<name>`, key `token`, in the
worker namespace, by convention — is injected as the env var its `credential_ref`
names, `optional`, so a missing Secret is the profile's `SecretMissing` condition and
not a pod that will not start. Personal MCP servers are untouched: they arrive through
`tools.register` under consent and are never configured into a pod.

### 14.2 Service principals, unattended sessions and triggers

A service principal is a credential a team owns — `svc:<team>/<name>`, a hashed secret
shown once, a list of the team's profiles it may use. It is not a member and not a
person, which is what keeps team membership the identity provider's business. It
exchanges its secret at `/auth/exchange` for the same plane token a person gets, with
`kind: "service"`, resolves through `Identity` as a user with one team, and gets `:none`
from `Admin.actor_for/1`: it can create and steer sessions on its profiles and do
nothing else. Every input it sends is in the log under its name.

`session.create` now carries what an unattended session needs: `prompt`, which the
plane passes to the pod in `session.activate` and the pod seeds as the first task only
when the log is empty, so a later activation never re-runs it; `terms` — a budget slice
in place of the fixed one, `max_turns`, `wall_clock_seconds`, and `approvals`, which is
`wait` (the approval sits in the log and the queue) or `deny` (the agent is told no, as
a readable result); and `origin`, recorded on the row and in `session_created`. There
is no `auto` for a triggered session's approvals; a trigger that needs none runs a
profile whose bundle sets those tools to `auto`, an admin's versioned act rather than a
flag on a schedule.

Four lifecycle facts left the log and became columns: `status`, `done_reason`,
`pending_approvals` and `cost_micros`, reported by the pod on change and at dormancy.
They are not content — a review queue, an A2A `tasks/get` and a synced session list all
need them, and none of them should have to replay a log to find out. `sessions.list`
filters on `origin`, `trigger`, `status` and `needs_review`; `session.review` marks a
run seen; `session.grant` adds a collaborator from the plane. Dormancy now releases the
team's budget reservation, as its documentation always said.

A trigger is a row the plane stores and a caller fires. `trigger.fire {trigger,
idempotency_key, event}` renders the prompt template, applies the terms, creates and
activates the session as the trigger's principal through the same `Harness` call a
person's client makes — so every grant, budget and policy check applies — grants the
`notify` subjects, and records a run; the same key returns the same run. Concurrency is
capped per trigger and an overlapping run is `skipped`, not a second session. Hatchet is
the executor for schedules with retries and for webhooks, which terminate at Hatchet and
never at the plane, so the plane still has no public trigger surface and makes no
outbound call. A plane without Hatchet fires cron triggers itself from a `:global`
scheduler singleton, the idiom `Placement` and `TeamBudget` already use, which is what
the small release ships with.

### 14.3 The A2A facade

`troupe_a2a` is a fourth server image and a client of the other three surfaces. It
depends on `troupe_protocol` only, holds no database and no credential of its own: a
caller presents a service principal's secret or an identity provider token, the facade
exchanges it and acts as that principal, and a compromised facade holds nothing more
than each caller's short-lived plane token.

The mapping is the one the event model was built for. A task is a session, created
with `origin.kind: a2a` and the session id as the task id; a message is `input.send`;
`message/stream` is a subscription translated into status and artifact updates over
server-sent events; `input-required` is `approval_requested`, answered by a structured
decision part and refused for free text, because text cannot answer a yes or no the log
will record as a decision; artifacts are `published` events and blob references served
through `fs.read` and `blob.get` with the caller's own token, the hash being the artifact
id. The agent card is rendered from `profiles.list`, so Troupe skills are A2A skills and
the card's version is the bundle's.

Two costs are stated rather than hidden. Reading a finished task's history or an
artifact opens a reader on a pod of the profile, because the plane cannot decrypt a
session and never will; `tasks/get` without history is answered from the row alone.
And there are no push notifications yet: they would be the facade's first outbound call
through an egress policy that names model endpoints and git hosts, and when they come
they will be the facade's, to an allowlist, never the plane's.

---

## 15. What a session cost

A team can be told what it spent, by session, by model and by person. The mechanism is
one sentence long: **cost is a fold over the log, not a second thing to write down.**

### 15.1 The event carries it

Every model call already left an `llm_response` in its session's log. That event now
carries three more things: the `model` the turn asked for, and, where a gateway sat in
front of the provider, that gateway's `request_id` and `cost_micros`. Both come from
response headers — `x-litellm-call-id` and `x-litellm-response-cost` — read once in the
shared HTTP path and never from the body, because a body shape differs per provider and
a header does not.

**Troupe has no price table.** The gateway has already priced the call by the time it
answers, and the plane already runs a nightly reconciliation whose whole purpose is to
catch the ledger disagreeing with the gateway. A price of our own would only ever
reconcile against itself. Where a gateway says nothing, the tokens are recorded with a
cost of zero and a request id synthesised as `seq:<session>:<n>` — a shape no gateway
would mint, which is what lets reconciliation count it as *unmetered* rather than as a
call the gateway never made.

Adding keys to an event is what the compatibility rule permits, so an old log still
folds; what it folds to is tokens and no cost, which is what was true.

### 15.2 The pod holds it in a table it may lose

`Troupe.Session.Log` hands every durable event to `Troupe.Session.Usage.observe/2`,
which is a no-op for all but one type and for every deployment with no sink configured
— which is every laptop, because there is no ledger to report to. On a pod the sink is
`Troupe.Worker.Usage`: a named public ETS set keyed by `{session_id, seq}`, written with
`:ets.insert/2` from the log's own process, drained on an interval into one
`usage.batch` per session.

Three properties, in the order they matter:

* **No mailbox on the turn path.** The writer never sends this process a message, so a
  slow flush, an unreachable plane, or a collector that has just crashed and not yet
  restarted cost a turn exactly nothing.
* **Losing the table costs a fold.** Everything in it came from the log and can come
  from the log again. The plane's `usage_seq` says where to start;
  `Log.replay_from/2` and `Usage.records/2` do the rest, and the ledger's uniqueness
  turns any overlap into duplicates rather than charges. A cap of twenty thousand rows
  drops the newest and says so, for the same reason: dropping is recoverable, growing
  is not.
* **The live path and the recovery path are one function.** `Usage.record/2` folds a
  single event as it arrives; `Usage.records/2` folds a list on catch-up. Two callers,
  one definition of what a row is.

Keying on the log's sequence rather than a counter of the collector's own is what makes
the watermark free: there is already exactly one monotonic number per session, and it is
the one the index reports.

### 15.3 The plane records it once

`TeamBudget.record_batch/2` inserts a batch inside the team's own actor — one round trip
rather than five hundred, and still serialised per team — and reports how many were new,
how many were already there, and the highest sequence now accounted for. A duplicate
counts towards that sequence: it is a success, and a watermark that refused to move past
one would ask the pod to send it forever. A record that fails to insert stops the
watermark where it is, so the number never jumps a gap.

The plane names the owner, not the pod. What a worker sends is the call and its cost;
whose session it was comes from the row, which is the same rule enrolment follows. A
charge dated in the future is dated now, because a pod with a fast clock would otherwise
write charges into a window no report asks about.

`Troupe.Plane.Ledger.Cache` is an ETS table owned by a process, in the same shape as the
facade's token cache: sums and breakdowns remembered for a minute, invalidated by
`TeamBudget` — which is already one actor per team, so the invalidation is serialised
without a lock. Losing it costs a query.

### 15.4 What this does not do

There is no rollup pipeline. `usage_records` with its `(team_id, occurred_at)` index and
this cache answer every question the panel asks at the small release's volume, and a
fold-into-buckets job for a table with fifty thousand rows in it is work that looks like
progress. What the next stage owes is the retention decision, not the pipeline.

And `session.status`'s `cost_micros` now moves, because the summary projection folds the
same field — so a review queue shows a cost without anyone reading a log, which is what
§14.2 always claimed and could not yet do.
