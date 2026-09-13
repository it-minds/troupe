# The Troupe protocol, version 1

This document is complete on its own. Everything needed to write a Troupe client is
here; no Elixir is involved. A reference client in ~180 lines of Python standard
library lives at [`clients/python/troupe_client.py`](clients/python/troupe_client.py).

A Troupe **session** is an agent doing work in a workspace. A **client** attaches to
sessions to watch them and to steer them. The client never holds session state: it
subscribes, replays the log, and follows along. Several clients may attach to the same
session and all see the same thing in the same order.

---

## 1. Transports

The messages are identical on every transport. Only the framing differs.

### Unix socket (local)

`$XDG_RUNTIME_DIR/troupe/daemon.sock`, mode `0600`. Falls back to
`$HOME/.troupe/run/daemon.sock` when `XDG_RUNTIME_DIR` is unset.

Framing is newline-delimited JSON: one JSON value per line, `\n`-terminated, UTF-8.
A message must not contain a raw newline outside a string. Lines may be up to 64 MiB.

Socket permissions are the authentication: if you can open it, you are the user who
owns it, and you get all scopes.

### Loopback TCP (Windows, and anywhere a Unix socket is unavailable)

`127.0.0.1` on a port written to `%LOCALAPPDATA%\troupe\run\daemon.json`, together
with a random 32-byte token:

```json
{"transport": "tcp", "port": 51837, "token": "b64url…"}
```

The file is created with owner-only permissions. Framing is the same NDJSON. The
first message must be `initialize` carrying the token in `auth.token`.

### WebSocket (remote)

`wss://<host>/v1/socket`. One JSON-RPC message per **text** frame; no newline
framing, no batching. Binary frames are not used. The token goes in the
`Authorization: Bearer` header, or in `auth.token` on `initialize` where headers are
unavailable.

---

## 2. Framing: JSON-RPC 2.0

Three message kinds, all with `"jsonrpc": "2.0"`.

**Request** — has an `id`, expects exactly one response.

```json
{"jsonrpc": "2.0", "id": 7, "method": "input.send",
 "params": {"command_id": "c-1a2b", "session_id": "s-9f", "text": "fix the test"}}
```

**Response** — `result` or `error`, never both.

```json
{"jsonrpc": "2.0", "id": 7, "result": {"accepted": true, "command_id": "c-1a2b"}}
{"jsonrpc": "2.0", "id": 7, "error": {"code": -32004, "message": "forbidden",
                                      "data": {"required_scope": "control"}}}
```

**Notification** — no `id`, no response. Events travel this way.

```json
{"jsonrpc": "2.0", "method": "event",
 "params": {"topic": "session:s-9f", "session_id": "s-9f", "event": { … }}}
```

`id` is a client-chosen integer or string, unique while in flight. The server may
send requests to the client (see [tool.invoke](#8-client-hosted-tools)); those carry
a server-chosen `id` and the client must respond.

Batching is not supported. A batch array is rejected with `-32600`.

---

## 3. Handshake

The first message on a connection must be `initialize`. Anything else is rejected
with `not_initialized` and the connection closes.

```json
{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
  "protocol_version": "1",
  "client_info": {"name": "troupe-tui", "version": "0.2.0"},
  "capabilities": {"tools": false, "blobs": true},
  "auth": {"token": "…"}
}}
```

`params.capabilities` declares what the *client* can do:

| capability | meaning |
| --- | --- |
| `tools` | the client can serve `tool.invoke` requests (§8) |
| `blobs` | the client will fetch truncated payloads with `blob.get` |

The response:

```json
{"jsonrpc": "2.0", "id": 1, "result": {
  "protocol_version": "1",
  "server_info": {"name": "troupe-daemon", "version": "0.2.0", "instance_id": "kP3u_2fQ8xA"},
  "capabilities": {"worktrees": true, "watch": true, "remote": false},
  "principal": {"subject": "local:martin", "display_name": "martin", "kind": "user"},
  "scopes": ["observe", "control", "admin"],
  "limits": {"max_message_bytes": 67108864, "outbound_queue": 10000}
}}
```

`server_info.instance_id` identifies the running daemon and changes when it restarts.
A client that reconnects and finds a different one is talking to a daemon that has been
restarted: its own view of any session is stale and it must replay rather than resume.
Without it a restart is indistinguishable from a very quiet session.

**Version negotiation.** `protocol_version` is a major version as a decimal string.
The server answers with the version it will speak. If the client's version is one the
server cannot speak, the server replies with error `unsupported_version` and lists
what it supports in `data.supported`.

Within a major version, changes are **additive only**. A client must ignore unknown
fields and unknown event types, and must not fail on an unknown `capabilities` key.

---

## 4. Events

Events flow as `event` notifications:

```json
{"jsonrpc": "2.0", "method": "event",
 "params": {"topic": "session:s-9f", "session_id": "s-9f", "event": {…}}}
```

The envelope names the session as well as the topic. An event does not carry its own
session id — in the log, the file it lives in says which session it belongs to — and a
`fleet` subscriber receives events from every session on one subscription, so it needs
the envelope to tell them apart.

### Durable events

Persisted, replayable, and totally ordered per session.

```json
{
  "seq": 42,
  "prev_hash": "sha256:7d0c…",
  "ts": "2026-09-11T08:14:22.481Z",
  "actor": {"subject": "local:martin", "kind": "user"},
  "agent": ["root"],
  "type": "tool_call_completed",
  "v": 1,
  "data": {"call_id": "call_3", "name": "edit_file", "ok": true, "content": "Edited lib/a.ex."}
}
```

| field | meaning |
| --- | --- |
| `seq` | monotonic from 1, no gaps, per session |
| `prev_hash` | `sha256:` of the previous event's canonical JSON; `null` at `seq` 1 |
| `ts` | RFC 3339 UTC, millisecond precision |
| `actor` | who caused it; `{"kind": "system"}` when nobody did |
| `agent` | agent path from the root, e.g. `["root"]` or `["root", "explore#1"]` |
| `type` | see the table below |
| `v` | schema version of `data`, starting at 1 |
| `data` | type-specific object |

**Canonical JSON** for hashing: UTF-8, object keys sorted by Unicode code point, no
insignificant whitespace, numbers in shortest round-trip form. The hash covers the
event *without* its own `prev_hash` field. This makes the log independently
verifiable: walk it and recompute.

### Ephemeral events

No `seq`, never persisted, may be dropped under load. They carry `"ephemeral": true`.

```json
{"ephemeral": true, "type": "llm_delta", "agent": ["root"],
 "data": {"kind": "text", "text": "Let me "}}
```

Every completed model message also lands as a durable `llm_response`, so dropping
deltas loses nothing but smoothness.

### Event types

Durable:

| type | `data` |
| --- | --- |
| `session_created` | `workspace`, `profile`, `visibility`, `bundle_version`, `kind` (`team`/`local`), `origin` |
| `agent_started` | `profile`, `mode`, `bundle_version` |
| `agent_restarted` | `replayed_events` |
| `user_input` | `source` (`user`/`watch`/`tui_todo_edit`), `text` |
| `input_queued` | `command_id`, `author`, `text` |
| `input_accepted` | `command_id`, `author` |
| `llm_request` | `model`, `message_count`, `tools`, `profile` |
| `llm_response` | `message`, `usage`, `stop_reason`, `model`, `gateway` |
| `llm_error` | `reason` |
| `tool_call_started` | `call_id`, `name`, `args` |
| `tool_call_completed` | `call_id`, `name`, `ok`, `content` |
| `tool_results` | `results` |
| `todo_updated` | `items`, `source` |
| `profile_switched` | `from`, `to` |
| `delegation_started` | `call_id`, `agent`, `child_path`, `task` |
| `compacted` | `summary` |
| `budget_exhausted` | `limit` |
| `agent_done` | `reason`, `summary`, `limit` |
| `input_after_done` | `source` |
| `cancelled` | — |
| `approval_requested` | `call_id`, `tool`, `args`, `agent_path` |
| `approval_decided` | `call_id`, `tool`, `decision`, `actor` |
| `approval_resolved` | `call_id`, `resolved_by` |
| `session_dormant` | `last_seq` |
| `session_activated` | `epoch`, `pod` |
| `session_resumed` | `dormant_ms`, `moved` |
| `fs_changed` | `path`, `hash`, `size` |
| `acl_granted` / `acl_revoked` | `subject`, `role` |

Ephemeral: `llm_delta`, `progress`, `presence`, `summary_diff`.

`llm_response.gateway` is what the gateway in front of the provider said about the call
it billed: `{"request_id": "…", "cost_micros": 18400}`. Both keys are optional and the
whole object is absent where the gateway said nothing, which is a fact a reader may act
on — tokens with no cost — rather than a cost of zero. A client that shows spend should
treat an absent `gateway` as "not known" and a `cost_micros` of `0` as "free".

Neither key is present in events written before this release. A reader folding an old
log gets the tokens and no cost, which is what was true.

### Payloads are semantic

Payloads never contain ANSI codes, layout, column widths, or any client state.
Text is markdown. A diff is structured hunks, not a rendered patch:

```json
{"path": "lib/a.ex", "hunks": [
  {"old_start": 21, "old_lines": 1, "new_start": 21, "new_lines": 1,
   "lines": [{"op": "del", "text": "  x < t"}, {"op": "add", "text": "  x <= t"}]}
]}
```

Tool calls and results are objects; todo lists are arrays of
`{"id", "content", "status"}`.

### Large payloads

Any `data` field over **16 KiB** is replaced by a blob reference:

```json
{"blob": "sha256:1f3a…", "size": 402113, "preview": "first 4 KiB…", "truncated": true}
```

Fetch it with [`blob.get`](#blobget). Blobs are content-addressed within a session
and never shared between sessions.

---

## 5. Subscriptions

### `subscribe`

```json
{"method": "subscribe", "params": {
  "command_id": "c-7",
  "topic": "session:s-9f",
  "level": "detail",
  "from_seq": 0
}}
```

| param | values |
| --- | --- |
| `topic` | `"fleet"` or `"session:<id>"` |
| `level` | `"summary"` or `"detail"` |
| `from_seq` | optional; replay durable events with `seq > from_seq` |

Result:

```json
{"subscription_id": "sub-3", "head_seq": 128}
```

Then the server replays durable events from the cursor and switches to live delivery
**with no gap and no duplicate at the boundary**: exactly one event per `seq`, in
order, forever.

`from_seq: 0` replays everything. Omitting `from_seq` starts live from `head_seq`
with no replay.

- **`detail`** delivers every event for the session, durable and ephemeral.
- **`summary`** delivers only `summary_diff` ephemerals plus session lifecycle
  events. A summary carries: per-agent state and profile, current todo item, active
  tool, tokens, cost, pending approvals, and last error. Summary diffs are throttled
  to at most 4 per second.
- **`fleet`** carries only session lifecycle events — created, state changes,
  archived, erased — for every session the principal can see. `fleet` ignores
  `from_seq`.

### `unsubscribe`

```json
{"method": "unsubscribe", "params": {"subscription_id": "sub-3"}}
```

### `resync_required`

If a client falls far enough behind that the server's bound for its **durable**
backlog is exceeded, the server drops the subscription and sends:

```json
{"jsonrpc": "2.0", "method": "resync_required",
 "params": {"subscription_id": "sub-3", "topic": "session:s-9f", "last_seq": 91}}
```

The client re-subscribes with `from_seq` set to the last `seq` it actually processed.
Ephemerals are coalesced and then dropped long before this happens; reaching
`resync_required` means durable events could not be delivered.

---

## 6. Commands

Every command takes a client-generated **`command_id`**: a string unique per
connection lifetime (a UUID or `c-<counter>` is fine).

**The response is an acknowledgement, not the effect.** `input.send` returns
"accepted", not the model's answer. Effects arrive as events carrying the
originating `command_id`, which is how a client reconciles an optimistic render.

**Replaying a `command_id` is a no-op** that returns the original acknowledgement.
This makes every command safe to retry after a disconnect.

### Session lifecycle

#### `session.create`
```json
{"command_id": "c-0", "workspace": "/home/me/project", "profile": "build",
 "prompt": "fix the test", "visibility": "private", "worktree": "auto",
 "config": {"auto_approve": false, "watch": true}}
```
→ `{"session_id": "s-9f", "workspace": "/home/me/project", "worktree": null, "branch": null}`

`worktree`: `"auto"` (default) creates a git worktree on `troupe/<slug>` when the
workspace already has a live session; `"never"` reuses the directory; `"always"`
always branches.

`config` carries the session settings a client may choose, and only those:
`auto_approve`, `watch`, `profile`. Everything else in the configuration — where state
is written, which provider is used, what a key is — belongs to the machine the daemon
runs on, and a client cannot move it.

#### `session.list`
```json
{"filter": {"state": ["active", "dormant"], "workspace": "/home/me/project"}}
```
→ `{"sessions": [{"id", "workspace", "branch", "profile", "state", "status",
"tokens", "cost", "created_at", "last_active_at", "pinned"}]}`

#### `session.get` → one session object plus `head_seq`.

#### `session.archive` → `{"session_id"}`; makes a dormant session with no local cache.

#### `session.pin` / `session.unpin` → exempt from retention.

#### `session.erase` → tombstone; irreversible.

### Steering

#### `input.send`
```json
{"command_id": "c-1", "session_id": "s-9f", "text": "make the tests pass"}
```
→ `{"accepted": true}`. If the agent is busy this produces a durable `input_queued`;
when taken it produces `input_accepted`.

#### `turn.cancel` → `{"command_id", "session_id"}`. Valid from any state.

#### `profile.switch` → `{"command_id", "session_id", "profile": "plan"}`. Applied at
the next turn boundary.

#### `approval.respond`
```json
{"command_id": "c-4", "session_id": "s-9f", "call_id": "call_3",
 "decision": "allow"}
```
`decision` is `allow`, `deny`, or `allow_session`. **First response wins**; a later
one receives an `approval_resolved` event naming who resolved it, and has no second
effect.

#### `todo.edit`
```json
{"command_id": "c-5", "session_id": "s-9f", "action": "cancel", "id": "t2"}
```
`action` is `add` (with `content`), `cancel`, or `complete`.

### Reading

#### `blob.get`
```json
{"session_id": "s-9f", "blob": "sha256:1f3a…", "range": [0, 65535]}
```
→ `{"blob", "size", "range": [0, 65535], "encoding": "base64", "data": "…"}`

`range` is an inclusive byte range and is optional; omit it for the whole blob.
Servers may cap a single response and will say so with a shorter `range` than asked.

#### `fs.list`
```json
{"session_id": "s-9f", "path": "lib"}
```
→ `{"path": "lib", "entries": [{"path", "name", "kind", "size"}]}`

`path` is relative to the session's workspace and defaults to its root. `kind` is
`file`, `directory`, or `other`. Paths are resolved through the session's **mount
table**, the same one the agent's own file tools go through, so a client sees exactly
what the agent may see and a path that climbs out of a mount is refused with
`forbidden`.

#### `fs.read`
```json
{"session_id": "s-9f", "path": "lib/a.ex"}
```
→ `{"path", "content", "size", "hash"}`

`hash` is the `sha256:…` of the bytes, the same one `fs_changed` carries, so a client
can check that the file it read is the file the event announced. Reading a directory,
or a file larger than the server's cap, is `invalid_params`.

#### `fs.upload`
```json
{"command_id": "c-9", "session_id": "s-9f", "path": "notes.md", "content": "…"}
```
→ `{"path", "size", "hash"}`

Needs `control`: putting a file into a workspace is steering the session. The write is
recorded as an `fs_changed` event whose actor is the client that uploaded it, not the
session.

#### `workspace.recent` → `{"workspaces": [{"path", "last_used_at", "sessions"}]}`
#### `workspace.search`
```json
{"query": "trou", "limit": 20}
```
→ `{"workspaces": [{"path", "score"}]}`

#### `worktree.list` → `{"worktrees": [{"path", "branch", "session_id", "dirty"}]}`
#### `worktree.remove`
```json
{"command_id": "c-8", "path": "/home/me/project/../project-troupe-abc", "force": false}
```
Refuses a dirty tree with `conflict` unless `force` is true.

### Fleet

#### `fleet.get` → the same shape `subscribe` to `fleet` would replay as a snapshot.
#### `watch.set` → `{"command_id", "workspace", "enabled": true}`. Watch mode is
**exclusive per workspace**; enabling it where another session already watches returns
`conflict`.

### Session states, dormancy, and activation

| `state` | actor tree | what a client can do |
| --- | --- | --- |
| `active` | running | everything |
| `dormant` | stopped | read it; an activating command brings the tree back |
| `read_only` | stopped | read it; activating commands return `forbidden` |
| `erased` | gone | `not_found` |

A session goes `dormant` on its own idle timeout, or on `session.archive`. Its log
stays, and so does everything a client can learn from it: `session.list`,
`session.get`, `blob.get` and `subscribe` all work on a dormant session and start
nothing. That is deliberate — a session that woke up because somebody looked at it
would never stay dormant.

The **activating** commands are `input.send`, `turn.cancel`, `profile.switch`,
`approval.respond` and `todo.edit`. Each brings a dormant session's tree back by
folding its log before taking effect, and the session logs `session_activated`.

### After a restart

A daemon restart is not visible as an event, because nothing was running to write one.
What a client sees is this:

- every session it could see before is still listed, `dormant`;
- a session that was mid-turn reports `"status": "interrupted"`, which is read from
  the log — a tool call that started and never completed, or a request the model never
  answered — and is therefore true before anything has been restarted;
- **no model call is made.** A session comes back interrupted and stays that way until
  an activating command arrives. Resuming instead would mean a crash loop spends money
  and re-runs shell commands nobody is watching. A daemon may be configured to resume,
  and then it re-runs unfinished tool calls and takes the turn it owed.

When an interrupted session is activated, the tool calls that never finished are
closed off as errors naming the interruption, so the conversation the model sees has a
result for every call it made.

---

## 7. Scopes

| scope | grants |
| --- | --- |
| `observe` | `initialize`, `subscribe`, `unsubscribe`, `session.list`, `session.get`, `blob.get`, `fleet.get`, `fs.list`, `fs.read`, `workspace.recent`, `workspace.search`, `worktree.list`, `presence.set` |
| `control` | everything in `observe`, plus `input.send`, `turn.cancel`, `profile.switch`, `approval.respond`, `todo.edit`, `fs.upload`, `tools.register`, `tools.unregister` |
| `admin` | everything in `control`, plus `session.create`, `session.archive`, `session.pin`, `session.unpin`, `session.erase`, `worktree.remove`, `watch.set` |

Locally, the socket's permissions authenticate the user and the connection gets all
three. `troupe ctl token --scope observe` mints a read-only token for a status bar or
a dashboard.

A command outside the connection's scopes returns `forbidden` with
`data.required_scope`.

### Remote connections: session tokens

A connection to a **worker pod** authenticates with a JWT in `params.auth.token` at
`initialize`. The token is minted by the plane, signed through OpenBao's transit engine,
and verified by the worker **offline** against a cached JWKS — the plane is not in the
data path of a live session, so a pod that cannot reach it still decides who may attach.

| claim | meaning |
| --- | --- |
| `sub` | the subject, as the IdP knows them |
| `aud` | **the pod's worker id**, not the profile and not the plane |
| `session_id` | the session this token is for, or absent for a create grant |
| `role` | `owner`, `collaborator`, or `viewer` |
| `scopes` | the scopes the role carries, so a client need not know the mapping |
| `team` | the team the session is billed to |
| `exp` | at most 15 minutes out |

`aud` is what stops a token leaking sideways from being useful: one minted for a `ux`
pod presented to a `dev` pod fails with `unauthenticated` and `data.reason` of
`wrong_audience`.

Roles map onto the same three scopes:

| role | scopes |
| --- | --- |
| `owner` | `observe`, `control`, `admin` |
| `collaborator` | `observe`, `control` |
| `viewer` | `observe` |

The role in a token is a claim about the moment it was minted. **Access is checked again
on every command** against the ACL the plane has pushed to the pod, so a collaborator
whose access is revoked is refused on their next command with `forbidden` and
`data.reason` of `access revoked` — even though the token in their hand still verifies.

### `auth.expiring` (notification, server → client)

```json
{"jsonrpc": "2.0", "method": "auth.expiring", "params": {"expires_at": 1767225600}}
```

Sent two minutes before `exp`. Ephemeral, and about the connection rather than any
session.

### `auth.refresh`

```json
{"jsonrpc": "2.0", "id": 9, "method": "auth.refresh", "params": {"auth": {"token": "…"}}}
```

→ `{"principal", "scopes", "auth": {"expires_at"}}`

Renews on the connection that is already open, so a session in the middle of a turn
never notices. The new token is verified exactly as the first one was, including its
audience: a refresh is not a way to move a connection to a different pod.

Nothing is accepted past `exp`. The next command after it returns `unauthenticated`
with `data.reason` of `expired` and the connection closes; a connection that sends
nothing is closed shortly afterwards regardless, rather than streaming events on a token
that has run out.

---

## 8. Client-hosted tools

A harness can offer tools that run on its own machine — a personal MCP connection,
usually — to a session it is attached to. Three things make that safe enough to be worth
having.

**Consent is a round trip.** `tools.register` with no consent gets `consent.challenge`
back; the harness shows the words to the person and registers again carrying what they
confirmed. A client cannot set a boolean on somebody's behalf.

**The registering connection owns the tool.** `tool.invoke` goes over that connection and
no other. A second client attached to the same session cannot invoke a tool it did not
register, and a registrant that disconnects takes its tools with it.

**The session is tainted, visibly.** `session_tainted` is durable and appears in every
participant's summary, because a tool running on somebody's laptop is something the others
are entitled to know about.

### `tools.register`

Needs `control`.

```json
{"jsonrpc": "2.0", "id": 7, "method": "tools.register", "params": {
  "tools": [
    {"name": "notes.search", "description": "Search my local notes.",
     "schema": {"type": "object", "properties": {"q": {"type": "string"}}}}
  ],
  "consent": {"challenge": "…", "confirmed_by": "ada@example.test"}
}}
```

Without `consent`, the answer is an error carrying the challenge to show:

```json
{"jsonrpc": "2.0", "id": 7, "error": {"code": -32013, "message": "consent_required",
  "data": {"challenge": "…", "prompt": "Let this session run 1 tool on your machine?",
           "tools": ["notes.search"]}}}
```

With it: `{"registered": ["client.notes.search"], "taint": "personal_connector"}`.

Registered tools appear as `client.<name>` under the same allowlists, permissions and
approvals as everything else.

### `tools.unregister` → `{"unregistered": [...]}`

Also happens on its own when the connection drops.

### `tool.invoke` (request, **server → client**)

```json
{"jsonrpc": "2.0", "id": 42, "method": "tool.invoke", "params": {
  "call_id": "call-1", "name": "notes.search", "arguments": {"q": "the thing"}}}
```

The client answers with a result or an error, on the same connection. A client that does
not answer within the tool's timeout gets the call abandoned and the agent gets an error
result — the same contract as any other tool that fails.

### Presence

```json
{"jsonrpc": "2.0", "method": "presence", "params": {
  "subject": "ada@example.test", "state": "focused", "agent": ["root"]}}
```

Ephemeral, always. Presence is published through a path that has no access to the durable
log, so it cannot end up there by accident.

---

## 9. Admin methods

*(Stage 3.)*

Administration is a separate surface from a session: it runs against the **plane**, and
every method goes through one context that the console, `troupe admin` and the admin MCP
server also go through. There is no admin method that returns session content —
administration is about profiles, teams, budgets and lifecycle state, and reading what a
session said requires being on its ACL.

Two roles. `platform_admin` comes from an identity-provider group named in the plane's
configuration; `team_admin` is assigned per team by a platform admin and is scoped to
that team.

| method | role | answers |
| --- | --- | --- |
| `admin.overview` | either | fleet health, active sessions, spend per team |
| `admin.profiles.list` | either | profiles with conditions, pods, load and versions |
| `admin.profile.get` | platform | the CR spec, the policy verdict, published vs reported bundle hash |
| `admin.profile.put` | platform | creates or updates a `WorkerProfile`, returning the diff that was applied |
| `admin.profile.delete` | platform | removes one |
| `admin.pod.drain` | platform | drains a pod, returning what it held |
| `admin.teams.list` | either | teams, with grants, budgets, volumes and retention |
| `admin.team.enable` | platform | makes an IdP group a team |
| `admin.team.update` | either | budget, retention, default visibility |
| `admin.team.grant` / `admin.team.revoke` | platform | a team's access to a profile |
| `admin.sessions.list` | either | session *metadata*, never content |
| `admin.session.erase` | either | erases one, for authorised roles |
| `admin.bundles.list` | either | every version of a channel, each with its `summary` (names of agents, skills and MCP servers) |
| `admin.bundle.get` | either | one version in full: the document, its `detail` (agents with mode and skills, skills with files, MCP servers with the Secret to create), and adoption per profile |
| `admin.bundle.validate` | platform | checks a document the way publishing will, without publishing; `{ok: true, summary, hash}` or `invalid_params` with `data.errors` |
| `admin.bundle.publish` / `admin.bundle.retire` | platform | publish a version — refused as `invalid_params` with `data.errors`, one sentence per problem, when the document is malformed or names an MCP host outside `allowedEgress` — or retire one |
| `admin.mcp.check` | either | `{host, allowed}`: whether the cluster policy lets a pod reach an MCP server's host |
| `admin.audit.list` | either | who changed what, with diffs, each change keyed by its path (`spec.llm.model`) |
| `admin.provisioning.mode` | either | `direct` or `gitops`: whether a profile write changes the cluster or commits for review |
| `admin.settings.list` | either | every platform setting with its value, where that value came from (`stored`, `deployed`, `unset`), what changing it does and when it takes effect; a secret is reported as set and never returned |
| `admin.setting.put` | platform | `{key, value}` — parsed against the setting's declared type and refused if it does not fit, or if the deployment owns it |
| `admin.setting.reset` | platform | `{key}` — drops the stored value, so the setting goes back to what the plane was deployed with |
| `admin.identity.check` | either | four named checks with what each proved and how long it took: provider discovery, its signing keys, the endpoints this plane was given, and who actually carries the platform admin group. `{group}` checks a candidate group *before* it is saved |
| `admin.principals.list` | either | a team's service principals: subject, profiles, last use, whether enabled — never a secret or its hash |
| `admin.principal.create` | either | `{team, name, description, profiles}` → the principal, with `secret` exactly once; `profiles` must be within the team's grants |
| `admin.principal.rotate` / `admin.principal.disable` | either | `{subject}`: a new secret shown once, or the end of the credential; a disabled principal is `unauthenticated` at its next call |
| `admin.triggers.list` | either | `{team}` → a team's trigger definitions |
| `admin.trigger.put` | either | upsert by `team` and `name`; partial on update, so `{team, name, enabled: false}` is a switch-off; returns the trigger and the diff |
| `admin.trigger.delete` | either | `{team, name}`; the runs go with it, the sessions they made do not |
| `admin.trigger.run` | either | `{team, name}`: fire it now, with a manual idempotency key naming the caller and the minute |
| `admin.runs.list` | either | `{team, trigger?, limit?}` → runs newest first, each with its `state` (`created`, `running`, `waiting`, `done`, `failed`, `skipped`) read from the session's status |

Membership is never editable: it comes from the identity provider, and a method to change
it would be a second source of truth for who is in a team.

### The same methods as MCP tools

    POST /mcp

Streamable HTTP, one JSON-RPC message per request, protocol revision `2025-06-18`, and the
same `Authorization: Bearer` token as `/rpc`. Stateless: no session id is issued and none
is required, so any plane replica can answer any request. A notification is answered with
`202` and no body; `GET` and `DELETE` are `405`, because this server neither streams nor
has a session to end.

`initialize`, `ping`, `tools/list` and `tools/call` are implemented; `resources/list` and
`prompts/list` answer with empty lists although neither capability is offered, because
several clients ask regardless.

A tool's name is its method with the dots replaced by underscores — `admin.profile.put`
becomes `admin_profile_put` — mechanically and reversibly, so a call in a model's
transcript can be found in the audit log, where it is written the other way. Every tool
carries a JSON Schema built from the method's declared arguments, with
`additionalProperties: false` so a misspelled field is an error rather than a change that
silently does nothing, and MCP annotations that say whether it reads, writes or destroys.

A **destructive** tool takes a `confirm` argument that must repeat the identifier the
method names — `admin_session_erase` wants `session_id` and `confirm` to be the same
string — and the call is refused if it does not match. A refused or failed call comes back
as `isError: true` with a sentence, not as a JSON-RPC error, so the model can read it and
try something else.

The tool list is *not* filtered by role: a team admin sees every tool and is refused if
they call one they may not, with the role that was wanted named in the refusal.

`troupe mcp` bridges this endpoint over stdio for a client that cannot send a bearer
header, minting and renewing the plane token from the credentials `troupe login` stored:

    claude mcp add troupe -- troupe mcp

### Triggers and principals on the harness side

Three methods on the plane's `/rpc` that are not administrative, because a caller other
than an admin uses them:

| method | scope | who | answers |
| --- | --- | --- | --- |
| `trigger.fire` | control | the trigger's principal, or an admin of its team | `{trigger (name, `team/name` or id), idempotency_key, event}` → the run and, when a session was made, the same `{session_id, endpoint, token}` `session.create` returns. The same key returns the same run and a fresh token; over the trigger's `concurrency` the run is `skipped` and has no session |
| `session.grant` | control | the session's owner, or an admin of its team | `{session_id, subject, role}` (`owner`, `collaborator`, `viewer`; default collaborator) → mirrored in the plane's ACL and pushed to the pod holding the session as `acl.changed` |
| `session.review` | control | anybody who can see the session | `{session_id}` → sets `reviewed_by`/`reviewed_at` on the session and its run, audited as `session.review` |

`POST /auth/exchange` takes `{"client_id": "svc:<team>/<name>", "client_secret": …}` as
well as `{"id_token"}`, and answers the same plane token with `kind: "service"`, `team`
and `profiles` claims.

### Errors

`forbidden` with `data.required_role` when the caller's role is not enough, and
`not_found` for a team a `team_admin` may not see — because whether a team exists is
itself something a person who cannot see it should not learn.

---

## 10. Errors

```json
{"code": -32004, "message": "forbidden", "data": {"required_scope": "control"}}
```

`message` is a stable machine-readable token, not prose. `data` carries detail.

| code | message | meaning |
| --- | --- | --- |
| -32700 | `parse_error` | invalid JSON |
| -32600 | `invalid_request` | not a valid JSON-RPC message |
| -32601 | `method_not_found` | unknown method |
| -32602 | `invalid_params` | missing or malformed parameters |
| -32603 | `internal_error` | unexpected server fault |
| -32001 | `not_initialized` | first message was not `initialize` |
| -32002 | `unsupported_version` | `data.supported` lists what the server speaks |
| -32003 | `unauthenticated` | missing or invalid token |
| -32004 | `forbidden` | `data.required_scope` |
| -32005 | `not_found` | `data.kind`, `data.id` |
| -32006 | `conflict` | e.g. dirty worktree, watch already held |
| -32007 | `stale_version` | `data.expected`, `data.actual` |
| -32008 | `capacity` | no room; `data.retry_after_ms` may be present |
| -32009 | `resync_required` | also sent as a notification (§5) |
| -32010 | `unavailable` | a dependency is down; `data.component` |
| -32011 | `rate_limited` | `data.retry_after_ms` |
| -32012 | `payload_too_large` | `data.limit` |
| -32013 | `consent_required` | `data.challenge`, `data.prompt`, `data.tools` |
| -32014 | `budget_exhausted` | the team has nothing left to reserve; `data.team`, `data.reason` |

Transport-level framing faults close the connection after a best-effort error.

---

## 11. Schemas and compatibility

Machine-readable JSON Schema for every message and event lives in
[`protocol/schema/v1/`](protocol/schema/v1/) and is committed to the repository. It is
generated from the same definitions the server uses, so it cannot drift.

Within major version 1:

- fields may be **added**;
- fields may **not** be removed, renamed, retyped, or newly made required;
- event types may be added; clients must ignore types they do not know;
- enum values may be added; clients must tolerate unknown values.

`mix troupe.schema.diff` compares the committed schemas against the current
definitions and fails CI on any breaking change.

---

## 12. Worked example

```
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocol_version":"1",
    "client_info":{"name":"demo","version":"1"},"capabilities":{}}}
← {"jsonrpc":"2.0","id":1,"result":{"protocol_version":"1","scopes":["observe","control","admin"],
    "principal":{"subject":"local:martin","kind":"user"}, …}}

→ {"jsonrpc":"2.0","id":2,"method":"session.create","params":{"command_id":"c-1",
    "workspace":"/tmp/demo","profile":"build","prompt":"say hello"}}
← {"jsonrpc":"2.0","id":2,"result":{"session_id":"s-1","workspace":"/tmp/demo"}}

→ {"jsonrpc":"2.0","id":3,"method":"subscribe","params":{"command_id":"c-2",
    "topic":"session:s-1","level":"detail","from_seq":0}}
← {"jsonrpc":"2.0","id":3,"result":{"subscription_id":"sub-1","head_seq":2}}
← {"jsonrpc":"2.0","method":"event","params":{"topic":"session:s-1","session_id":"s-1",
    "event":{"seq":1,"prev_hash":null,"type":"session_created", …}}}
← {"jsonrpc":"2.0","method":"event","params":{"topic":"session:s-1","session_id":"s-1",
    "event":{"seq":2,"prev_hash":"sha256:…","type":"agent_started", …}}}

→ {"jsonrpc":"2.0","id":4,"method":"input.send","params":{"command_id":"c-3",
    "session_id":"s-1","text":"say hello"}}
← {"jsonrpc":"2.0","id":4,"result":{"accepted":true}}
← … events: user_input, llm_request, llm_delta (ephemeral), llm_response …

→ {"jsonrpc":"2.0","id":5,"method":"approval.respond","params":{"command_id":"c-4",
    "session_id":"s-1","call_id":"call_1","decision":"allow"}}
← {"jsonrpc":"2.0","id":5,"result":{"accepted":true}}
```

---

## 13. Writing a client

1. Connect and send `initialize`. Keep the negotiated `scopes`.
2. `subscribe` to `fleet` for the session list, and to `session:<id>` at `detail`
   for one session.
3. Fold durable events into your view; render ephemerals as they arrive and expect
   to lose some.
4. Track the highest `seq` you have processed. On reconnect, re-subscribe with
   `from_seq` set to it.
5. Give every command a fresh `command_id`, and retry with the *same* one after a
   disconnect — it is a no-op if the server already saw it.
6. Ignore event types and fields you do not recognise.
