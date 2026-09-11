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

## 7. Stages 2–4

Not built yet. The shape they assume:

* **Stage 2 — workers.** The same daemon, in a pod, with a `Plane.Link` process
  holding a control connection to the plane. Session content moves to object storage,
  encrypted with a per-session key held only in the KMS; the PVC holds a disposable
  working copy. Losing the link never affects a running session.
* **Stage 3 — plane and operator.** The plane is Phoenix: harness API, admin panel,
  worker control. Cluster-unique actors registered with `:global` serialise the two
  things that must not overbook — one `Placement` per profile, one `TeamBudget` per
  team. The operator reconciles Kubernetes and has no public surface.
* **Stage 4 — client-hosted tools.** Server-to-client requests, so a tool can run on
  the user's machine while the agent runs in a pod.
