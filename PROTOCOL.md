# The Troupe protocol, version 1

This document is complete on its own. Everything needed to write a Troupe client is
here; no Elixir is involved — and every Troupe client is written this way: the terminal
client and the desktop app under `clients/` speak only this protocol, though they live in
the repository that implements the server. A reference client in ~220 lines of Python
standard library sits in that repository as a test fixture, at
[`apps/troupe_gateway/test/conformance/troupe.py`](apps/troupe_gateway/test/conformance/troupe.py),
with the conformance script CI runs against a real daemon beside it.

A Troupe **session** is an agent doing work in a workspace. A **client** attaches to
sessions to watch them and to steer them. The client never holds session state: it
subscribes, replays the log, and follows along. Several clients may attach to the same
session and all see the same thing in the same order.

---

## 1. Transports

The messages are identical on every transport. Only the framing differs.

### Unix socket (local)

`$XDG_RUNTIME_DIR/troupe/daemon.sock`, mode `0600`. Falls back to
`$HOME/.troupe/run/troupe/daemon.sock` when `XDG_RUNTIME_DIR` is unset, and
`TROUPE_DAEMON_SOCKET` names another path.

Framing is newline-delimited JSON: one JSON value per line, `\n`-terminated, UTF-8.
A message must not contain a raw newline outside a string. Lines may be up to 64 MiB.

Socket permissions are the authentication: if you can open it, you are the user who
owns it, and you get all scopes.

### Loopback TCP (Windows, and anywhere a Unix socket is unavailable)

`127.0.0.1` on a port written to `%LOCALAPPDATA%\troupe\daemon.json` — the same
`troupe/daemon.json` under `$XDG_RUNTIME_DIR` where that is what the platform has, and
`~/.troupe/run` failing both — together with a random 32-byte token:

```json
{"transport": "tcp", "port": 51837, "token": "b64url…"}
```

The file is created with owner-only permissions. Framing is the same NDJSON. The
first message must be `initialize` carrying the token in `auth.token`.

### Loopback WebSocket (graphical clients)

A browser cannot open a Unix socket and cannot open a raw TCP one, so neither of the
transports above is reachable from a page — in a tab, or inside a desktop shell's
webview. The daemon therefore also serves the WebSocket transport on `127.0.0.1`, at a
port the kernel chose and the path `/v1/socket` (`ws://127.0.0.1:<port>/v1/socket`), and
publishes it as a second entry in the same discovery file:

```json
{"transport": "unix", "path": "/run/user/1000/troupe/daemon.sock",
 "ws": {"port": 49312, "token": "b64url…"}}
```

The discovery file is now written for **every** local transport, not only TCP: a Unix
socket records its path there so that one file describes the daemon whichever door a
client uses. `ws.token` is its own token and goes in `auth.token` on `initialize`, the
same as the TCP one.

The upgrade also checks `Origin`, which is a second fence rather than the first — a page
on another origin cannot read the token out of a user-only file. By default the daemon
admits `http://localhost:*`, `http://127.0.0.1:*`, a desktop shell's own origin, the
origin of the plane it is linked to (`identity.link`'s `plane_url`), and any origin in
`ws.origins`, which `troupe-daemon open` adds for the page it opens and which goes with
the entry when the daemon stops; both are read at each upgrade. `TROUPE_ALLOWED_ORIGINS`
replaces that list, the same mechanism and the same variable a worker uses. The wildcard
applies to the port and nothing else, so a rule written for `http://localhost:*` does not
admit `http://localhost.evil.example`. A refused upgrade is answered 403, which a browser
does not show the page, so the daemon logs it as a warning naming the origin.

### WebSocket (remote)

`wss://<host>/v1/socket`. One JSON-RPC message per **text** frame; no newline
framing, no batching. Binary frames are not used. The token goes in the
`Authorization: Bearer` header, or in `auth.token` on `initialize` where headers are
unavailable.

The upgrade checks `Origin` as the daemon's does. A pod admits a desktop shell's own
origin and the origins in `TROUPE_ALLOWED_ORIGINS` (the operator writes them from
`operator.workerAllowedOrigins`, with the plane's origin where the chart serves the GUI);
with none listed, no browser page gets a socket, and `*` admits every page. A client that
is not a browser sends no `Origin` and is not refused for it.

A laptop's session offered for steering from another device is reached the same way, at
the plane's `wss://<plane>/v1/relay/session`, which relays to the laptop
([Relayed connections](#relayed-connections)).

A frame is one message whatever whitespace it holds, newlines between its tokens
included. A frame larger than the socket's ceiling, 16 MiB unless the server is
configured otherwise, closes the connection before it is read; `initialize` says what the
ceiling is (`limits.max_message_bytes`), and a client does not send a message larger
than that (Decision 845).

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
  "client_info": {"name": "troupe", "version": "0.15.0-beta"},
  "capabilities": {"tools": false, "blobs": true},
  "auth": {"token": "…"}
}}
```

`params.capabilities` declares what the *client* can do:

| capability | meaning |
| --- | --- |
| `tools` | the client can serve `tool.invoke` requests (§8) |
| `blobs` | the client will fetch truncated payloads with `blob.get` |

`params.client_info.name` says which client this is, and a daemon names the sessions a
connection creates or wakes to the model provider by it (Decision 787): `troupe` is the
terminal UI, `troupe-headless` its headless run, `troupe-gui` the desktop app, and any
other name is `other`. The name itself never leaves the daemon.

`params.client_info.local_only: true` says the client is in *Local only* (Decision 951),
and `client.mode {local_only}` (any scope, answered by the connection itself, → `{local_only}`)
says it again when its switch moves; turning it on puts the sessions the connection has
open under it. A session is under Local only from when such a client creates it or gives it
work (`input.send`, `commands.run`, `session.goal.set`, `session.loop.start`) until a client
not in it gives it work, or the client that put it there turns it off; it stays there when
that client disconnects. For it the daemon calls no plane: an agent's `remember` with
`level: "me"` is refused with a sentence that offers the repository, `remote.offer` is
`forbidden`, its turns are left out of the `sessions` the memory poll reports, and its first
`instructions_loaded` under it carries `local_only`, a sentence saying it reads the memory
the machine holds. The client itself is refused `me.memory`, `me.memory.put`, `memory.in_effect`, the
forwarded `admin.memory.*` and a private
`session.create`, and gives an offered session no work; `session.invite`, `session.uninvite`,
`session.invites` and `session.read_sealed` are `forbidden` to it and for a session under it,
and so are the daemon's `artifact.*` (an agent's `publish_artifact` there is refused too); `me.memory.status` answers what the
copy holds without asking the plane. While every client attached is in Local only, the
daemon's own polls of the plane (`me.memory`, the version policy) wait. A client from before
it sends neither, and is in none.

The response:

```json
{"jsonrpc": "2.0", "id": 1, "result": {
  "protocol_version": "1",
  "server_info": {"name": "troupe-daemon", "version": "0.15.0-beta", "instance_id": "kP3u_2fQ8xA"},
  "capabilities": {"worktrees": true, "branches": true, "watch": true, "remote": false,
                   "private_sessions": true},
  "principal": {"subject": "local:me", "display_name": "me", "kind": "user"},
  "scopes": ["observe", "control", "admin"],
  "limits": {"max_message_bytes": 67108864, "outbound_queue": 10000}
}}
```

`limits.max_message_bytes` is the largest message this connection reads: 64 MiB on the
socket and TCP transports, the socket's ceiling over a WebSocket (16 MiB by default). A
larger one ends the connection, with `payload_too_large` on a socket and without a word
on a WebSocket, so a client checks a message against it before sending one.

The server's `capabilities`:

| key | meaning |
| --- | --- |
| `worktrees` | this server can make a git worktree for a session |
| `branches` | `session.create` takes `parent`, `session.list` filters on it, `worktree.merge` / `worktree.discard` end a branch's worktree, and an agent has `read_branch` |
| `watch` | `watch.set` and `watch.get` are served, a saved `AI!` or `AI?` comment starts a branch (`watch_triggered`), and `fs_changed` events arrive |
| `remote` | this is a worker pod rather than a local daemon |
| `private_sessions` | this server can seal a session under the caller's own key, so a client may offer to make one |

`private_sessions` is computed at every `initialize`, never compiled in, and it is what
un-gates the client's control. It is true only where both things it needs are true: a
person the server can name — `local:<username>` means nothing to a plane or to another
device, so an unlinked daemon says false — and somewhere to seal to, which for a daemon is
the plane its link names: it writes through the URLs that plane signs and needs no object
store of its own, and one not yet handed a token seals once it is. A worker always
says false: a private session is sealed under its person's own key, in a subtree no pod
credential can reach, and no worker profile is involved in one.

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
  "actor": {"subject": "local:me", "kind": "user"},
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
| `ts` | RFC 3339 UTC, microsecond precision |
| `actor` | who caused it; `{"kind": "system"}` when nobody did; `"via": "plane"` beside a person who did it from another device, through the plane ([Steering from another device](#steering-from-another-device)) |
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

`kind` is `text` (the answer as it arrives), `reasoning` (the model's thinking, shown
apart from the answer and never part of `llm_response`'s prose), `tool_use_start` (`id`,
`name`) or `tool_input` (`fragment`). Every completed model message also lands as a
durable `llm_response`, so dropping deltas loses nothing but smoothness.

### Event types

Durable:

| type | `data` |
| --- | --- |
| `session_created` | `workspace`, `profile`, `visibility`, `bundle_version`, `kind` (`team`/`local`/`private`), `owner`, `entitlements` (the agent, skill and MCP server names the grant resolved to; absent for no restriction), `origin`, `parent` |
| `session_forked` | `parent` (the id, the `seq` forked at and the parent's head hash there), `reason` — a fork's first event; the parent gets nothing |
| `agent_started` | `profile`, `mode`, `bundle_version` |
| `agent_restarted` | `replayed_events`, `interrupted`, `incomplete_calls` (the calls the restart closed) |
| `user_input` | `source` (`user`/`watch`/`tui_todo_edit`/`loop`/`harness`/`shell`/`subagent` — `loop` is an iteration of `session.loop.start`, `harness` the note the harness gives a model whose reply was cut or empty, or that keeps calling a tool that fails, `shell` what the agent was given of the person's own commands, each of which a client draws from its `user_shell` instead, and `subagent` the end of a child the agent started in the background, handed to it once, Decision 853), `text`, `command_id` — the send it was taken from, as its `input_accepted` names it; absent from a `harness`, `shell` or `subagent` note, which nobody sent, and from a log written before 0.5.2; `child_path` and `ended` (`finished`, `cut_short`, `stopped`, `cancelled`, `interrupted`, `failed`) on one from `subagent` |
| `user_shell` | `run_id`, `command`, `output`, `ended`, `agent`, `exit_status`, `reason`, `timeout_ms`, `duration_ms`, `command_id` — a command the person ran with `shell.run`, written by the root agent under their actor when it ended. `output` is its combined stdout and stderr, the tail capped at `tool_output_limit` with the `read_output` marker when it was cut; `ended` is `exited` (with `exit_status`), `timeout`, `killed` (`shell.cancel`) or `failed` (it could not start, `reason` says why); `agent: false` is one kept from the agent (Decision 813) |
| `input_queued` | `command_id`, `author`, `text` |
| `input_accepted` | `command_id`, `author` |
| `llm_request` | `model`, `message_count`, `tools`, `profile`, `prompt_bytes` — what the prompt was made of (see below); `system_changed`, `tools_changed`, `turn_context`, `turn_context_block`, `turn_hold` — what changed in front of what the agent had sent, and what a turn holds to its end (see below) |
| `llm_response` | `message` (`role`, `content`: blocks of type `text`, `tool_use`, `tool_result` or `reasoning` — the last is the model's thinking, `provider`-bound, replayed only to the provider that made it and carried by `Message.text` nowhere), `usage` (`input_tokens`, `cache_read`, `cache_write`, `output_tokens` — disjoint, so the first three sum to the prompt's length), `stop_reason`, `model`, `gateway`; `thinking_resent`, `thinking_dropped`, `prefix_mismatch` — what became of the thinking the call handed back, and what the provider said of why (see below) |
| `llm_error` | `reason` — a sentence a person can act on: a blown context window, rejected credentials, an unknown model, a rate limit the backoff outlasted, with the provider's words in brackets; `note` — a root's, the words its conversation was given about the failure, which a replay puts back; `stopped` — the call the agent gave up on when it did not answer within `llm_timeout_ms`, or sent nothing within `llm_first_byte_ms` (the sentence names the host), and stopped (see below) |
| `truncated` | `reason` (`max_tokens`: the output cap cut the reply; `empty`: it had neither text nor a tool call), then one of `note` (the model was asked again), `calls` (tool calls cut mid-argument, answered with an error and not run) or `final: true` (asked once already; the agent ends `output_truncated` or `empty_reply`) |
| `tool_call_started` | `call_id`, `name`, `args`, `identity`, `principal` |
| `tool_call_completed` | `call_id`, `name`, `ok`, `content`; `exit_status` or `timed_out` — how a `shell` call's command ended: `exit_status` when it exited, `timed_out: true` when its timeout killed it. Absent on every other tool and on a `shell` call that ran no command. `ok` is true for a command that ran, whatever its status, and the model reads `content` alone, which still ends in `[exit status N]` for a non-zero exit, so a reader that tells a failing command from a passing one reads `exit_status` rather than the text. `spent` on a waited-for `delegate`'s: what its subagent reported it spent, in `turn`'s shape, which the parent's turn counts as its own; a replay counts it from here, so a restart in the middle of the turn keeps it. `artifact` on a `publish_artifact`'s: `{id, version, url, title, visibility, owner_team?}`, what it published on the plane, `owner_team` the team whose it is when the plane answers one |
| `tool_results` | `results` |
| `todo_updated` | `items`, `source` |
| `profile_switched` | `from`, `to`; and `layer` (`builtin`, `bundle`, `user` or `project`, where the new agent was read from), `tools_added` and `tools_removed` (the tool names the new agent holds that the old did not, and the other way round) and the switch's `command_id`, under the actor who switched it (Decision 841) |
| `instructions_loaded` | `budget`, `used`, `searched`, `files`, `memory` — what the agent's system prompt was read from at this turn: for a root agent first the harness's own word (`scope: harness`, `path: harness`, outside the files' budget): where a file the person asks for goes, and in `open` what is open for one in this session, `{file_tools, starting, artifact: {state: open | closed | none, why}, where: local | pod}` (`starting`, where there are any, the servers marked `stores: files` still starting, whose tools join at the next turn) (the tools of a server marked `stores: files`, whether `publish_artifact` can publish from here, where the workspace is), Decision 956; the organisation's memory documents (`organisation`, `team`, `profile`, each with its `version`), the instruction files (`AGENTS.md`, `.agents/AGENTS.md` and `.troupe/rules`, and the other tools' files listed as not read) and the project brief, as `context.get` lists them, each with `scope`, `path`, `size`, `chars`, `budget`, `share`, `status`, `reason`, `trimmed`, `skipped`, `imported_by`, `unfollowed`, `rule`, `applies` and `hash`. Read as the turn began and held for the rest of it. Written when the set of files, or what one of them holds, changed since the agent's last turn, so a quiet log means the same files were read again. `memory` is each memory document read, as the plane names it, `{scope, name, version, hash}` with `scope` `organisation`, `team`, `profile` or `user` (Decision 947), so the log says which version of each the turns from here run under; a document some of whose `## Topic` sections a closer level's replaced, and which the prompt therefore left out, has `replaced: [{topic, by: [{scope, name}]}]` (Decision 957), and its file in `files` the same `replaced` (empty for none). `local_only`, once, where the session's client put it under Local only (Decision 951): a sentence that it reads the memory the machine holds and that nothing of it goes to the plane |
| `memory_changed` | `changes`, `message` — the organisation's memory documents the agent reads changed while the session ran (#55, Decision 929): a save on the plane reached it, on a pod through `session.memory` and on a laptop through its daemon's copy, and this turn read the new ones. Written by each agent as the turn begins, before its `instructions_loaded`, and never during a turn. Each change is `{scope, name, from, to}`, the versions, `null` for a document new or taken away; `message` is the sentence a client shows as it is (`The organisation's memory changed: the team design's memory is now version 6 (it was 5). Read from this turn on.`, or `Your memory changed: …` where only the person's own did, Decision 943) |
| `goal_set` | `text`, `command_id` — the session's goal, written by the root agent under the actor who set it (`session.goal.set`) |
| `goal_cleared` | `command_id` |
| `loop_started` | `loop_id` (`loop-<n>`), `max_iterations`, `max_failures`, `goal`, `command_id` — a loop towards the goal, written by the session under the actor who started it (`session.loop.start`) |
| `loop_iteration_started` | `loop_id`, `iteration`, `command_id` — the command id the iteration's input carries, which the root's `input_accepted` echoes |
| `loop_iteration_finished` | `loop_id`, `iteration`, `outcome` (`continue`: the turn ended and the goal is not met; `complete`: the agent called `goal_complete`; `failed`: the turn ended in an error; `stopped`: the loop stopped around it), `detail` |
| `loop_stopped` | `loop_id`, `reason` (`goal_complete`, `max_iterations`, `failures`, `budget`, `requested`, `cancelled`, `goal_cleared`, `interrupted`, `agent_done`), `iterations`, `detail`, `summary` (the evidence `goal_complete` gave), `command_id` (the `session.loop.stop` that asked) |
| `delegation_started` | `call_id`, `agent`, `child_path` (the parent's path and `<agent>#<n>`; `n` goes on counting across restarts, so a path names one child), `task` (the child's first message: the brief's parts under their names), `brief` (the parts, `goal`, `context`, `constraints`, `deliverable` and `do_not`; absent from a log written before briefs had them, Decision 847), `wait` (`false` for a child started in the background: the `delegate` call answered at once, and the child's end reaches the parent later as a `user_input` from `subagent`; absent otherwise, Decision 853). The child writes its `agent_done` before the parent's `tool_call_completed` for the call, and is stopped once the parent has its result: from then on it is only its log. A delegation a restart closes as interrupted or takes up again leaves a child nothing starts again, so the restart closes that child's part of the log, and the part of each agent under it: a `tool_call_completed` for each call still open, then `agent_done` with `reason: interrupted` |
| `compacted` | `summary`, `reason` (`threshold`, or `context_overflow` when the provider refused the prompt and the turn is sent again after compacting), `conversation` (the conversation the agent goes on with: the summary as a message, then what was kept, a large tool result as a blob), and the summariser's own model call as `llm_request` and `llm_response` say one: `model`, `prompt_bytes`, `usage`, `gateway` (absent from a log written before 0.8.2) |
| `budget_exhausted` | `limit` |
| `budget_ask_started` | `call_id` (`budget-<n>`), `dimension`, `used`, `limit`, `detail` — the budget is spent and the agent asks before its next model call; the question itself is a `question_asked` under the same `call_id`, answered with `question.answer`. Its `question` says what the limit protects against, what the session has used and spent, and what the raise on offer would cost; its `options` are sizes and scopes — `+25 turns this run`, `+50 turns this session`, `no limit this session`, `+50 turns this workspace`, `stop` — and a typed amount (`50`, `+50 turns`, `+50k tokens`, `+15 min`, with `run`, `session` or `workspace` after it) is an answer too (Decision 699) |
| `budget_ask_answered` | `call_id`, `decision` (`allow`: one more slice of the original size, `grant` says how much; `always`: the limit the question was about, named in `lifted` — `max_turns`, `max_input_tokens`, `max_output_tokens` or `wall_clock` — is lifted for this agent and its subagents, and the others still ask; `raise`: `limit` goes up by `amount` — turns, tokens or milliseconds — for `scope` `run` (given back at the turn's end), `session` or `workspace`, the last also written to the project's file named in `path`, or `note` says why it was not; `unclear`: the answer could not be read, `note` says why, and the question is asked again under the next id; `deny`: `budget_exhausted` follows). An `always` without `lifted`, from a log written before Decision 687, lifted the limit its `budget_ask_started` named |
| `budget_warning` | `dimension`, `used`, `limit`, `fraction`, `detail` — once per dimension per agent, at `budget_warn_at` |
| `config_note` | `key`, `message`, `source`, `limit`, `model`, `effort`, `thinking` — something the configuration did to the session that the person is told, once a session, under the root; `message` is the sentence a client shows as it is. The one there is (`key: max_tokens`): an organisation's enforced `max_tokens` (`limit`, from `source`, the plane's URL or the managed file's path) left a model call less thinking than `model`'s `reasoning_effort` (`effort`) asks for, `thinking` tokens of it, 0 where thinking is off for the call (issue #644) |
| `tool_failures_ask_started` | `call_id` (`failures-<n>`), `tool`, `failures`, `detail` — one tool has failed `failures` times in a row and the agent asks before its next model call whether the turn goes on; the question itself is a `question_asked` under the same `call_id`, with options `stop` / `continue`, answered with `question.answer` |
| `tool_failures_ask_answered` | `call_id`, `decision` (`continue`: the tool's count starts again; `stop`: a `user_input` from `harness` saying why, then `turn_ended` with `reason: tool_failures`) |
| `agent_done` | `reason` (`finished`, `budget_exhausted`, `output_truncated`, `empty_reply`, `refused`, `tool_failures`, `llm_error` — a subagent whose model request failed, after the `llm_error` that says why; a root rests instead; `interrupted` — a subagent a restart took down, written by the restart, see `delegation_started`; `stopped`, `cancelled` and `failed` — a child in the background its parent stopped, a cancel stopped, or that failed past its restarts, written by its parent, Decision 853), `by` (with `stopped`, the parent's path), `summary` (after a `finish`, its report as the parent is handed it: the summary, then `changed`, `ran`, `passed`, `unverified` and `needs` under their names), `report` (those parts, `changed` as Troupe counted it from the agent's file tools: `files` with `path`, `added`, `removed` and `whole`, the totals, `commands` not counted, `session_id` and `agent` to read the diff by with `read_branch`, and `said`; Decision 847), `limit`, `turn` — what the agent's last turn cost, a subagent's whole task (see below); absent from one a restart wrote |
| `agent_woken` | `from`, `source` — a root agent that had finished took new input as a turn |
| `input_after_done` | `source` — input a done agent did not take (its budget is spent) |
| `cancelled` | `turn` — what the cancelled turn had cost (see below); `stopped` — the model call the cancel stopped, when one was in flight (see below) |
| `turn_ended` | `reason` — the agent's turn is over and it waits for input: the model answered without asking for a tool, or a root's request failed and the `llm_error` just before says why. The durable twin of `agent_state` reaching `idle`, for a client that was not listening when it happened; a cancelled turn ends with `cancelled` instead, and a finished agent with `agent_done`. `reason` is there only when the harness ended the turn: `tool_failures`, a tool kept failing and the answer to `tool_failures_ask_started` was `stop`; `agent_failed`, the root agent crashed as often as it may be restarted, `detail` says what it raised, and the session stops after it, to come back dormant (Decision 727). Neither turn is taken up again by a restart. `waiting`, a subagent that ended its turn while a child it started in the background still runs: it rests until that child's end, and its task goes on (Decision 853). `turn` — what the turn cost (see below); absent from an `agent_failed` or a `waiting` one |
| `approval_requested` | `call_id`, `tool`, `args`, `agent_path` — open until its `approval_decided`, its call's `tool_call_completed` (a cancel, or a tool that timed out waiting, ends the call with no decision), or a `cancelled` on the agent that asked or on one above it. A delegation a person asked to see first (`delegation.ask` in a config file, or `delegation: ask` in the agent's definition; Decision 850) asks with `tool: "delegate"`, the call's arguments as `args`, and `delegation`: what the gate shows — `agent`; `definition` (`name`, `layer`, `path`, `description`; `agents.get` by that name opens it, and the gate never edits one); `brief` (`goal`, `context`, `constraints`, `deliverable`, `do_not`); `tools` (`[{name, permission}]`, what the child will hold); `budget_share`; `depth` (the child's) and `max_depth`; `agents` (`[{name, description}]`, the subagents it could go to instead). `auto_approve` does not answer one. A call a per-tool rule of the configuration asks about (#658, Decision 907) carries `rule`, `{action, rule, tool, pattern, scope, source}` as `config.get`'s `permissions` has it: neither `auto_approve` nor an earlier `allow_session` answers it. A call a `deny` rule refuses asks nothing; its `tool_call_completed` names the rule and where it came from. A `publish_artifact` asks with `publication`, what the person aims: `title`, `kind`, `files` (how many), `visibility` and `owner` as the model proposed them (`null` where it proposed none; a call with no `visibility` is asked whatever a rule or `auto_approve` says, since whom it is for is the person's to choose), `id` (the artifact it republishes) and `note` |
| `approval_decided` | `call_id`, `tool`, `args`, `agent_path`, `decision` (who decided is the event's `actor`); for a delegation, `agent` (the subagent it went to, when allowed), `brief` and `edited` (the brief as the person edited it, and which parts), `reason` (the person's word back with a denial); for a publication, `visibility` and `owner` (what it ran with, when allowed) and `edited` (which of the two the person changed from the model's proposal), `reason` with a denial |
| `approval_resolved` | `call_id`, `resolved_by` |
| `question_asked` | `call_id`, `agent_path`, `question`, `options` (`[{label, description}]`), `multiple`, `preview` — the agent's `ask_user`; answered with `question.answer`. `preview`, where there is one, is text the question is about, for a client to show as it is beneath it: the prompt a workspace's command would send, when it asks before it is first sent (`commands.run`). Open until its `question_answered`, its call's `tool_call_completed` (a cancel, or a tool that timed out waiting, ends the call with no answer), or a `cancelled` on the agent that asked or on one above it. The budget's and the failure guard's question have no call; each also ends with its `budget_ask_answered` or `tool_failures_ask_answered`, the only word there is when nobody is there to ask, and one a cancel ended is asked again at the next turn with another `question_asked` under the same `call_id` |
| `question_answered` | `call_id`, `text` (who answered is the event's `actor`) |
| `command_declined` | `name`, `reason`, `command_id` — a workspace's command that asked before it was first sent (see `commands.run`) and was not: `reason` says why and how to run it later, and `command_id` is the `commands.run` that asked |
| `onboarded` | `target` (`repo`: the workspace's `.troupe/`; `workspace`: an `AGENTS.md` of the workspace's, Decision 827; `user`: the person's config directory), `path` (from that root), `file` (as a person reads it), `source` (the other tool's file it was made from: relative to the workspace, or `~/`), `source_hash` (the sha256 of that file, lowercase hex), `action` (`created` or `replaced`) — a file the `onboard_write` tool wrote, which asks first (Decision 823); the file records the same provenance itself, or `.troupe/onboarded.json` does for it |
| `onboarding_suggested` | `reasons`, `message`, `workspace`, `command`, `proposals`, `onboarding_version`, `onboarded_version`, `survey_version`, `brief_version`, `due`, `brief_due`, `counts` — what onboarding would do in the session's workspace, said at every start while onboarding is due or the brief is outdated and the person has not said no for that version (Decisions 827 and 835); nothing was written. `due` is onboarding's (`first`, `outdated` or `none`) and `brief_due` the brief's (`first`, `stale`, `outdated` or `none`), as `onboard.plan` has them; `counts` is the workspace's files a client would ask about (`files`, `write`, `create_agents_md`), and `onboard.plan` lists them. `reasons` holds `first` (other tools' files are there and nothing is onboarded: `proposals` counts what `troupe onboard` would propose by kind, `instructions`, `rules`, `agents`, `commands`, `skills`, `workflows`, `mcp`), `outdated` (the workspace was onboarded under `onboarded_version` of the onboarding rules, older than this build's `onboarding_version`) and `brief` (the brief was written by `brief_version` of the librarian's survey, older than `survey_version`). `message` says all of it in one line for a client to show as it is; `command` is what to run. Not on a pod |
| `watch_triggered` | `agent`, `mode`, `markers`, `session_id`, `error` — a saved `AI!` or `AI?` comment started a branch of this session (Decision 844): `agent` (`quick` for a change, `answer` when every comment was a question; `mode` is `change` or `question`) as the session `session_id`, whose `parent` is this one, in this session's checkout, for the comments in `markers`, each `{file, line, comment}`. The session's own agent is told nothing. `error` in place of `session_id` says why no branch started. A client opens the branch as it opens one it started, and says which file and comment started it. The branch asks before every write, edit and shell command unless `watch_auto_approve` is on, and does not watch |
| `session_dormant` | `last_seq` |
| `session_activated` | `epoch`, `pod` |
| `session_resumed` | `dormant_ms`, `moved` |
| `trigger_fired` | `source`, `idempotency_key`, `principal`, `revision`, `payload_digest` |
| `files_skipped` | `files` — the agent, skill, command and workflow files a session found at a start and did not read, each `{kind, name, path, reason}`: on a pod, a working copy's file of a name its bundle has or a built-in agent's, which those beat unless the profile sets `repositoryOverridesBundle`; in a git worktree, one the main checkout has not committed (Decision 826); a workspace's `.troupe/` file, or directory, that is a link out of it, a skill whose `SKILL.md` can't be read, and what a workspace's `skills.json` links from outside the repository while the workspace is not trusted (Decision 829). A directory not looked into has a null `name`. Written when the list differs from the one the log last recorded, so an empty list says the files went away |
| `fs_changed` | `path`, `hash`, `size` |
| `file_ready` | `path`, `size`, `hash`, `title`, `local_path` — a file the agent made for the person: `write_file` with `deliverable: true` (Decision 956). `path` is in the session's workspace, as `fs.read` takes it, and `hash` the one that read answers; `local_path`, on a session that runs on the person's machine, is where it already is there. A client offers to save it: the desktop app's **Save…** on the line (the bytes through `fs.read`, then a save dialog), the TUI the path on a laptop and `/save <path> [to]` from a pod; a headless run prints it |
| `scratch_updated` | `name`, `path`, `kind`, `title`, `size`, `hash`, `version`, `call_id` — a document the `show` tool wrote to the session's scratchpad, or replaced (Decision 870), or the `patch` tool revised in place: a plan, report, comparison, diagram or table the agent shows the person beside the chat instead of printing it there. `path` is where `fs.read` reads it (`scratch:/<name>`), `kind` how to show it (`markdown`, `mermaid`, `json`, `csv` or `text`), `hash` the same `sha256:…` `fs.read` answers, `version` the writes of that name in the session from 1, and `call_id` the `show` or `patch` call that wrote it, so a client puts a card where the call was rather than the call's `content`. `scratch.list` lists the documents |
| `acl_granted` / `acl_revoked` | `subject`, `role` |
| `session_invited` / `session_uninvited` | `subject`, `role` (invited only), `by`, `display_name`, `by_name` — a person invited into the session by name, to follow it (`observe`) or steer it (`control`), or the invitation taken back (Decision 949): written by the pod holding a pod session when the plane tells it, and by the daemon sealing a private one when its owner invites from there. A private session's daemon reads who it has invited from these, and puts a new key only in the slots of people they name |
| `mounts_resolved` | `mounts` — the volumes a pod session's working tree was given, as the session started |
| `published` | `source`, `destination`, `hash`, `bytes`, `direction` — a file the `publish` tool copied to or from a shared volume |
| `config_upgraded` | `channel`, `from`, `to`, `hash`, `entitlements` — the configuration a session was pinned to was retired, and an activation moved it to the channel's current version |
| `session_read_only` | `reason` — declared for a session parked read-only (see the states below) |
| `session_archived` / `session_erased` | nothing; declared, and carried on a session's topic |
| `share_created` | `id`, `role` (`observe` or `control`), `expires_at`, `audience` — a share of a team session, announced by the plane |
| `share_revoked` | `id`, `reason` |
| `tools_registered` | `tools`, `connection`, `consent` — a client offered tools of its own (§8) |
| `tools_unregistered` | `tools`, `connection`, `reason` (`disconnected`: the client left; `unregistered`: it took them back), `actor` — whose they were, the subject the registration was made for, also the event's `actor`; a log written before it has neither |
| `session_tainted` | `kind` (`personal_connector`), `tools`, `actor` (the subject), `display_name` (their name, where the sign-in gave one) — a person's own tools were offered to the session, which says so from then on (§8) |

A spent budget is a question, not a stop (Decision 660): the agent's `agent_state` is
`waiting` until the answer, input queues meanwhile, and the answer says how much more and
for how long (Decision 699) — a checkpoint every time. It is a stop where the budget is a
contract (`budget_asks: false`, which the plane's terms set) and never asked under
`full_send`; a session with `approvals: deny` answers no itself, as it does an `ask_user`.
A subagent never asks: it hands its parent what it found, labelled partial, and the parent
may delegate again. It ends `budget_exhausted` with no further model call and nothing left
running, and a `done` subagent keeps no session awake: its parent stops it on taking its
result. `always` lifts only the limit it was asked about (Decision 687). On a pod the
terms are a ceiling: a raise past a limit they set is refused with the reason, and the
workspace is not a scope there.

A tool that keeps failing is stopped whatever the budget says (Decision 687). The agent
counts each tool's failures in a row; a success of that tool clears its count. At
`tool_failures_note_at` (5) the model gets a note, a `user_input` from `harness`; at
`tool_failures_stop_at` (10) the agent is `waiting` on a `tool_failures_ask_started`
question before its next model call, under `full_send` and a lifted budget alike. `stop`
comes first among the options, so a client that answers with the first option stops.
Under `approvals: deny` the agent answers `stop` itself. A subagent does not ask: it ends
`tool_failures` and hands its parent what it found, labelled partial.

Ephemeral: `llm_delta`, `agent_state` (`state`, `profile`, `agent`, `todos`, `budget`,
`done_reason`: an agent's state as it changes), `progress`, `presence`, `summary_diff`, and `shell_started` and
`shell_output` while a person's command runs (`shell.run`); `watch_notice` (`message`)
when watch mode falls back to polling or cannot start, and `watch_changed` (`enabled`,
`backend`: `native`, `poll` or `off`) on the session whose watch went on or off or
changed backend, which `watch.get` answers at any time.

`budget_warning` — `dimension` (`turns`, `input`, `output`, `wall`, `context`), `used`,
`limit`, `fraction`, `detail` (`input tokens 4.9M/6.0M (82%)`) — is written once per
dimension per agent when it crosses `budget_warn_at` (0.8 by default), so a person hears
a limit is near before `budget_exhausted` stops the agent. Durable, because an ephemeral
may be dropped under load and a warning has to arrive. `agent_state.budget.headroom`
carries all five fractions for a client that draws a gauge. `full_send: true` in the
session's config turns the warnings off.

`trigger_fired` is written once, at creation, for a session started by something other
than a person at a keyboard, and never again however many times that session is woken.
`source` is one of `schedule`, `webhook`, `integration`, `ci`, `api`, `manual`, `agent`,
and everything else about the seven is the same — which is the point of the event. A
session a person typed into carries none.

`payload_digest` is a hash and never a payload: a webhook body is content, and content
belongs where the retention policy reaches it rather than in an event that outlives the
session. It and `revision` are absent where there was nothing to measure — a session
started through the A2A facade has no trigger document to name — and absent means there
was none, never that the writer skipped it.

`tool_call_started.identity` says whose credential an MCP call goes out as: `"profile"`
for a profile-mode server, the subject for a person-mode one, and absent for every other
tool. `principal` answers the same question with its other half — `{"subject", "actor"}`,
whose authority and what acted — and both halves are written even where they are equal.
A reader written against `identity` alone keeps working: the field still holds the string
it always held.

`llm_response.gateway` is what the gateway in front of the provider said about the call
it billed: `{"request_id": "…", "cost_micros": 18400}`. Both keys are optional and the
whole object is absent where the gateway said nothing, which is a fact a reader may act
on — tokens with no cost — rather than a cost of zero. A client that shows spend should
treat an absent `gateway` as "not known" and a `cost_micros` of `0` as "free".
`"priced_locally": true` beside a `cost_micros` says the harness worked the cost out
itself, because the gateway did not say: from the provider's catalog, or from the
`models.prices` its configuration holds (Decision 689). A reconciliation against the
gateway's own records should expect those to differ from it a little.

Neither key is present in an event written before Troupe logged what the gateway said. A
reader folding such a log gets the tokens and no cost, which is what was true.

`turn`, on the event that ends a turn (`turn_ended`, `cancelled`, `agent_done`), is what the
turn cost: one input, until the agent rests (Decision 769).

```json
{"calls": 3, "input_tokens": 300, "cache_read": 3000, "cache_write": 0,
 "output_tokens": 3, "cost_micros": 945, "unpriced": 0}
```

`calls` counts the model calls the turn made: its subagents' included, the one that writes
a compaction's summary, whose figures are on its `compacted`, and one the agent stopped,
whose figures are its `stopped` (below). The four token figures
are those calls' `usage` added up, disjoint as they are there. `cost_micros` adds up the
`gateway.cost_micros` of the calls that had one, and `unpriced` counts the calls that had
none, which the sum leaves out rather than counting as free. A subagent's `agent_done` says
what its task cost, which is part of its parent's turn. A cancel stops a subagent before it
reports, so a cancelled turn leaves out what its running subagents had spent; and a restart
in the middle of a turn reads the agent's own calls back from the log and forgets what its
subagents had reported, as its budget does.

`stopped`, on `llm_error` and on `cancelled`, is a model call the agent gave up on before
it answered: one still streaming when `llm_timeout_ms` ran out, one that had sent nothing
when `llm_first_byte_ms` ran out, or one a cancel stopped
(Decision 788). The agent stops it, which closes its request, so a reply that keeps coming
is not generated and billed after that. It says what `llm_response` says of a call, as far
as the provider had said it: `model`, and `usage` and `gateway` when the provider had
reported usage by then. Anthropic's API does as the reply starts; an OpenAI-compatible one
says it only at the end.

```json
{"model": "claude-sonnet-5",
 "usage": {"input_tokens": 2000, "cache_read": 500, "cache_write": 0, "output_tokens": 1},
 "gateway": {"cost_micros": 6165, "priced_locally": true}}
```

What the reply had written by then and the provider had not reported is not counted. A
call that had reported nothing is one of the turn's `calls` and one of its `unpriced`, not
a free one. A compaction's summary given up on at its timeout is counted in its turn's
`turn` and written nowhere else.

`prompt_bytes`, on `llm_request` and on `compacted` for the summariser's call, is what that
call's prompt was made of, in UTF-8 bytes, as the log writes it:

```json
{"system": 6330, "brief": 2210, "tools": 18400, "conversation": 72700,
 "tool_results": 61200, "total": 97430}
```

`system` is the whole system prompt, of which `brief` is the instruction files and the
project brief; `tools` is the tool definitions as a JSON list of name, description and
schema; `conversation` is every message as `llm_response.message` writes one, of which
`tool_results` is the tool results' text; `total` is `system + tools + conversation`. It is
the measure `troupe bench` takes of a request, which also writes the workspace's path as
`<workspace>` (Decision 772). Bytes rather than tokens: the
provider's own count is on the response, and the parts scale to it. Neither field is in
events written before 0.8.2.

What a model call's prompt kept of the one before (issue #465, Decision 815), which is
what a provider's prompt cache and Anthropic's newest models' kept thinking are bound to.
On `llm_request`, `system_changed` and `tools_changed` say whether the system prompt and
the tool definitions differ from the agent's call before; both are absent on an agent's
first call and on its first after a restart. `turn_context` is present on a call that sent
the session's turn context, with `system_prompt: stable` (the default since 0.13.0,
Decision 863): the sections it carried, of `instructions`, `goal` and `task_list`; and
`turn_context_block` the block itself, `at` (the index of the message it goes after),
`text` and `sent` (each section's `sha256:` digest), which a restarted or resumed agent
folds back so its next call sends the prefix the one before it sent. Absent in events
written before 0.13.0, whose agents send their next call without the blocks once.
`turn_hold` is on a turn's first call: the tools of MCP servers and of people's clients,
and the skills, that the call took and the turn offers to its end (Decisions 871 and 876),
as `digest` (`sha256:`), with `tools` (each `name`, `description`, `schema`,
`default_permission`) and `skills` (`bundle` and `local`, each `name`, `description`,
`layer`, `dir`) when they differ from the last hold the agent wrote whole; an agent
restarted in the middle of the turn folds it back and offers what the turn began with.
Absent in events written before 0.15.0, whose agents restarted mid-turn take them afresh. On
`llm_response`, `thinking_resent: true` says the provider refused the thinking the call
handed back as bound to another conversation and the call was sent once more without it
(Decision 805), and `thinking_dropped` how many thinking blocks Anthropic's
thinking-binding beta dropped instead, with `thinking_binding: drop_block`; each is absent
when nothing happened. None of the five is in events written before 0.9.1.
`prefix_mismatch` is what Anthropic's `anthropic-thinking-prefix-mismatch` response header
said of the edit, on the refusal or on the response that dropped blocks, cut to its own
words: the `kind`, `pattern`, `sections`, `changed_validated` and `position` pairs whose
value is a word, a path or a list of them (`kind=system_changed; pattern=system_rerendered;
sections=system; changed_validated=system.0`); a header that is one such word alone is
kept as it is, and one with neither is `unrecognised`. Absent when there was no header, and
in events written before 0.13.0.

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

A tool's output over **16 KiB** — `tool_call_completed.content`, a result in `tool_results`,
or one in `compacted.conversation` — is replaced by a blob reference:

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
| `topic` | `"fleet"`, `"session:<id>"` or `"presence:<id>"` |
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

A subscription that names a session — `session:<id>`, or its `presence:<id>` — is also how
a client says it is reading the session: the daemon does not put one to sleep under a
subscriber, and the session's `unseen` row (`session.list`) is cleared by it and counted
again from when the last subscriber leaves. `fleet` names no session and reads none.

- **`detail`** delivers every event for the session, durable and ephemeral.
- **`summary`** delivers only `summary_diff` ephemerals plus session lifecycle
  events. A summary carries: per-agent state and profile, current todo item, active
  tool, tokens, cost, pending approvals, pending questions (`questions`, from a session's
  first `question_asked` on), and last error. Summary diffs are throttled
  to at most 4 per second.
- **`fleet`** carries only session lifecycle events — created, state changes,
  archived, erased — for every session the principal can see, the ones created or woken
  after the subscription was answered among them. `fleet` ignores `from_seq`, and
  replays nothing. Beside a subscription to one of those sessions on the same
  connection, each event arrives once on each, and dropping `fleet` leaves the other as
  it was.
- **`presence:<id>`** carries `presence` and nothing else, and is the only topic that
  does. It ignores `level` and `from_seq`, answers `head_seq: 0` with
  `"cursored": false`, and is the first thing the server stops sending when a client
  falls behind. Presence never reaches `session:<id>` or `fleet`.

#### Presence is a topic of its own

Who is looking at a session is true while somebody is there and worthless a minute
later. It has no `seq`, it is never persisted, and a subscriber who missed some of it
has missed nothing — three properties the session's own stream has none of.

That is what makes it droppable in a way the session's events are not. **With a
client's outbound queue saturated, presence stops entirely and the durable order is
unchanged**: shedding it is a decision about one subscription, so the session's own
stream arrives whole and in the same order it would have. Presence riding
`session:<id>` would be presence a client cannot decline and a server cannot shed
without touching the stream it must not touch.

A client that wants both subscribes twice. It is delivered once, on the presence
subscription.

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

Every command that changes something takes a client-generated **`command_id`**; a
read needs none. The server remembers an id for 30 minutes, by the person who sent it
and not by the connection, so that a retry after a disconnect is recognised: an id must
be unique for that person over that time, across every connection and client they have
open. A UUID is, and so is a counter behind a random prefix; a bare `c-<counter>` that
starts again at zero on each connection is not, since two local clients sign in as the
same person.

**The response is an acknowledgement, not the effect.** `input.send` returns
"accepted", not the model's answer. Effects arrive as events carrying the
originating `command_id`, which is how a client reconciles an optimistic render.

**Replaying a `command_id` is a no-op** that returns the original acknowledgement, for 30
minutes; a replay that arrives while the first call is still running answers
`{"accepted": true, "duplicate": true}`. This makes every command safe to retry after a
disconnect.

**A session id is the one the server generated**: a UTC timestamp and six characters
of URL-safe base64, `20260923T101112-q3Vx_A`, which the examples here shorten to
`s-9f`. The daemon and a worker refuse any other shape with `invalid_params`, naming
the field — `session_id`, a branch's `parent`, or the `topic` of a `subscribe` —
before they look for a session: an id names a place on disk, and a pattern or a path
in its place would reach sessions it does not name. The plane holds an id a caller
brings to the same shape, in `session.create` and in a first `session.register`.

### Session lifecycle

#### `session.create`
```json
{"command_id": "c-0", "workspace": "/home/me/project", "profile": "build",
 "prompt": "fix the test", "worktree": "auto",
 "parent": "s-3a", "config": {"auto_approve": false, "watch": true}}
```
→ `{"session_id": "s-9f", "workspace": "/home/me/project", "worktree": null, "branch": null,
"parent": "s-3a"}`

`worktree`: `"auto"` (default) creates a git worktree on `troupe/<slug>` when the
workspace already has a live session; `"never"` reuses the directory; `"always"`
always branches. The tree is `<checkout>-<slug>`, beside the checkout or worktree the
workspace belongs to. A workspace that is a folder of it (one the repository tracks or
would add) works in the same folder of the new tree, `workspace` in the answer, and
`worktree` is the tree's top. A folder the repository ignores, like a directory in no
repository, is a workspace of its own: it gets no worktree, whatever `worktree` says
(Decision 881).

`worktree_name`: work in the worktree of that name, whatever `worktree` says:
`<checkout>-<name>` on `troupe/<name>`, made the first time, the same tree after, and
made again from its branch when only the directory has gone. A name is one path segment
of letters, digits, `.`, `_` and `-`, not starting with `.` or `-` (`invalid_params`,
field `worktree_name`, otherwise); refused with `conflict` while a session is working
in that tree, in its directory or a folder of it; refused with `invalid_params`, field
`workspace`, in a folder its repository ignores or in no repository.

`workflow`: run the prompt as a named **workflow**: the step list at
`<workspace>/.troupe/workflows/<name>.json` (or the built-in `default` pipeline) is
rendered around the prompt as the plan the `orchestrate` agent starts from, and `profile`
defaults to `orchestrate`; `workflow`, the name of the agent that ran workflows before
`orchestrate` took its place, is taken as `orchestrate` (Decision 888).
`workflows.list {workspace}` says which names exist. A workflow is meant for a worktree
of its own (`worktree: "always"`), since its subagents write.

`parent`: the session this one is a **branch** of — a second agent a person started
from the first one's screen. The daemon records it in `session_created`, returns it in
every listing, and refuses an id it does not know (`invalid_params`, field `parent`).
It changes nothing about how the session runs: a branch is a session (Decision 646).
A client that shows a workspace's branches together groups by `parent`; the parent's
agent reads a finished branch's summary with the `read_branch` tool. Servers that do
this say `branches: true` at `initialize`.

`config` carries the session settings a client may choose, and only those:
`auto_approve`, `watch`, `profile`, `full_send` (no `budget_warning`s, and a spent budget never asks). Everything else in the configuration — where state
is written, which provider is used, what a key is — belongs to the machine the daemon
runs on, and a client cannot move it.

`private: true`, beside `config` and not in it, asks a daemon for a **private session**:
recorded `kind: "private"` in its `session_created`, registered with the plane the daemon
is linked at and sealed under the person's own key with the token a client handed it
(`identity.link`). The answer's `syncing` says whether it is being sealed now. A daemon
that cannot yet — no token, or no plane answering — makes the session anyway and says
`false`, and seals it from its first event once a client links it with a token.

#### `session.list`
```json
{"filter": {"state": ["active", "dormant"], "workspace": "/home/me/project",
            "parent": "s-3a"}}
```
→ `{"sessions": [{"id", "workspace", "branch", "parent", "profile", "state", "status",
"failed", "pending_approvals", "pending_questions", "unseen", "tokens", "cost", "created_at",
"last_active_at", "pinned", "kind", "sync", "device", "remote"}]}`

`filter.parent` selects the branches of one session.

`remote` is `null`, or how the session stands offered to the plane for steering from
another device ([Steering from another device](#steering-from-another-device)):
`{"owner", "shares": [{"subject", "display_name", "email", "role"}], "offered_at", "state",
"since", "steering": [{"subject", "display_name", "role"}], "lasts", "restored"}`, where
`state` is `online`, `connecting` or `offline` (since `since`), and `steering` is who is
attached through the plane now. `lasts` says whether the offer comes back after this
machine restarts: `across_restarts` where the daemon starts at login (`troupe-daemon login
on`), which reads its own sign-in back and offers it again, and `until_restart` where
nothing starts the daemon then. `restored` is true for an offer the daemon read back from
its record as it started, until it is offered again.

`kind` is where the session is kept: `local`, `private` (sealed under its person's key,
see `private` above), or a pod's `team`. A private session's `sync` says how its sealing
stands on this machine, so a client can list it as private and say whether its copy
elsewhere is current (Decision 785); it is `null` for any other session:

| `sync` | meaning |
| --- | --- |
| `current` | sealing here, with nothing waiting to be sealed |
| `behind` | sealing here, with events not sealed yet |
| `paused` | not sealing: no client has handed the daemon a plane token since it started or since the person signed out, the plane was not there, or the session was archived; the next link with a token carries it on (`identity.link`) |
| `elsewhere` | another device sealed it last, and it is that device's until it is claimed here (`session.claim`); `device` names it where the plane did |
| `erasure_pending` | somebody erased it and the plane has not yet destroyed its key (Decision 756) |

`elsewhere` and `erasure_pending` are what the plane said when the daemon last asked, at a
link with a token or a seal; a listing does not ask it. `device` is `null` but for
`elsewhere`.

`pending_approvals` counts the approvals still open (see `approval_requested` for when one
ends), `pending_questions` the questions (see `question_asked`: the agent's `ask_user`, the
budget's and the failure guard's), and `status` is `waiting` while either is not zero,
whatever else it would say: the columns a plane's `sessions.list` row carries, so an inbox
is a listing and not a replay. A dormant session counts the root agent's, which are what it
asks again when it wakes.

`unseen` is what happened while nobody was reading the session — "while you were away",
for a client that comes back to tell the person, and the marker it shows:

```json
{"turns": 1, "approvals": 0, "questions": 1, "since": "2026-09-26T22:49:38.593Z"}
```

`turns` counts the root agent's turns that ended (`turn_ended`), `approvals` and
`questions` the requests it raised (`approval_requested`, `question_asked`; each once, since
a wake asks a request again under its id), and `since` is when the first of them happened,
`null` with nothing to say. All of it is counted from the moment the last client
subscribed to the session (§5) left, and it is empty while one is subscribed: what they read
as it happened is not news. Subscribing to the session is what clears it; a listing, a
`session.get` or reading a blob does not, so an inbox can be refreshed without losing its
markers. `pending_*` say what is still open, `unseen` what was raised with nobody there:
a question asked and timed out while away is in the second and not the first. A session no
client has ever read has nothing unseen, and a session asleep answers from its log exactly
as it answered awake.

`failed` is how the root agent's last turn failed, when the harness ended it so, read from
the log: `{"reason": "agent_failed", "detail": "<the first line of what was raised>"}` for a
root that crashed as often as it may be restarted, whose session stopped on it (see
`turn_ended`; Decision 727). `null` otherwise, and once another turn has started (the next
`user_input`). It is how a client that was not watching tells a session that failed from one
at rest: the session is `dormant` afterwards, as one that went to sleep is.

#### `session.get` → one session object plus `head_seq`.

#### `session.archive` → `{"session_id", "state": "dormant"}`; stops the session's agents and makes it dormant. On a daemon the log stays where it is; on a plane the pod keeps no copy of a dormant session.

#### `session.pin` / `session.unpin` → `{"session_id", "pinned"}`; a pinned session is exempt from the plane's retention. A daemon has no retention: it marks the session pinned in its listing, running or dormant, and keeps the mark in a file beside the session's log, so it outlives the session's going dormant and the daemon's stopping. A session it has no log of is `not_found`.

#### `session.erase` → `{"session_id", "erased", "state"}`; irreversible.

A private session is sealed at the plane as well, and the daemon erases it there first, as
an erasure started at the plane goes (Decision 789): it asks the plane's `session.erase`,
which destroys the key. Once the key is gone the session's sealer stops, the copy here is
erased, and the plane is told (`session.erased`), which is when it deletes the objects:
`erased: true`, `state: "erased"`. Where the plane has not destroyed the key yet,
`erased: false`, `state: "erasure_pending"`: the sealer and the session stop, the copy here
stays and is listed with `sync: "erasure_pending"`, and it goes when the plane has
destroyed the key, at the next link with a token or the next `session.erase`, which tries
again. A private session the plane has no row for was never sealed, and is erased here.

Nothing is erased where the plane cannot be asked: `unavailable` with `reason: "unlinked"`
where no client has handed the daemon a plane token, `"not_owner"` where the daemon is
linked to somebody other than the person the session belongs to (Decision 784), or the
reason the plane did not answer; `plane_url` names the plane the daemon was last linked
to, where the session is sealed and can be erased. A local session is erased here and
answers `erased: true`, `state: "erased"`.

#### `session.claim`
```json
{"command_id": "c-4", "session_id": "s-9f"}
```
→ `{"session_id", "device", "epoch", "sync"}`

Takes a private session another device sealed last over on this one, the daemon's only
(Decision 785): a pod holds no private session. The daemon reads the plane's row, claims
it with the row's `epoch` (`session.register` with `claim`), and seals it from here from
the row's `last_seq`. The answer is the row as it now stands, this device's `device` and
the next `epoch`, and the session's `sync` here. The other device is not told; its next
seal is refused before it writes anything under the session's prefix, and it stops
(Decision 800). A row that already names this device is carried on, not claimed again.

Only where this machine's copy holds what the plane has: the event at the row's
`last_seq` is in the log here with the row's `head_hash`. Otherwise it is `conflict` with
`reason: "diverged"`, and nothing changes: the other device sealed events this copy does
not have, and sealing this copy after them would make the session two histories. Also
`not_found` with `reason: "erased"` for a session somebody erased or is erasing, or
`"not_registered"` for one the plane has no row for (a link with a token registers it);
`stale_version` where another device claimed it first; `unavailable` with `reason:
"unlinked"` where no client has handed the daemon a plane token; and `invalid_params`
for a session that is not private.

#### `session.invite`, `session.uninvite`, `session.invites`, `session.read_sealed`
```json
{"command_id": "c-6", "session_id": "s-9f", "person": "bea@example.test", "role": "observe"}
```
→ the plane's `session.invite` answer.

A person invited by name into a private session sealed here (Decision 949), the daemon's
only, since it alone holds the session's key: a pod session is invited at the plane, and
`invalid_params` says so of a session on this machine alone, which is offered instead
(`remote.offer`). `role` is `observe` or `control`; somebody invited with `control` steers
the session only while its owner offers it (`remote.offer` with `consent`, Decision 952),
and an offer it makes is shared anew with the people invited with `control`, the view of
somebody taken back closed at once. The daemon asks the plane where the
invitee's slot is (`session.invite_slot`), signs in at the key manager as the session's
owner, puts each generation of the session's key there, which its credential may create and
may not read back, tells the plane where (`session.invite` with `keys`), and writes
`session_invited` in the log where the session is running here.

`session.uninvite {command_id, session_id, person}` → `{session_id, subject, rekey_due,
key_version}`: the plane takes the invitation back and destroys that person's copies, and
the daemon re-keys forward: what is pending is sealed under the key held now, a new
generation is made (`<session_id>.k<n>`), everything after is sealed under it, it is put in
the slot of each person the plane lists whom this session's own log also says was invited,
the plane is told (`session.rekeyed`), and `session_uninvited` follows in the log, under the
new key. `rekey_due: true` where any of that could not be done now; the next link that carries
the session on does it before anything more is sealed.

`session.invites {session_id}` → the plane's answer. `session.read_sealed {session_id,
after_seq}` → `{session_id, events, last_seq, key_version}`: somebody else's private session
shared with this machine's person, read from the plane's sealed copy: the daemon asks
`session.keys`, spends its assertion at the key manager under the person's own name, reads
each key from their slot and the segments through URLs the plane signs for reading, and
answers the durable events after `after_seq`, oldest first, as far as the owner's machine has
sealed them. Nothing of it is kept here. `not_found` where it is not shared with them.

#### `session.fork`
```json
{"command_id": "c-5", "session_id": "s-9f", "config": {"auto_approve": true}}
```
→ `{"session_id", "workspace", "forked_from"}`

A second session from this one's conversation as it stands, the daemon's (Decision 812): a
pod session is forked through the plane's `session.fork`. The child's log opens with
`session_forked` (`parent`: the parent's id, the seq forked at and its head hash there;
`reason: "branch"`) and goes on with every event of the parent's up to its head, each
given the child's own `seq` and chained again, as a pod's fork is. It runs in the parent's
workspace, under its profile, with `config` as `session.create` takes it, and is opened as a
session resuming that log is: its agent starts from the parent's conversation, and the
next input goes on from there. It is a session of its own and not a branch: no `parent` in
the listing, its own budget, and erasing either leaves the other. The parent is read off
disk, running or dormant, and is neither changed nor woken.

`not_found` for a session the daemon does not have, and with `reason: "erased"` for a
private one being erased; `invalid_params` with `reason: "private"` for any other private
session, which is not forked here, since its child would be a copy no plane knows of.

### Steering

#### `input.send`
```json
{"command_id": "c-1", "session_id": "s-9f", "text": "make the tests pass"}
```
→ `{"accepted": true}`. If the agent is busy this produces a durable `input_queued`;
when taken it produces `input_accepted` and then the `user_input` with the text, and all
three carry the `command_id`, which is how a client that drew the line when it was typed
knows each of them for the same line. A root agent that has *finished* is woken by
input: `agent_woken`, then the turn as usual. One whose budget is exhausted is not, and
writes `input_after_done` instead.

#### `commands.run`
```json
{"command_id": "c-2", "session_id": "s-9f", "name": "review", "arguments": "the parser"}
```
→ `{"accepted": true, "command_id": "c-2"}`. Runs a command a markdown file defines (the
`custom` section of `commands.list`): the harness reads the file and sends its prompt as
the session's input, exactly as `input.send` would — the same events, carrying the
`command_id`, under the actor who sent it, and activating a dormant session the same
way. Every `$ARGUMENTS` in the prompt is replaced by `arguments`, trimmed; a prompt
without one has `arguments`, when there are any, added as a paragraph of its own.
`arguments` is optional and text; anything else is `invalid_params` with `field:
"arguments"`. A `name` the session's table does not list as a defined command — a
built-in's, an agent's, or nobody's — is `not_found` with `kind: "command"`: a built-in
is the client's to run.

A workspace's command (`source: "project"`) asks once before it is first sent while the
session approves every tool call itself (`auto_approve`), since nothing else would ask
before what its prompt says is done (Decision 814). The answer is then `{"accepted":
true, "command_id": "c-2", "question": "command-3f0a…"}`, and nothing is sent yet: the
session asks a `question_asked` under that `call_id`, its `preview` the prompt as it
would be sent, with the options `deny`, `once` and `allow`, answered with
`question.answer` like an `ask_user`, so any client can. `allow` sends it and is
remembered per checkout in the daemon's state directory, never in the repository, beside
a hash of the file's prompt, so an edited command asks again and the `arguments` do not;
`once` sends it; any other answer, or a session nobody can answer in (`approvals:
deny`), sends nothing and writes `command_declined` saying how to run it later. A
person's own commands never ask, and neither does a workspace on `trusted_workspaces`.

#### `turn.cancel`: `{"command_id", "session_id"}` → `{"accepted": true}`. Valid from any state.

Each tool call the cancel stops is closed before `cancelled` is written: a
`tool_call_completed` with `ok: false`, then the turn's `tool_results`. A restart takes
up nothing a cancel stopped: no call runs again, no approval is asked for again, and no
model call is made for the cancelled turn. `cancelled` carries who asked as its `actor`,
as an input does.

#### `shell.run`
```json
{"command_id": "c-4", "session_id": "s-9f", "command": "git status", "agent": true}
```
→ `{"accepted": true, "run_id": "sh-Qx3…", "command_id": "c-4"}`. Runs a command the
person typed (the TUI's `!cmd`) where the session runs, in its workspace: the local
daemon's checkout or worktree, or the pod's working copy. It goes through the runner the
agent's `shell` tool uses — the same shell, reaper, sandbox over the mount table, timeout
and kill — as a fresh `bash -c` (Git bash, then `pwsh`, on Windows) with stdin at the null
device: no terminal, nothing interactive, and no `cd` or `export` carried to the next one.
`timeout_ms` is optional, a positive number of milliseconds, the session's
`shell_timeout_ms` when absent. There is no approval prompt; the authority is the scope
(Decision 813):

* `control`, as `input.send` takes, **and** the session's owner or an `admin`. A
  collaborator holding `control` is refused `forbidden` with `required_scope: "admin"`
  and `reason: "only the session's owner can run commands on it"`: the agent's own shell
  asks before it runs, and this does not.
* What forbids the agent's shell forbids this: `managed_permission_rules_only` (`forbidden`,
  `setting: "managed_permission_rules_only"`), and agent definitions none of whose
  primary profiles may run `shell` (`setting: "permissions"`). Each `reason` is a
  sentence a client shows as it is.

Activating, as input is. While it runs the session publishes the ephemeral `shell_started`
(`run_id`, `command`, `agent`) and `shell_output` (`run_id`, `text`, at most every 100 ms,
the first MiB of it); when it ends, the root agent writes the durable `user_shell` under
the actor who ran it. Its output **does not start a turn**: unless `agent` is `false`
(the TUI's `!!cmd`), the agent is given the command and its capped output before its next
model call, as one `user_input` from `shell` — before the input that starts a turn, or
after a tool exchange and its results, never between a call and its result. A replayed
`command_id` answers the same `run_id` and runs nothing again.

#### `shell.cancel`: `{"command_id", "session_id", "run_id"}` → `{"accepted": true, "run_id"}`

Kills a `shell.run` command and everything it started, as its timeout does; its
`user_shell` says `ended: "killed"`. The same scope as `shell.run`, and not activating. A
run that has ended, or was never this session's, is `not_found` with `kind: "run"`.

#### `profile.switch` → `{"command_id", "session_id", "profile": "plan"}`. Applied at
the next turn boundary.

→ `{"accepted": true, "profile": "plan", "layer": "builtin"}`. It changes the agent a
session runs, its root's, and so a branch's (a branch is a session, Decision 646): the
conversation stays, and from the next model call the tools, permissions, prompt, model and
`max_turns` are the new definition's; a tool it no longer holds is not offered and a call
to one is refused (Decision 841). The definition is read from its file when the switch is
asked, so an agent saved with `agents.put` a moment ago, or edited since the session
started, is the one switched to, and a restarted agent comes back on it. A workspace's
agent's `auto` still waits for the workspace to be trusted (Decision 825). An agent that
has finished (`agent_done`) takes the switch at once, and its next input runs on the new
agent; otherwise it waits for the turn boundary. The effect is `profile_switched`, written
under the actor who switched it and carrying this `command_id`, and `session.list` says
the new `profile` from then on. A name nothing defines is `not_found` with `kind:
"agent"`; a subagent's is `invalid_params` with `field: "profile"` (a session or a branch
runs a primary agent, `agents.list`'s); nothing is written for either. Before Decision 841
every name was accepted and an unknown one did nothing.

#### `session.goal.set`, `session.goal.get`, `session.goal.clear`
```json
{"command_id": "c-6", "session_id": "s-9f", "text": "the release notes build on Windows"}
```
→ `{"accepted": true}`. The effect is a durable `goal_set` carrying `text` (trimmed) and
the `command_id`, written by the root agent under the actor who sent it;
`session.goal.clear {command_id, session_id}` writes `goal_cleared`. Setting the goal a
session already has, or clearing one it does not have, writes nothing. A `text` that is
empty or only whitespace is `invalid_params` with `field: "text"`.

The goal is part of the root agent's folded state, so it survives a restart and a
dormancy, and it is read into the root agent's context on **every** turn after it is set —
not only the next — until it is cleared or replaced. It is taken at once, not at the next
turn boundary: it changes the next request's prompt and never the one in flight. A
subagent is given its task by the root agent and does not carry the goal. Both commands
activate a dormant session, like `profile.switch`.

`session.goal.get {session_id}` → `{"goal": "…", "set_by": "<subject>", "set_at": "<ts>"}`,
or all three `null` when no goal is set. It is read from the log, so it answers for a
dormant session and wakes nothing.

#### `session.loop.start`, `session.loop.stop`, `session.loop.get`
```json
{"command_id": "c-7", "session_id": "s-9f", "max_iterations": 5}
```
→ `{"accepted": true, "loop_id": "loop-1", "max_iterations": 5}`. The session works
towards its goal on its own, one iteration at a time: `loop_started` carrying the
`command_id`, then for each iteration `loop_iteration_started`, a turn of the root agent
(an `input_accepted` echoing the iteration's `command_id` and a `user_input` from `loop`,
then the turn as usual) and `loop_iteration_finished`, and at the end `loop_stopped`.
`max_iterations` is optional and the session's `loop_max_iterations` (10) when absent; it
is otherwise a positive integer, or `invalid_params` with `field: "max_iterations"`. A
session with no goal answers `conflict` with `needs: "goal"`, and one with a loop already
running answers `conflict` with its `loop_id`. It activates a dormant session.

Each iteration ends with the agent's own verdict, given as a tool call and never read
from its prose: on the loop's turns the agent is offered `goal_complete {summary}`, and an
iteration in which it completes that call ends the loop with reason `goal_complete`. A
model that binds its thinking to its tools (Claude Fable 5.1, Opus 5.5 and Sonnet 5.5 and
later, a model the provider's own list says binds, or one whose config says
`binds_thinking`) is offered it on every turn, so its tools never
change, and a call to it on a turn that is not the loop's fails with a sentence saying no
loop is running. An iteration that ends without one is followed by
the next. The loop also stops when it has run `max_iterations`; when `loop_max_failures`
(3) iterations in a row fail (the model request failed, the agent ended short or
crashed, or the failure guard stopped the turn); when the budget question is asked (`budget`: the question stays with whoever
answers it, and the loop does not resume after an `allow`); when somebody cancels the
turn with `turn.cancel` (`cancelled`) or clears the goal (`goal_cleared`, and the turn in
flight finishes); and when the root agent has ended in a way input does not wake
(`agent_done`). Input a person sends meanwhile is taken between iterations.

`session.loop.stop {command_id, session_id}` → `{"accepted": true}`; the effect is
`loop_stopped` with reason `requested` and the `command_id`, written under the actor who
sent it. Any client with `control` may send it, at any point in an iteration: if the root
agent's turn is the loop's, it is cancelled (`cancelled` follows), and a person's own turn
is left to finish. Stopping when no loop runs writes nothing. It does not activate a
dormant session, whose loop is not running.

`session.loop.get {session_id}` → `{"loop": null}`, or `{"loop": {"loop_id", "state"
(`running` or `stopped`), "iteration", "max_iterations", "failures", "reason",
"detail", "summary", "goal", "started_by", "started_at"}}` for the session's latest
loop. It is read from the log and wakes nothing.

A loop is written down the way everything else is, so it survives what the session
survives. If the session stops mid-loop — a daemon that died, a session made dormant —
the loop does **not** carry on by itself when the session comes back: the first thing
the activated session writes about it is `loop_stopped` with reason `interrupted`, and
`session.loop.get` already answers `stopped` / `interrupted` while the session is
dormant. A daemon configured to resume (`resume_on_restart`) resumes the loop too.

#### `approval.respond`
```json
{"command_id": "c-4", "session_id": "s-9f", "call_id": "call_3",
 "decision": "allow"}
```
`decision` is `allow`, `deny`, or `allow_session`. **First response wins**; a later
one receives an `approval_resolved` event naming who resolved it, and has no second
effect.

A delegation's request (`approval_requested` with `delegation`, Decision 850) takes three
more, each optional: `agent`, one of the subagents its `delegation.agents` offers, to send
the same brief there instead; `brief`, the parts the person edited (`{"constraints": "…"}`),
laid over the brief and held to its shape, so a part sent blank is refused; `reason`, a
word back with `deny`, which the agent that delegated receives as the call's answer.
`allow_session` lets the agent it goes to run unasked for the rest of the session. A wrong
one is `invalid_params` with a `reason` saying why, and the request waits on.

```json
{"command_id": "c-6", "session_id": "s-9f", "call_id": "call_7",
 "decision": "allow", "agent": "explore", "brief": {"constraints": "Read only."}}
```

A publication's request (`approval_requested` with `publication`) takes `visibility`, whom
the artifact is for: `private`, `organisation`, `team:<name>` or `profile:<name>` (the
shape alone; a team the person is not in is the plane's to refuse, at publish); `owner`,
whose it is, `me` or `team` (a team publication is the team's unless `owner` is `me`; a
republish keeps its owner, so one given with `publication.id` is dropped); and `reason`, a
word back with `deny`. Each is optional where the model proposed one, which
`publication` shows; an `allow` naming no `visibility` where `publication.visibility` is
`null` is refused with `say whom it is for: visibility is private, organisation,
team:<name> or profile:<name>`, and the request waits on. The call then runs for whom the
person chose, and `approval_decided` says what it ran with and which of the two they
changed (`edited`). `allow_session` on a publication whose `visibility` was `null` is this
call's `allow`: nothing standing is created, since the next call's audience is not yet
chosen; on one that named a visibility it lets `publish_artifact` run unasked for the
session, as for any tool.

```json
{"command_id": "c-8", "session_id": "s-9f", "call_id": "call_9",
 "decision": "allow", "visibility": "team:core", "owner": "team"}
```

#### `question.answer`
```json
{"command_id": "c-5", "session_id": "s-9f", "call_id": "call_4", "text": "the blue one"}
```
The answer to a `question_asked` — the agent's `ask_user` tool, whose result is this
text. A client offering the question's `options` sends the chosen labels, joined with
`", "`; free text is always allowed. **First answer wins**; a later one changes nothing.

#### `todo.edit`
```json
{"command_id": "c-5", "session_id": "s-9f", "action": "cancel", "id": "t2"}
```
`action` is `add` (with `content`), `cancel`, or `complete`.

### Steering from another device

*(A daemon's, `admin`. A worker pod is reached through the plane already.)*

A person offers one of their sessions on this computer to the plane they are signed in to,
so they, from any of their other devices, and the people they name can steer it: follow its
transcript, answer its approvals and questions, send it prompts, cancel a turn and switch
its agent (Decision 921). Nothing listens on the laptop: while a session is offered the
daemon keeps one WebSocket open to the plane's `/v1/relay`, and the plane relays each
remote person's protocol messages over it ([Relayed connections](#relayed-connections)).

**The daemon's own sign-in** (Decision 928). At the first offer the daemon asks the plane's
`remote.grant {device}` with the plane token a client handed it (`identity.link`), keeps
the grant in the operating system's credential store (Credential Manager, the macOS
keychain, the Secret Service), never in a file, and exchanges it at `POST /auth/relay` for a
token of the laptop's door alone, renewed on the open socket before it runs out. So the offer
stays up after the client that made it closes, and after a restart of the daemon. Withdrawing
the last offer, `identity.sign_out` for that plane and person (a client's sign-out, `troupe
logout`) and `identity.unlink` release it at the plane, take it out of the store and close
the connection; the offers are kept, and offered again at the next link with a token. A
daemon with something offered does not stop at its quiet period.

#### `remote.offer`
```json
{"command_id": "c-6", "session_id": "s-9f",
 "share": [{"person": "bea@example.com", "role": "control"},
           {"person": "cy@example.com", "role": "observe"}]}
```
→ `{"session_id", "remote"}`, `remote` as `session.list` has it.

`person` is a subject or an email the plane knows, and `role` is `control` (steer it) or
`observe` (follow it), `observe` where none is said. The session's owner, the person linked
here, may always steer it and is never named. Offering again replaces the share. The answer
waits for the plane: one that does not know a person is `not_found` naming them, and
nothing is recorded; one that cannot be reached is `unavailable`.

**A private session** (Decision 952) is offered only with `"consent": "private"`, its
person's yes to what it says passing through the plane unsealed while it is offered; without
it the answer is `forbidden` with `data.consent: "private"` and `data.reason` the sentence a
client asks in (*This session is private: while it is offered, what it says and does passes
through the plane unsealed, and the plane relays it to whoever you invited with control. The
plane keeps none of it. Offer it?*). It names nobody (`invalid_params` on `share`): it is
shared with the people its log says are invited into it with `control`, and its `remote`
says `private: true`. Sealing goes on as before. `remote.withdraw` closes every view with
*The owner withdrew the offer: this private session is sealed-only again, and what it says
no longer passes through the plane.* A daemon with no plane token is `unavailable`, "sign
in to a plane first", and a session another person made while linked here is `forbidden`.
A person in a team whose administrators do not allow offering is `forbidden` with `data.team`
and a sentence naming it, as the plane says it.

The daemon keeps the offer and its share (`<state>/remote.json`) and dials the plane again,
backing off, whenever the connection drops: on connecting it says exactly what it still
offers, so a session withdrawn while the laptop was away is not offered again.

#### `remote.withdraw` → `{"command_id", "session_id"}` → `{"session_id", "remote": null}`

Every remote view of the session ends at once, closed here before the plane is told.
Erasing a session withdraws it.

### Identity

*(Local transports only. A worker pod knows who is calling from the token it was given.)*

A daemon authenticates by the socket's permissions, or by the token in a user-only file.
Either way it knows the *operating system's* user and calls them `local:<username>`,
which means nothing off this machine — so nothing it records could be billed, listed by a
plane, or opened from another device.

A client that is signed in tells it who that is, once.

#### `identity.get` → `{"linked": false}`, or
```json
{"linked": true, "subject": "ada@example.test", "display_name": "Ada",
 "plane_url": "https://troupe.example", "linked_at": "2026-09-14T08:00:00Z"}
```
with `update_required`, a sentence saying what to run, where the plane it is linked to
refused this daemon's version at the last link ([Client versions](#client-versions)), and
`plane_key`, the key that plane signs with as this machine pinned it ([The plane's
signing key](#the-planes-signing-key)):

```json
"plane_key": {"plane_url": "https://troupe.example", "algorithm": "ed25519",
  "public_key": "6kpsY+Kc...", "fingerprint": "SHA256:/oEsEvOr...", "pinned_at": "2026-10-18T08:00:00Z",
  "offered": {"algorithm": "ed25519", "public_key": "...", "fingerprint": "SHA256:...", "seen_at": "..."}}
```

`offered` is there only where the plane has served another key since: nothing that key
signs is taken until a person accepts it (`identity.accept_plane_key`). No `plane_key` for
a plane that signs nothing, or from a daemon from before it.

#### `identity.link`
```json
{"command_id": "c-2", "subject": "ada@example.test", "display_name": "Ada",
 "plane_url": "https://troupe.example", "plane_token": "..."}
```
Every connection made after this carries that subject as its principal, and the one that
made the call is relabelled where it stands. `session_created` gains an `owner` field
naming it. A blank subject is `invalid_params`.

`plane_token` is optional and is the one part of this that is not a label. The daemon
authenticates nobody, so it cannot obtain a plane token and has to be handed one by the
client that signed in — it needs one to register and seal a private session. It is held
in memory only: `identity.json` records the name, never the token, because a token on
disk is a token a backup copies. A restarted daemon therefore has no token until a client
links again, which costs nothing: the local log is already durable, so a daemon with no
token seals later rather than losing anything. A client that refreshes its token links
again, and so does one that finds the daemon restarted; the desktop app and `troupe` do
both for a daemon linked to the person signed in at that plane (Decision 764), and take it
back when the person signs out (`identity.sign_out`). A link that
carries one is also when the daemon asks the plane which of the person's private sessions
were erased while it was away, and drops its copy of each (Decision 756), and then carries
on sealing each private session it has no sealer for: from the row's `last_seq`, at the
epoch the row says, registered with that epoch so a claim made meanwhile refuses it, for
one this device sealed last; from its first event for one the plane has never heard of;
not at all for one another device sealed last, until it is claimed here
(`session.claim`), and `session.list` says `sync: "elsewhere"` of it meanwhile. Only the linked
person's are carried on: those whose `session_created` names `subject` as their `owner`,
and those made while nobody was linked, which name none. Somebody else's, made while they
were linked here, is left alone with this token, the daemon's log says how many of whose,
and it carries on at that person's next link (Decision 784). A link naming somebody other
than the person the daemon was linked to stops every sealer first, as `identity.unlink`
does, and keeps none of that person's token: a link without `plane_token` keeps the one
the daemon holds only when it names the same person.

#### `identity.unlink` → `{"linked": false}`. The events already written keep the actor
they were written with. The plane token goes with the link, and every private session's
sealer stops, as at `identity.sign_out`: nothing is sealed until a client links with a
token again, and then only the sessions of the person it links (issue #386).

#### `identity.sign_out`
```json
{"command_id": "c-3", "plane_url": "https://troupe.example", "subject": "ada@example.test"}
```
→ `{"signed_out": true}`

The person signed out of that plane at a client, which takes back the token it handed
over. The daemon forgets its plane token if it is for that plane and, where `subject` is
given, for that person, and stops sealing: each private session's sealer stops, as at a
restart, and nothing is sealed until a client links with a token again, when each carries
on as `identity.link` describes. Nothing on this disk is lost, and the label stays, so that
link is the same link. `signed_out` says whether there was a token to forget: `false` for
none, or one that is somebody else's or another plane's, which is left. A client that does
not know who signed out leaves `subject` out and takes back the token for that plane,
whoever it is for. `troupe logout` and the desktop app's *Sign out* send it (issue #381).

#### `identity.accept_plane_key`
```json
{"command_id": "c-4", "fingerprint": "SHA256:...", "plane_url": "https://troupe.example"}
```
→ `{"plane_key": {...}}`, as `identity.get` carries it.

The person accepting the key the linked plane (or `plane_url`) now signs with, in place of
the one pinned, by the fingerprint they were shown and checked. The daemon asks the plane
for the key it serves; it must be that fingerprint, and is pinned. Then the organisation's
document is fetched again. Any other fingerprint is `invalid_params`, naming the one the
plane offers; a plane that signs nothing has no key to accept. `troupe plane-key accept`
does the same to the same file.

**This is a label, not authentication.** Nothing here verifies a token, and nothing
should: anything that can reach the daemon can already do everything on it, and what
linking changes is the name in the record. A daemon reachable by somebody who should not
be linking has a much larger problem than the label.

### Reading

#### `blob.get`
```json
{"session_id": "s-9f", "blob": "sha256:1f3a…", "range": [0, 65535]}
```
→ `{"blob", "size", "encoding": "base64", "data": "…"}`

`range` is an inclusive byte range and is optional; omit it for the whole blob. The
answer is the bytes in that range, stopping at the blob's end, and `size` is the whole
blob's, so a client reading a blob in pieces counts the bytes it decoded and asks for the
next range until it has `size`. A range that starts past the end answers with no bytes.

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
can check that the file it read is the file the event announced. Reading a directory is
`not_found` (with the reason, `eisdir`); a file is bounded only by the WebSocket frame,
16 MiB. A `path` of
`scratch:/<name>` reads a scratchpad document (`scratch.list`), whose `hash` is the one
its `scratch_updated` carries.

#### `fs.upload`
```json
{"command_id": "c-9", "session_id": "s-9f", "path": "notes.md", "content": "…"}
```
→ `{"path", "bytes"}`: the path relative to the workspace, and how many bytes were
written.

Needs `control`: putting a file into a workspace is steering the session. The write is
recorded as an `fs_changed` event, carrying the file's `hash` and `size`, whose actor is
the client that uploaded it, not the session. `scratch:/` is read-only to it: only the
agent's `show` and `patch` write the scratchpad.

Where it lands is `session:/`, the directory the session works in (Decision 896). On a pod
that is the session's own, erased with it. On a daemon it is the checkout the session
was started in: git sees the file, another session in that checkout sees it, and erasing
the session leaves it there. A `path` whose prefix names no mount (`plans:/x`) is
`forbidden`, with a `reason` naming the ones there are, as every file tool refuses it.

#### `scratch.list`
```json
{"session_id": "s-9f"}
```
→ `{"documents": [{"name", "path", "kind", "title", "size", "hash", "version",
"updated_at"}]}`

The session's scratchpad (Decision 870): the documents its agents showed the person with
the `show` tool and revised with `patch`, the latest version of each name, in the order
each was first shown. Each row is what that name's last `scratch_updated` said, and
`updated_at` when it was written. It is a fold over the log, so a dormant session
answers it as a running one does, and a client that attaches late has the same rows from
its replay. Read a
document's words with `fs.read` of its `path`, the one read path there is. The documents
are the session's own, beside its log rather than in its workspace: an erasure takes
them, and a fork carries the ones its history shows.

#### `agents.list`
```json
{"workspace": "/home/me/project"}
{"session_id": "20260923T101112-q3Vx_A"}
```
→ `{"agents": [{"name", "description", "source", "notes", "mode", "layer", "origin",
"profile", "model", "tool_count", "read_only", "max_turns", "worktree", "available",
"reason", "path", "editable", "editable_reason", "overrides"}], "skipped": [{"name",
"path", "reason"}]}` — the primary agents a session in that
workspace may be created with, resolved as `session.create` resolves them (built-ins, the
machine's `agents/`, the project's `.troupe/agents/`). `source` is `builtin`, `global`
or `project`. Named by a session instead (#594), the rows are that session's own agents,
read again from their files as `profile.switch` reads them: on a pod the profile's bundle's,
the built-ins and its working copy's, in the order Decision 826 gives them. That is the one
list both clients' agent pickers read, and on a pod a token a plane mints for the session
may ask it (§7) when it names the session and no `workspace`; named by a workspace, a pod's
listing is about a path on the pod and such a token is refused it. One of the two is named.
`skipped` is each agent file found and
not read, with why: one that is a link out of the workspace (`not read: outside the
workspace`; a `.troupe/agents` linked out whole is one entry with a null `name`,
Decision 829), in a git worktree one the main checkout has not committed, or one that does
not parse, with what is wrong in words (`not read: mode must be primary or subagent, not
"main"`, Decision 841), which the session's `files_skipped` carries too. Additive.

With `"subagents": true` the subagents an agent delegates to are listed as well, after the
primaries, each in the same shape (Decision 852): what an agents manager asks, so a person
can read and change `explore` or `reviewer`; a picker of what a session runs never asks,
since `session.create` and `profile.switch` refuse a subagent. Every row says its `mode`,
`primary` or `subagent`. Both are additive: a daemon before them lists the primaries alone
and its rows have no `mode`.

`notes` is what a person should know about how an agent is read, each `{"key",
"reason"}` with the reason in words, and empty for most. A `project` agent whose
`permissions:` set a tool to `auto` in a workspace that is not trusted has one with the
`key` `permissions`: the `auto` applies once the workspace is trusted, the tool asks until
then, and the reason names the command that trusts it (Decision 825). A daemon trusts a
workspace as its user's `trusted_workspaces` says, and a worker trusts none. The key is
additive; a client that does not know it shows the agent as before.

What decides whether a person wants an agent, on each row (Decision 841, additive):
`layer` is where it is read from, `builtin`, `bundle`, `user` (the person's `agents/`,
which `source` calls `global`) or `project`, the last two the `scope` `agents.put` writes;
`model` as the definition names it (`null` is the session's own); `tool_count`, the tools
it holds (an MCP server's or a client's are counted only by a session that runs them);
`read_only`, true when it denies `write_file`, `edit_file` and `shell`; `max_turns`
(`null` for no cap of its own); `worktree`, whether a session started on it here now would
get a worktree of its own (a git repository with a session already working in it, as
`session.create`'s `"auto"` decides, so the same for every row today); `available`, false
with `reason` in words when a session could not run it here, which today is a model the
provider does not serve by the list the daemon keeps (Decision 778); a list never fetched
says nothing either way.

What a picker shows of each (#594, additive): `origin` is where it comes from in the four
words a person uses, the same in every client: `Shipped` (Troupe's own), `Your
organisation's` (the profile's bundle), `Yours` (the person's `agents/`, read in every
workspace) and `This repository's` (`.troupe/agents/`, read once the workspace is trusted);
`profile` names the plane's profile a bundle's agent came with, as the session's pin says
it, `null` for any other; `path` is its file; `editable` and `editable_reason` say whether
a person may change it here as `agents.get` says it; and `overrides` (`[{"layer",
"origin", "path"}]`, nearest first) are the files of the same name in lower layers it
stands in for, which `agents.get` has called `also`.

#### `agents.get`, `agents.validate`, `agents.put`, `agents.delete`, and `agents.changed`

An agent read whole, checked, written and taken away (#503, Decision 841). Both clients
manage one set through these and never write the directories themselves, so the checks
and the choice of layer happen in one place. Writing is the daemon's, like `mcp.*`
(Decision 700). On a pod a token a plane mints for one session reads and checks its own
session's agents, `agents.get` and `agents.validate` naming the session and no
`workspace` (#594), and is refused the rest (§7); with a token for no session, a pod reads
and checks, and refuses `agents.put` and `agents.delete` as `forbidden` with `reason` "On a pod
the agents come from the profile's bundle and are read-only here: change them in the
console".

```json
{"name": "plan", "workspace": "/home/me/project"}
```
`agents.get` (`observe`; `workspace` or `session_id`, or neither for the person's own and
the built-ins) → one definition, as the session would run it: every key of an
`agents.list` row, plus `mode` (`primary` or `subagent`), `tools` (`"all"` or the list),
`permissions` (`{"<tool>": "auto"|"ask"|"deny"}`), `budget_share`, `delegation` (`ask` when
a delegation to it asks first by its own file, else `auto`; Decision 850), `skills` (`"all"` or
the list), `prompt` (the instruction, the file's body), `path` (the file, `null` for a
bundle's ACP agent), `text` (the file as it is on disk, frontmatter and all, for an
editor), `hash` (`"sha256:<hex>"` of `text`, `null` with no file: what `agents.put`'s
`if_hash` names, Decision 852), `editable` and `editable_reason` (`null` when editable; otherwise a sentence: a
built-in is changed by a copy in a scope, a bundle's agent in the console, and on a pod
none here), `also` (`[{"layer", "path"}]`, the files of the same name in lower layers this
one hides, nearest first: what answers once this one is taken away) and `running`
(`[{"session_id", "parent"}]`, with a `session_id`: the windows of that session's family,
the session, its branches and, for a branch, the session it came from and its other
branches, that run this agent now; empty without one). With a `session_id` the
definitions are that session's (on a pod its bundle's), read again from their files as a
switch would read them. A name nothing defines is `not_found` with `kind: "agent"`.

`broken` (Decision 852) is the person's or the workspace's file of that name that was found
and does not parse, the one that would answer once mended, for an editor to open: `{"scope",
"layer", "path", "text", "hash", "reason"}`, `scope` being where `agents.put` writes it back
(`user` or `project`) and `reason` the words `agents.list`'s `skipped` gives; `null` when
there is none. It is beside what answers to the name (a `.troupe/agents/plan.md` that does
not parse leaves the built-in `plan` answering), and when nothing answers the answer is
`{"name", "broken"}` alone rather than `not_found`. A file not read for another reason (a
link out of the workspace, a main checkout's draft, one a bundle's name beats) is never
`broken`: it is not at the place `agents.put` writes.

```json
{"source": "---\nmode: primary\n---\nYou review.\n", "name": "review", "workspace": "/home/me/project"}
```
`agents.validate` (`observe`) → `{"ok": false, "errors": [{"field", "message"}],
"warnings": [{"field", "message"}]}`, writing nothing. `field` is a frontmatter key
(`mode`, `tools`, `model`, …), `permissions.<tool>` for one permission, `frontmatter`
when it is not YAML, `name`, or `prompt` and `description` for the warnings. Errors: a key
no agent has (the keys are `description`, `mode`, `model`, `tools`, `permissions`,
`max_turns`, `budget_share`, `skills`, `override` and `delegation`, and onboarding's
`imported_*`); `delegation` not `ask` or `auto`;
`mode` missing or not `primary`/`subagent`; `tools` or `skills` not `"all"` or a list; a
tool that does not exist (with the nearest that do; a pod's GitHub tools, `git_push`,
`pr_open`, `pr_comment` and `pr_checks`, exist everywhere here, though only a pod session with a
repository has them); a permission not `auto`, `ask` or
`deny`; a permission that grants (`auto` or `ask`) a tool `tools` does not list, which
could never apply (a `deny` of one is allowed, as the built-ins write it); a model the
provider does not serve, by the list the daemon keeps (Decision 778), with the nearest it
does; `max_turns` not a whole number above 0; `budget_share` not a number above 0;
`override` not true or false; a name an agent may not have. Warnings: an MCP server's
(`mcp.<server>.<tool>`) or a client's (`client.<name>`) tool, which is known only once it
runs; a model when the provider has never listed its models on this machine; a
`budget_share` above 1 (read as 1); an empty description or instruction. `name` is the
name it would be saved under; the configuration the model is checked against is the
workspace's (or the session's).

```json
{"command_id": "c-30", "name": "review", "scope": "project", "workspace": "/home/me/project",
 "source": "---\ndescription: Reviews.\nmode: primary\n---\nYou review.\n"}
```
`agents.put` (`admin`) checks `source` as `agents.validate` does and writes it as it is,
as `<config>/agents/<name>.md` (`scope: "user"`) or `<workspace>/.troupe/agents/<name>.md`
(`scope: "project"`; `"workspace"` is taken as the same, the word `mcp.*` uses; it needs
`workspace` or `session_id`) → `{"name", "scope", "layer", "path", "action": "created" |
"replaced", "warnings"}`. One with an error is `invalid_params` with `reason` (the first
error, and how many more), `errors` and `warnings`, and nothing is written. The file goes
through the writer onboarding writes with (Decision 823), judged where it really is: a
project file must be under the workspace's real `.troupe/`, so a `.troupe` or
`.troupe/agents` that is a link out of the workspace, or an `<name>.md` that is one, is
`invalid_params` with a `reason` naming where it resolves (Decision 829's edge, held by the
writer too); a temporary file is renamed over it. A name an agent may not have is
`invalid_params` with `field: "name"`, a bad `scope` with `field: "scope"`. A built-in is
changed by a copy: a `put` of its text, under its name (which then hides it) or another,
into either scope. A user agent that the workspace's `.troupe/agents` has a file of the
same name for is written, with a warning that the repository's is the one that runs there.

`if_hash` (optional, Decision 852) is the `hash` `agents.get` gave for the file this save
replaces, which a client sends when it saves an edit back into the file it was opened from.
When the file there holds anything else now, saved by another client or by hand, or is gone,
nothing is written and the answer is `conflict` with a `reason` in words ("…/review.md
changed since it was opened, saved from somewhere else: nothing is written. Read it again
to see the change; saving over it replaces that change", or that it "was taken away since
it was opened") and `hash`, what the file holds now (`null` when gone), which a save that
means to replace it sends as its `if_hash`. It is checked in the same transaction as the
write. Without it the last write wins, as before; a copy into another scope, or a new
agent, sends none.

```json
{"command_id": "c-31", "name": "review", "scope": "project", "workspace": "/home/me/project"}
```
`agents.delete` (`admin`) takes `<name>.md` away from the scope's directory (a link
itself, not what it points at) → `{"name", "scope", "path", "deleted": true, "layer"}`,
`layer` being the one that answers to the name now (`builtin` once a copy of a built-in is
gone), or `null`. A built-in's name with no copy in that scope is `forbidden` with a
`reason`: a built-in is not deleted. Any other name with no file there is `not_found` with
`kind: "agent"`.

`agents.changed` (a notification, server → client) is sent to every client attached once
an `agents.put` or `agents.delete` has written, the one that made it included, so one
client's list follows what another saved:

```json
{"jsonrpc": "2.0", "method": "agents.changed",
 "params": {"name": "review", "scope": "project", "path": "/home/me/project/.troupe/agents/review.md",
            "action": "created", "workspace": "/home/me/project"}}
```
`action` is `created`, `replaced` or `deleted`; `workspace` is there for `project`. A
file edited by hand is not announced: `agents.list` and `agents.get` read the files each
time they are asked.

A session's agent, or a branch's, is changed with `profile.switch` (Steering, above): the
same method, read from the file at the switch.

#### `commands.list`
```json
{"session_id": "s-9f"}
```
→ `{"commands": [{"name", "aliases", "section", "summary", "usage", "args", "availability",
"source", "detail", "example"}]}`

The slash commands a client may offer for the session — the one table behind every
client's palette, so `/help` in the terminal and the desktop app show the same list and
adding a command is one change in the harness. Entries come grouped by `section`, in
the order a palette shows them: `session`, `navigate`, `workspace`, `setup`, `agents`,
`custom`, `quit`; a section with no entries is absent. Each has a `name`, its
`aliases`, a one-line `summary`, how it is typed (`usage`: `/upload <path>`), its
`args` (`{"name", "required", "kind"}`, where `kind` is `window`, `file`, `path` or `text`, for
completion), a longer `detail`, an `example` or null, and where it came from: `source`
is `builtin`, `agent`, `user` or `project`. The agents are the primary ones the session
was started with, described by their definition: on a pod its bundle's, as the team's
grant narrows them, and for a session that is asleep the ones `agents.list` answers with
for its workspace. They take a `prompt` and start a branch on it, which a client without
branches shows as such.

The `custom` section is the commands markdown files define: `<config>/commands/<name>.md`
(`source: "user"`) and the workspace's `.troupe/commands/<name>.md` (`source:
"project"`), the workspace's winning a name both have. The file name is the command, the
frontmatter's `description` its summary (the prompt's first line without one) and its
`argument-hint` what `usage` says follows the name; `detail` names the file, and `body`,
which only these entries carry, is the prompt it sends as the file has it, `$ARGUMENTS`
and all, for a palette to show before it runs (Decision 814). `agent`, only where the
frontmatter names one, is the agent the file says it runs on, which a client that starts a
branch for it starts it on (the terminal client's command mode, TUI Decision 155). A name a
built-in, an alias or one of the session's agents has stays theirs, and the file is
skipped. The files are read when the table is asked for, so one written a moment ago is
listed. A client runs one with `commands.run` (Steering, above) and needs no code of its
own for any of them.

`availability` is what the command needs, for a client to judge and say rather than
hide the row: `always`; `window` (acts on a window — the activated one, or one named
as an argument); `local` (a session on this machine: a pod has no checkout, watcher or
project brief of the person's to act on); `plane` (needs a plane). A client runs what
it can and shows the rest greyed with the reason. Reading the table wakes nothing.

#### `memory.get`
```json
{"workspace": "/home/me/project"}
```
→ `{"status": "fresh", "path": "/home/me/project/.troupe/memory.md",
"built_at": "2026-09-20T10:00:00Z", "sections": ["Overview", "Layout", "Commands",
"Conventions", "Notes"], "text": "...", "repository": true, "refresh_due": false, "refresh_held_until": null,
"generated": true, "facts": [{"id": "f_5c0d9a3e71b2", "kind": "command", "claim": "The gate is
`mix check`", "scope": null, "anchors": [{"path": "mix.exs", "hash": "9f2c...e1"}],
"evidence": {"session": "s_01J...", "seq": 412, "head": "7f8a221", "exit_status": 0, "by":
"librarian"}, "created_at": "2026-10-10T09:00:00Z", "verified_at": "2026-10-10T09:00:00Z",
"status": "current"}], "model": {"usable": true, "reason": null}}`

The **project brief**: what earlier agents learned about the repository, read into
every agent's system prompt and written by the `remember` tool and the `librarian`
agent. `status` is `absent` (no facts), `stale` (never built, older than
`memory_max_age_days`, or a command or convention it holds rests on a file that changed or
went since it was last checked, Decision 838), `fresh` or `disabled` (`memory: false` in the workspace
config). A `librarian`'s run that ends as it meant to builds it, whether or not it
rewrote any of it.
`remember` with `level: "me"` writes the person's own memory on the plane instead (#55,
Decision 943): one entry, `claim` and an optional `topic`, added at the end of that topic's
`## <topic>` section (`Notes` for none, made where there is none, Decision 957) through the
daemon's `me.memory.put` or, on a pod, `session.memory.put`; refused with a sentence offering the
repository where the session's person is signed in to no plane. It has no level for the
organisation's, a team's or a profile's memory, which no tool writes.
One brief per repository: a worktree's is the main checkout's, and so is that of a folder
the repository tracks or would add. A folder the repository ignores keeps a brief of its
own, as a directory in no repository does (Decision 881). `repository` says which:
`false` outside a repository and in an ignored folder (a daemon from before it sends none).
`refresh_due` is whether
a client should start a `librarian` session on the workspace now, which is what
`memory_auto_refresh` asks of it: the workspace is in a git repository (`repository`;
never in a directory none holds, such as a home directory, or in a folder the repository
ignores), the brief is `absent` or `stale`, and no librarian has
started on it in the last `memory_max_age_days` without its being built since. A
librarian's run that failed, was cancelled or wrote nothing is tried again that much
later, not in every new session; `refresh_held_until` is when (or `null`), for a
client to say why it started none. `memory.forget` forgets that try with the brief.

The brief is made of **facts** (Decision 839), and `facts` lists every one, kind by kind
(`overview`, `layout`, `command`, `convention`, `negative`, `note`), oldest first within a
kind. `claim` is the fact in a sentence or two; `scope` a glob of the paths it applies to,
or `null` for the whole repository; `anchors` the files it was read from, each by its
`path` from the repository's top and the lowercase hex SHA-256 of what the file held when
the fact was written, which Troupe took and no model gave. `evidence` is where it came
from: the `session` and the `seq` of the `remember` call that wrote it, the repository's
`head` then (`null` outside git), `exit_status` when it is a command the session ran
(absent otherwise), and `by`: `librarian`, `agent:<name>`, `person` (a hand edit of the
brief, read back) or `migrated` (from a brief written before facts). `id` names the fact
for `memory.forget`; `created_at` is when it was first written and `verified_at` when it
was last checked. `status` is computed as the answer is made, never stored: `current`
(every anchor holds what it did), `moved` (an anchor changed) or `missing` (one is gone),
both of which a client shows as "may no longer be true", and `unanchored` (no anchors: it
ages out by `verified_at`). `generated: true` says `text` and `sections` are a view of the
facts, rewritten whenever they change. A daemon from before facts sends neither key, and a
client shows the brief as it did. In a repository an anchor git does not track (ignored, or
never added) is `missing` and never hashed, as `remember` refuses to write one.

`model` says whether a model can be asked under the workspace's own config (Decision 854):
`usable`, and when it is `false` the `reason` in words (`anthropic has no key, so no model
can be asked`, or why a `{env:VAR}` the key reads was refused). `setup.get`'s `usable` is
the machine's; a client starting a `librarian` on the workspace reads this one. A daemon
from before it sends no `model`. `control`: the path is any the client names, and reading a
brief there may migrate it, or read a person's edit back, into facts.

#### `memory.forget` → `{"command_id", "workspace", "id"}` (`id` optional)

With an `id`, forgets that fact alone and answers `{"forgotten": true, "id": "f_5c0d9a3e71b2"}`;
an `id` no fact has is `not_found`. Without one, deletes the whole brief, as before:
`{"forgotten": true}`. `admin`.

#### `memory.decline` → `{"workspace"}` (`command_id` optional)
→ `{"declined": true}`. The person said no to rewriting a brief an older version of the
librarian's survey wrote (`onboard.plan`'s `brief.due` `outdated`): it is not due again
until the survey changes. Kept in the state directory under the brief's path, so every
checkout of the repository shares it. `control`.

#### `onboard.plan`
```json
{"workspace": "/home/me/project"}
```
→ `{"onboarding": {"due": "first", "recorded": null, "version": 2, "tools": ["Claude Code",
"Cursor"], "items": [{"id": "3f1c0a9e5b7d2c41", "target": "workspace", "path": "AGENTS.md",
"shown": "AGENTS.md", "status": "new", "question": "create_agents_md", "source": "CLAUDE.md",
"also_from": [], "was": null, "notes": [], "diff": "+ # AGENTS.md\n..."}, {"id":
"9a0be4f27c1d3e58", "target": "repo", "path": "rules/style.md", "shown":
".troupe/rules/style.md", "status": "new", "question": "write", "source":
".cursor/rules/style.mdc", ...}], "skipped": []}, "brief": {"due": "first", "recorded":
null, "version": 2}, "refusal": null}`

What a session's start asks, in this order (Decision 835): onboarding other tools' files
into Troupe's own, then the brief. The daemon's alone; `admin`, since it answers with what
other tools' files hold, the person's own among them. **Onboarding** is `due` `first` when
the workspace is in a git repository, has other tools' files, nothing has been onboarded
there and nothing declined; `outdated` when it was onboarded under an older version of the
onboarding rules (`recorded`) than this build's (`version`); `none` otherwise: outside a
git repository (the home directory, whose `.claude/` is Claude Code's own), and once the
person has said no for this version. While it is due, `items` lists every file onboarding
would write, the workspace's and the person's own (into their config directory), each as
`troupe onboard` shows it: `target` (`workspace`, `repo` or `user`), `path` under it,
`shown`, `status` (`new` or `changed`), `question` (`write`, or `create_agents_md` for an
`AGENTS.md` that is not there, which is always asked on its own, Decision 827), `source`
and `also_from` (the other tool's files it is made from), `was` (what it was onboarded from
before), `notes` (one sentence per key left out or changed) and `diff`; `tools` names the
other tools they come from, and `skipped` is each file found and not proposed, with its
`reason`. While it is not, `items`, `tools` and `skipped` are empty and no source is
asked, so a start where nothing is due does not walk the workspace. An `id` names a file as it was shown: once its source or the
file changes it names nothing. **The brief** is `due` `first` (none) or `stale` when a
`librarian` should start, as `memory.get`'s `refresh_due` says; `outdated` when an older
survey wrote it (`recorded`, `0` for one from before there were versions) and the person
has not said no to rewriting it (`memory.decline`); `none` otherwise. Whether to start
anything at all is the client's (`memory_auto_refresh`). When onboarding is due, a client
starts the librarian only once onboarding is answered, so it reads what was written. On a
daemon running on a machine a worker runs on (`TROUPE_WORKER_AUTOSTART=true`) onboarding is
never due, and `refusal` is the sentence saying it runs on the person's own machine. A pod
has no `onboard.*` at all: it answers `method_not_found`.

#### `onboard.apply` → `{"workspace", "ids": [...]}` or `{"workspace", "all": true}` (`command_id` optional)
→ `{"written": [{"id", "shown", "action"}], "refused": [{"id", "reason"}]}`. Writes the
files named, or with `all` every one whose `question` is `write` (an `AGENTS.md` that is not
there is written only when its id is named), each with its provenance (Decision 823), and
never over a file that changed since it was shown. `action` is `created` or `replaced`; an
id that names no file the plan holds now is refused with a sentence. Once a call has
answered every file the plan held, the workspace is recorded as onboarded under this
build's rules. `admin`: it writes into the repository and into the person's config
directory. Outside a git repository, where the plan is due nothing, it and
`onboard.decline` are refused (`invalid_params`, with the sentence) and nothing is written
or remembered (Decision 854); `troupe onboard` still runs wherever it is asked to.

#### `onboard.decline` → `{"workspace", "ids": [...]}` or `{"workspace", "all": true}` (`command_id` optional)
→ `{"declined": n}`. Says no to the files named, or to all of them: each is not proposed
again until its source changes (`troupe onboard --all` offers it anyway), and `all` also
remembers the no to onboarding the workspace under this version of the rules, so a start
does not ask again until they change. Nothing is written but the person's answer, in the
state directory. `control`.

#### `context.get`
```json
{"session_id": "s-9f"}
```
→ `{"budget": 16000, "used": 1234, "searched": ["/home/me/.config/troupe", "/home/me/project"],
"files": [{"scope": "root", "path": "/home/me/project/AGENTS.md", "size": 812, "chars": 800,
"budget": 16000, "share": 0.05, "status": "whole", "reason": null, "trimmed": 0,
"skipped": [], "imported_by": null,
"unfollowed": [{"import": "docs/gone.md", "reason": "missing"}], "rule": null, "applies": null,
{"scope": "root", "path": "/home/me/project/CLAUDE.md", "size": 0, "chars": 0,
"budget": 16000, "share": 0.0, "status": "skipped",
"reason": "not read: run troupe onboard", "trimmed": 0, "skipped": [],
"imported_by": null, "unfollowed": [], "rule": null, "applies": null, "hash": null},
{"scope": "brief", "path": "/home/me/project/.troupe/memory.md",
"size": 0, "chars": 0, "budget": 6000, "share": 0.0, "status": "absent", "reason": null,
"trimmed": 0, "skipped": [], "imported_by": null, "unfollowed": [], "rule": null,

The **provenance of the prompt**: every file the session's next system prompt is read
from, in the order it is read — first the organisation's memory documents (#55,
Decision 922), each with `version`, `name` and `label` beside the fields below: the
organisation's (`organisation`, `path` `memory:organisation`), a team's (`team`,
`memory:team/<name>`) and a worker profile's (`profile`, `memory:profile/<name>`, the
profiles it extends first), as the session's next turn reads them: what it started with, or
what a save on the plane gave it since (`memory_changed`), outside the files' budget and held to the plane's limit (their
`budget` is that limit in bytes); then the person's own `<config>/AGENTS.md` (`user`), the
repository root's (`root`), one in each directory between the root and where the
session works (`nested`, parents before their children): the workspace and the
directory of each file the root agent's conversation has read, edited or written — and
the project brief (`brief`). A file one of them imports with `@path` comes right after
it, in its scope, with `imported_by` naming the importer; `unfollowed` lists the imports
a file names that were not read, each with its `reason`: `missing`, `outside` the
repository (the config directory for the person's own file), `depth` past five, or
`cycle`. Each file comes with its `size` on disk, the `chars` that reach the prompt, the
`budget` those count against (`instructions_max_chars` for the files together,
`memory_max_chars` for the brief) and its `share` of it. Every file applies and the
nearest wins where two disagree. `status` is `whole`; `trimmed`, with `trimmed` saying
how many characters were cut, the nearest scope (a file and what it imports) being kept
whole first; `dropped`, the budget was spent before it; `outside`, the file found (the brief
too) is really outside the repository (or, for the person's own, the config directory),
through a link, and was not read, its `size` and `chars` 0 and its `hash` null;
`unreadable`, the file is there and could not be read, the same; `skipped`, found and not
read, with `size` and `chars` 0 and `hash` null too; or, for the brief, `absent` or
`disabled` as `memory.get` has it. Other tools' files are not read (Decision 828): a
`CLAUDE.md` or `GEMINI.md` in one of those directories, `.github/copilot-instructions.md`
and `.github/instructions/*.instructions.md` at the repository root, Cursor's root`
.cursorrules`, and `.cursor/rules/*.mdc` in any of those directories are each listed after
the directory's own file as `skipped`, so nobody debugs a file that was
never loaded. Copilot reads its file at the repository root only, so one in any other
directory is listed as `skipped` with a reason of its own (Decision 806). `skipped` on a
file is always empty now that no other name stands for `AGENTS.md`, kept for the clients
that read it. An `.agents/AGENTS.md` in the root or one of those directories (Decision
822) comes right before that directory's file, in its scope.
`reason` says in words why a file is left out, the same words `/context` prints, and is
null for a file that reached the prompt and for a brief `absent` or `disabled`: `not
read: run troupe onboard`, `not read: outside the repository` (`outside the config
directory` for the person's own), `not read: permission denied` (or another reason the
system gave), `not read: Copilot's file counts only at the root`, `not read: onboarded
into <target>` for a file onboarding has already brought in, or `left out: the budget was
spent on nearer files`.
A rule (Decisions 809 and 828), each `.troupe/rules/*.md` in the root and in a directory
on the way to where the session works, comes after that directory's file and its
imports, in name order, in the directory's scope, with its front matter in `rule`:
`apply` (`always`, `globs`, `requested` for a rule with only a `description`, or `manual`
for one with none), `globs`, `description`, and `matched`, the file worked on that a glob
matched, from the directory that holds `.troupe`. One that
reached the prompt says why in `applies` (`always applied`, `applied: src/a.ts matches
src/**/*.ts`). One that did not is `inactive`, `chars` 0, with `reason` `applies when a
file matching src/**/*.ts is read or edited` or `not joined: no alwaysApply, globs or
description`; or `listed`, its `description` alone in the prompt and counted in `chars`,
with `reason` `requested by description only: listed in the prompt, not joined`. `rule`
and `applies` are null for every other file.
`memory_from`, where a plane gave any, says where the memory documents came from: `source`, the plane's URL, or
`the plane, with the session's activation` on a pod, and `fetched_at`, when this machine
fetched its copy.
`searched` is every directory looked in. Read from disk when asked, as the next
turn reads it, so it says what an edit will do; what a past turn read is its
`instructions_loaded` event. Nothing reaches the prompt from a file without appearing
here. Reading it wakes nothing: a session that is asleep is answered for its workspace
alone, without the directories its conversation worked in.

#### `mcp.status`
```json
{"session_id": "s-9f"}
```
→ `{"servers": [{"name": "filesystem", "state": "ready", "tools": ["read_file", "list_directory"],
"error": null, "layer": "workspace", "source": "/home/me/project/.troupe/mcp.json"}]}`

The MCP servers the session runs of its own — `mcp:` in `config.yaml` (`layer`
`config`), the user's `mcp.json` (`user`) and the workspace's `.troupe/mcp.json`
(`workspace`), `source` naming the file — as distinct from a pod's bundle servers:
`state` is `connecting`, `ready`, `error`, `stopped`, `pending` (the workspace's trust
question below is unanswered), `disabled` or `sign_in` (the server wants the person
signed in and they have not, or their sign-in has run out: `mcp.sign_in` below). Their
tools are `mcp.<server>.<tool>` like every other MCP tool.

#### `workflows.list`
```json
{"workspace": "/home/me/project"}
```
→ `{"workflows": ["default", "release"]}` — `default` is the built-in pipeline
(understand → plan → implement → test → document → verify); the rest are the
`.troupe/workflows/<name>.json` files in the workspace, each a JSON array of
`{"name", "prompt", "agent"?, "parallel"?}` steps.

#### `config.get`, `config.models`, `config.set`, `config.import`, `config.organisation`, `config.memory`, and `config.changed`

The machine's own settings — the provider, key and models every local session starts
from, and every other key of `config.yaml` — for a settings screen, so the desktop app and
the terminal UI show and change the same settings (#57). **The daemon's only**: a worker
answers `method_not_found`, because a pod's provider is its profile's business — or
`forbidden` to a token for one session, like every method not about its session (§7).
The one exception is `config.get` naming a session (below), which a pod answers too,
its session's own token included.
They edit `config.yaml` at the scopes of the configuration ladder: the user's file in the
daemon's config directory (`user`), a workspace's `.troupe/config.yaml` (`project`) and its
git-ignored `.troupe/config.local.yaml` (`local`). A client names a scope and never a
path, because the daemon is the process whose environment decides which file a session
reads. There is no second settings file.

```json
{"workspace": "/home/me/project"}
```
`config.get` (`observe`; `workspace` optional) → `{"config_dir", "path", "exists",
"provider", "base_url", "auth", "api_key_set", "api_key_source", "key_help", "models": {"default",
"cheap", "expensive"}, "overrides": [{"source", "detail"}], "provider_types", "workspace", "trusted",
"files", "organisation", "keys", "warnings", "errors"}`. The first fields are what the user's **file**
says, since that is what the model panel's save changes. `provider_types` is what a screen
offers to choose from, the one list of the provider types every party reads
(`Troupe.Protocol.ProviderTypes`, issue #658): `[{"name", "label", "summary", "url",
"default_url", "url_example", "key", "key_var"}]`, every type but `fake`. `url` is `own`
(the vendor's endpoint, which a gateway speaking its API stands in for at a `base_url`),
`server` (a server of the person's, `default_url` unless one is given) or `required` (no
default; `url_example` shows its shape); `key` is `required` or `none`, and `key_var` the
variable read when no key is given. A daemon before #658 sends no `provider_types`, and
takes `anthropic` and `openai`. The key is never in the answer:
`api_key_set` says whether one is in force and `api_key_source` where from (`file`, `env`,
`organisation` for a key the organisation hands to everybody through its document, or
null; a daemon before Decision 828 also said `opencode`). `key_help` is the organisation's
word on where a key comes from, from the machine's copy of its document (`me.client_defaults`'s
`key_help`), for a screen to show beside the key field; null where it says nothing. `overrides` names what beats
the file anyway: a project's `.troupe/config.yaml` or `.troupe/config.local.yaml` (only
when `workspace` is given, and in a workspace that is not trusted only for the keys trust
does not gate) or a `TROUPE_*` variable; opencode's settings beat nothing, being copied in (`config.import`)
and never read for a session. `config_dir` and `path` are written
as a person on the daemon's platform writes them, for a screen to print.

`keys` is every key the schema knows (`protocol/schema/config/v1.json`), as a session in
`workspace` would read it (`troupe config --explain`): `{"key", "value", "layer",
"source", "default", "scopes", "enforced", "secret", "label", "doc"}`. `layer` is the one
that set the value in effect — `default`, `org`, `user`, `project`, `local`, `env`, `cli`
or `enforced` — and `source` its file or variable, or for `org` and `enforced` the plane's
URL or the managed file's path (Decision 869). `enforced` is `{"value", "source"}` where the
organisation enforces the key, whether or not that value is the one in effect (a lower
value within a ceiling is), and null otherwise. A secret's `value` is `****`, or the
`{env:VAR}` a file wrote when the variable is not set; never the secret. `scopes` are the
scopes `config.set` writes the key to here: only `user` without a workspace, for the trust
list, and for a key marked trusted while the workspace is not; none for `version` and
`$schema`, and none for a key the organisation enforces. `label` is the name a settings
page shows the key by and `doc` its help, the same in both clients and in the generated
reference. `files` is each scope's file, `{"scope", "path", "exists"}`; `organisation` is
where the organisation's layer is read from, `{"scope": "org", "path", "exists"}` for the
managed file and, when the daemon keeps one, the plane's document with its URL as `path`
and `fetched_at`; `trusted` whether the workspace is; `warnings` what loading warned about.
A file that is refused leaves `keys` empty and says why in `errors`. These fields were added
for #57, and `enforced` and `organisation` with Decision 869; a daemon from before answers without
them, and a client that finds no `keys` sets no single key (below).

`permissions` is every file's per-tool permission rules (#658, Decision 907), which are not
keys: every scope's are kept together rather than the highest one's, so `keys` leaves
`permissions.*` out. Each is `{"action", "rule", "tool", "pattern", "scope", "source",
"ignored"}`: `action` is `deny`, `ask` or `allow`; `rule` the rule as written
(`shell(git push)`); `scope` the layer it came from (`org`, `enforced`, `user`, `project`,
`local`) and `source` that file, or the plane's URL; `ignored` why it does not apply (an
`allow` in a project's file of a workspace that is not trusted, or any `allow` but the
organisation's under `managed_permission_rules_only`), else null. A client shows them and
sets none. A daemon before #658 sends no `permissions`.

```json
{"session_id": "20261018T101112-a1B2c3", "explain": "text", "key": "max_turns"}
```
`config.get` with a `session_id` (`observe`) is that running session's configuration
instead, what is in force in it (Decision 918): what was resolved as it started, each value
and rule with where it came from, so a file changed since does not change the answer. A
daemon answers it for its own sessions and a worker for its pod's, to the session's own
token as to anyone the session's role lets observe; a session not running there is
`not_found`. The answer is `workspace`, `trusted`, `files`, `organisation`, `keys`,
`permissions`, `warnings` and `errors` as above, without the model panel's fields, plus
`session_id` and `pod`. On a pod (`pod: true`) `layer` has two more values: `profile`, the
worker profile's settings, which are the pod's environment, its `source` naming the
profile and the variable (`the worker profile fixing (TROUPE_MODEL)`); and `session`, the
terms the session was created with (`the session's terms`). What the platform enforces
(`managed_permission_rules_only`, `managed_mcp_servers_only`) is `enforced`, from `the
plane's platform settings`; what the pod sets of its own is `cli`, from `the worker pod`;
the worker profile's rules are in `permissions` with `scope` `profile` and `source` the
profile that wrote each; and a repository's own files are read as a pod reads them, no key
marked trusted taken from them. No key has a scope on a pod: none of it is a client's to
write. `explain` (`text` or `json`) adds what `troupe config --explain` prints for the
session, as `explain` (a string, or the JSON object), with `explain_status`, the exit
status it would have; `key` narrows it as `--explain KEY` does. A daemon or worker from
before Decision 918 does not answer this: an answer without `session_id` is not the
session's, and a worker refuses a session's token `forbidden`.

```json
{"provider": "openai", "base_url": "https://llm-gw.example/v1", "api_key": "sk-...", "auth": "bearer"}
```
`config.models` (`admin`; every field optional, falling back to the file) →
`{"models": [{"id", "context", "max_output", "input", "output"}], "failures":
[{"provider", "reason"}]}` — asks the provider what it serves, for settings that need not
be saved yet. Prices are dollars per million tokens, and null where the provider quotes
none (only a LiteLLM proxy does). Nothing is written, not even the model cache. `admin`
because it sends a key to a URL of the caller's choosing.

```json
{"command_id": "c-12", "provider": "openai", "base_url": "https://llm-gw.example/v1",
 "auth": "bearer", "api_key": "sk-...", "models": {"default": "glm-5.2", "cheap": "qwen3.6-35b"}}
```
`config.set` (`admin`) → the `config.get` answer after the write. With `provider` it is
the model panel's save, into the user's file: `provider` is `anthropic` or `openai`
(anything speaking Chat Completions), or `fake`, the scripted model a packaged build is
tried with. An absent `api_key` keeps
the saved one and `""` removes it; a `base_url` of null or `""` removes it; a model role
set to null is removed. Only the lines of the keys it sets change: every other line of
the file, comments included, stays as it was, and the file before the save is kept as
`config.yaml.previous`. A file
that does not parse is never overwritten — the call fails with `invalid_params`. The
next session reads the new file; nothing restarts.

```json
{"command_id": "c-14", "key": "models.default", "value": "gateway/glm-5.2", "scope": "user"}
```
With `key` it sets one key, by its name (`models.default`, `ui.theme`; an old spelling is
written by its new name), or with `path` by its path as a list, for a name under a map
that has a dot in it (`["models", "prices", "gpt-4.1"]`). `value` is the key's value as
JSON, and null takes the key out of that file so the layer below shows through. `scope`
is `user` (the default), `project` or `local`; the last two need `workspace`. The answer
carries `"written": {"key", "scope", "path"}`. It is refused with `invalid_params` and the
reason, and nothing written, for a key the schema does not know (with the nearest one
that it does), `version` and `$schema`, which the writer keeps, a key the organisation
enforces, whatever the scope and the value ("set by your organisation", with its value and
where from), a value the loader would
refuse or warn about, a scope that may not set the key — `trusted_workspaces` outside the
user's file, a key marked trusted in the project or local file of a workspace that is not
trusted, which names `troupe config trust` — and a file that does not parse. The same
writer, so the same lines change and the same `.previous` is kept.

`config.changed` (a notification, server → client) is sent to every client attached once
a `config.set`, a `config.import` or a `setup.answer` has changed a settings file, the
client that made the change included, so a screen in one client shows what another set:

```json
{"jsonrpc": "2.0", "method": "config.changed",
 "params": {"scope": "user", "path": "/home/me/.config/troupe/config.yaml", "keys": ["models.default"]}}
```
`keys` are the keys whose values differ in that file, read before and after the write; a
save that changed nothing sends nothing. `workspace` is there for `project` and `local`.
When the daemon keeps a new copy of the organisation's document (below), `scope` is `org`,
`path` the plane's URL, and `keys` the keys its defaults or its enforced set changed; every
session running on the machine takes the change at its next turn, and says so in a
`config_note` with key `organisation`. When its poll finds the plane's version policy
changed, `scope` is `versions`, `path` the plane's URL and `keys` the policy's that changed,
as `versions.desktop.recommended` (§9, Client versions).
When its copy of the organisation's memory changes (`config.memory` below, its own poll, or
a sign-out that drops it, #55), `scope` is `memory`, `path` the copy's, and `keys` the
documents whose version changed, as `context.get` names them (`memory:organisation`,
`memory:team/<name>`); the sessions running here have been given the new documents by
then, and read them from their next turn.
A client reads `config.get` again for the values. A file edited by hand is not announced:
the daemon reads the files when a session starts and at every `config.get`, so nothing
of its own is stale, and a screen sees the edit the next time it asks.

```json
{"command_id": "c-13", "from": "opencode"}
```
`config.import` (`admin`) → the `config.get` answer after the write, plus `"imported":
{"from", "providers", "kept", "skipped", "default"}`. Copies opencode's providers into the
file's `providers:` block (type, base URL, auth style, models, and the key as opencode has it
written: an `{env:VAR}` stays a reference, a literal key is copied), once: a session never
reads opencode's config (Decision 828). A provider the file already names is kept as it is
and listed under `kept`. A provider is copied only where its key goes to the host it was set
up for: its SDK package is one Troupe has a type for, or the file names its `baseURL`. Any
other (`@ai-sdk/mistral` with no `baseURL`, say) is not copied and is listed under `skipped`
as `{"provider", "reason"}`, the reason a sentence. opencode's default model becomes
`models.default` only when the file has none and its provider is in the file. `from` is
`opencode`, the only source; with no opencode providers, or none that can be copied, the
call fails with `invalid_params` and the reasons. Nothing is written when nothing would
change.

```json
{"command_id": "c-15", "plane_url": "https://plane.example.com",
 "document": {"configured": true, "provider": "openai", "defaults": {"provider": "openai", "models": {"default": "glm-5.2"}},
              "enforced": {"approvals": "deny", "max_turns": 100}}}
```
`config.organisation` (`admin`; `workspace` optional) keeps a plane's `me.client_defaults`
answer (§ the plane's methods) as this machine's copy of the organisation's document
(Decision 869): its `defaults`, read below the user's file, and `enforced`, which holds
every layer. A client signed in to the plane fetches it and hands it over (`troupe config
pull`); the daemon also fetches it itself after every `identity.link` that brings a plane
token, once the plane has served its version. An answer from a plane with no `defaults`
is read from its old fields. It is checked as the loader reads it, and a document the
loader would refuse is refused with `invalid_params` and the reason, the copy before it
kept. → `{"version", "plane_url", "fetched_at", "defaults", "enforced", "path",
"warnings", "shadowed"}`: what was kept, where (`path`, as the platform writes it), what
reading it warns about (a key it enforces that this Troupe cannot), and `shadowed`, the
keys its defaults set that the person's own files or variables set too and win on.

```json
{"command_id": "c-16", "plane_url": "https://plane.example.com",
 "document": {"documents": [{"scope": "organisation", "name": null, "version": 3, "hash": "sha256:…", "text": "…"}],
              "signed": {"…": "…"}}}
```
`config.memory` (`admin`) keeps a plane's `me.memory` answer, `signed` and all, as this
machine's copy of the organisation's memory (#55, Decisions 922 and 929): checked against
the key this machine pinned for the plane, refused with `invalid_params` and the reason
where the pin refuses it, the copy before it kept. `troupe config pull` fetches it beside
the organisation's document; the daemon also asks `me.memory` itself after every
`identity.link` that brings a plane token and every five minutes while it holds one. A copy
whose documents changed is given to every session running here, which reads it from its
next turn (`memory_changed`), and announced (`config.changed`, scope `memory`). → `{"plane_url",
"path", "documents", "changed"}`: what was kept, where, each document's `scope`, `name`
and `version`, and `changed`, each document whose version moved, `{scope, name, from,
to}`, `null` for none; empty where nothing did. `identity.sign_out` for the plane the copy
came from, and `identity.unlink`, drop the copy, and the sessions here read none from
their next turn; the key pinned for the plane stays.

#### `me.memory`, `me.memory.put`, `me.memory.status`

The person's own memory on the plane (#55's user level, Decision 943), read and saved
through the daemon's own sign-in, both `control`: `me.memory` → `{version, text, hash,
bytes, limit, changed_by, changed_at, plane_url}`, the plane's `user` as it answers now,
the copy here kept from the same answer; `me.memory.put {command_id, text, version}` or
`{command_id, append}` → the plane's answer to its own `me.memory.put` with `plane_url`, after
which the daemon asks `me.memory` again, so the sessions running here read the saved version
from their next turn (`memory_changed`) rather than at the next poll. `conflict` where the
plane refused a stale `version`; `unavailable`, with a sentence, where the daemon holds no
plane token. `troupe memory` and the desktop app's Instructions pane are these two. An
agent's `remember` with `level: "me"` reaches the same save from inside the daemon, as an
`append` naming the `session` and the `agent` it came from. `me.memory {blame: true}` adds
`lines`, each `{text, version, by, at}` and, for an agent's entry, `session` and `agent`:
who wrote each line, derived from the versions and their audit rows (`troupe memory
--blame`, Decision 951). `me.memory` also carries `documents`, the organisation's and the
person's teams' `{scope, name, version, hash, updated_at, text}` from the same answer, the
levels their sessions read first, which the desktop app's Memory view sets theirs against
(Decision 954). The daemon asks the plane's `me.memory` with `entries: true` here, so each
document and the person's own carry `entries`, its `## Topic` sections `{topic, body, heading,
version, by, at, used, session?, agent?}` (read off the text where a plane from before them
answers none, without who wrote them), and beside them `organisation: {name}` (Decision 957)
and `roles: {platform_admin, team_admin}`, as the plane says them, both false and empty from
a plane that says nothing of them.
`me.memory.put` also takes `{command_id, entries, version}`, the document as entries
`[{topic, body}]`, and `{command_id, append, topic}`. A plane from before entries reads
`text` alone and refuses them with `invalid_params` naming `text` in `data.missing`; the
daemon passes that on, the plane's data with a sentence, as it does a level's refusal
(`admin.memory.preview`, `admin.memory.put`), and a client then sends the entries rendered as
`text`, as the plane would have written them.

#### `memory.in_effect`, `admin.memory.get`, `admin.memory.preview`, `admin.memory.put`

Sent on to the plane as the person, through the daemon's own sign-in, with the arguments the
plane takes and nothing else, all `control` (Decision 957): `memory.in_effect {team?,
profile?}` → the plane's answer with `plane_url`, what a new session of theirs in that team
reads, one list of topics. `admin.memory.get {scope, name?, version?, against?}`,
`admin.memory.preview {scope, name?, text | entries}` and `admin.memory.put {command_id,
scope, name?, text | entries, version}` → the plane's answers with `plane_url`, so a team
admin edits their team's memory, and a platform admin the organisation's, from their own
app; whoever may not is told the plane's own refusal with its code (`forbidden`,
`not_found`). A put asks `me.memory` again, as after the person's own. Signed out,
`unavailable`; all four refused to a client in Local only.

`me.memory.history {version?, against?}` (`control`, the text being the person's) → the
plane's `me.memory.history` with `plane_url`: every version `{version, hash, bytes,
changed_by, changed_at}`, newest first, `version`'s `text` (the one in force where none is
named) beside `against`'s `against_text` (the version before it where none is named), and the
line `diff`; `not_found` for a version there is not. `me.memory.rollback {command_id, to,
version}` (`control`) → as `me.memory.put` answers: version `to`'s text saved as the next
version over `version`, the one in force as the client read it (`conflict` where another was
saved since), after which the daemon asks `me.memory` again, as after a save. The desktop
app's Memory view has both in its Versions drawer. Refused, like `me.memory`, to a client in
Local only.

Every ask the daemon makes of the plane's `me.memory`, at a link, at a poll and here, carries
`sessions`: what each session running on the machine read at its last turn, by id, when that
turn began and each document's `{scope, name, version, hash}`, never its text (Decision 947),
so the plane's console sees which sessions are behind. `me.memory.status` (`observe`) → `{plane_url,
fetched_at, path, documents, problem, in_force, current, reason, sessions}` says where this
machine stands, for its person's own debugging (`troupe memory --status`): `documents` the
versions the copy here holds (`problem`, in words, where the copy is refused), `in_force` the
plane's now, asked and kept as every answer is, and `current` whether the copy had them
(`null`, with `reason`, where the plane was not asked: signed out, or unreachable), and
`sessions`, each `{session_id, turn_at, documents, current}`, `current` against the copy now.
`held` is each document as the copy holds it, `{scope, name, version, text}`: what a memory
screen shows, read-only, where the plane is not asked.

#### `artifact.publish`

An artifact published on the plane as the daemon's person (#62, Decisions 948, 950 and 953), `control`: `{command_id, title, kind, visibility?, owner?, files: [{path, bytes, content_type?}], id?, note?, session_id?}` → the plane's answer to its own `artifact.publish` with `plane_url`; `unavailable`, with a sentence, where the daemon holds no plane token, and the plane's refusal with its own code and data (`forbidden` for a team the person is not in, naming theirs). `id` publishes the next version of one the person owns or holds an edit link to, with `note`. No `visibility` is `private` for a new one and what it was for a new version; `owner`, `me` or `team`, is whose a new team publication is, the team's unless told `me`; a new version keeps its owner, and an `owner` sent with `id` is dropped by the daemon (the plane refuses one; `artifact.transfer` moves an artifact). Files whose base64 passes about 2.5 MB go by an upload handle: the daemon asks the plane's `artifact.upload.begin`, sends each file to the URL it answers, and publishes naming the handle. The terminal client's `/publish` and the desktop app's **Publish…** send it. A session's `publish_artifact` reaches the same call from inside the daemon, naming the session and its agent; the daemon is what gives its sessions that tool.

#### `artifact.list`

The person's own artifacts on the plane, through the daemon's sign-in (Decisions 950 and 953), `observe`: `{mine?, shared?, teams?, visibility?}` → the plane's `artifact.list` with `plane_url`, each row's `scope` and the person's `teams`, and `gallery_url`, the console's gallery; `unavailable`, with a sentence, signed out. The desktop app's **Publish a new version of…** and its **Artifacts** gallery list from it.

#### `artifact.get`, `artifact.open`, `artifact.read`, `artifact.share`, `artifact.unshare`, `artifact.rollback`, `artifact.pin`, `artifact.put`

The desktop app's viewer (Decision 954) and the terminal's `/artifacts` and `troupe artifacts`, each the plane's method of the same name sent with the daemon's sign-in as the person, with the scope the plane gives it: `artifact.get {id}`, `artifact.open {id, version?}` and `artifact.read {id, version?, path?}` (one text file of a version, `{id, version, path, content_type, text}`, the entry where no path is named, which the terminal reads a Markdown artifact from) `observe`; `artifact.share {command_id, id, role, expires?}`, `artifact.unshare {command_id, id, share | person}`, `artifact.rollback {command_id, id, version}` `artifact.pin {command_id, id, version}` (`null` unpins) and `artifact.put {command_id, id, base, visibility?, title?, note?}` (no files: a version carrying every file of `base`, which is how the app moves who may open it) `control`. Only the arguments named are sent on. The answer is the plane's with `plane_url`; a refusal keeps the plane's own code and data (`not_found` for one the person may not see, `forbidden` for an owner's control asked by somebody else, `conflict`), and `unavailable`, with a sentence, signed out or where the plane is from before the method. `artifact.open`'s `url` is the artifacts host's one-time `/enter?ticket=` address, which the app opens in a window of the shell's own, never fetched into the app. All eight are refused to a client in Local only and for a session under it, as every `artifact.*` is.

#### `setup.get`, `setup.answer`

A first run's questions (Decision 705), asked one step at a time so that the terminal
client and the desktop app ask the same things in the same order, and a person who
answered in one is not asked again in the other. **The daemon's only**, like `config.*`:
a worker answers `method_not_found`. The daemon holds one flow in progress; every
answer moves it one step on, and the key a person gives at one step is the key written
at a later one, without ever travelling back to a client.

```json
{}
```
`setup.get` (`observe`) → `{"needed", "completed", "step", "steps": [{"name",
"done"}], "answers", "detected", "kinds", "key_storage", "offered", "suggested", "check",
"suggested_prompt", "daemon", "session"}`. `needed` says whether a client should offer the
questions: nothing recorded, no `config.yaml`, and no model that can be asked.
`completed` is `null` or `{"completed_at", "choice", "subject"}`, recorded once for every
client in the daemon's state directory; `completed_at` is an instant in microseconds, later
than that of the record it replaced, so a client tells a re-run that finished from the record
it began with. `step` is the step to answer next — `where`,
`provider`, `key`, `models`, `workspace`, `daemon`, `finish`, and `done` once `finish` is
answered — and `steps` the ones this path
takes, since a plane finishes at once, reused settings skip the key and the models, and a
provider that takes no key skips the key.
`kinds` is every way the `provider` step may be answered, in the order a screen offers
them (issue #658): each provider type a person may pick, as `config.get`'s
`provider_types` has it, then `gateway` and `litellm`, the two ways to an
OpenAI-compatible server at its address. Each is `{"id", "provider", "label", "summary",
"url", "default_url", "url_example", "key", "key_var"}`: `id` is the `kind` to answer with
and `provider` what is written; an address is asked where `url` is `required` (a gateway,
Azure's resource) or `server` (Ollama's, `default_url` when none is given), and a key
unless `key` is `none`, with `optional` letting a gateway go without. A daemon before #658
sends no `kinds`, and takes `anthropic`, `openai` and the two gateways.
`daemon` says whether the daemon starts when this user logs in (Decision 762):
`{"at_login", "kind": "startup_folder" | "launch_agent" | "systemd" | "autostart",
"path", "command"}`, the entry's file and the `troupe-daemon` it starts, `command` being
`null` when there is none to start.
`detected` is what is already here: `env` (which of the vendors' variables, the
`key_var` of each kind that has one, are set, names only), `opencode` (`path`, `providers`, `default`),
`config` (the user's file: `exists`, `path`, `provider`, `base_url`, `api_key_set`,
`api_key_source`, `models` and `usable`) and `plane` (`url`,
`linked`). `key_storage` says where a key goes: `{"kind": "file", "path", "keychain":
false}`, there being no keychain in the daemon. `answers` holds every answered step as
it was accepted; the key step is `{"source": "typed" | "env" | "none", "var"}`, never
the key.

```json
{"command_id": "c-20", "step": "key", "answer": {"api_key": "sk-..."}}
```
`setup.answer` (`admin`) → the `setup.get` answer after the move. `step` is the current
step, or one already answered, which goes back to it and forgets what came after; an
`answer` of `{"back": true}` goes back to a step and takes no answer, for a screen
whose person wants the question again. Each step's `answer`:

| step | answer | what it does |
| --- | --- | --- |
| `where` | `{"choice": "local"}` or `{"choice": "plane", "plane_url"?}` | a plane records the choice and goes to `finish`; signing in is the client's |
| `provider` | `{"provider": <a provider type, or "fake">, "kind"?: <a kind's id>, "base_url"?, "auth"?}`, or `{"reuse": "opencode" \| "config"}` | a gateway and a LiteLLM proxy are `openai` with their URL, which they and `azure_openai` are refused without; a kind whose `key` is `none` (Ollama) is asked for its models at once, as `key` would ask, and goes to `models`; `reuse` copies opencode's providers in as `config.import` does (the answer recorded lists them under `providers`, and those not copied under `skipped`, as `config.import` does), or keeps a `config.yaml` that works, and goes to `workspace` |
| `key` | `{"api_key"}`, `{"env": "VAR"}` (kept as `{env:VAR}`) or `{}` for a gateway that wants none | checked with a real request, the provider's model listing: `check` is `{"state": "ok" \| "refused" \| "unknown", "reason"}`. Refused stays on `key`; `ok` fills `offered` (`{"id", "context", "max_output", "input", "output"}`, prices per million tokens) and `suggested` (`{"default", "cheap"}`, a safe answer); `unknown` goes on with nothing listed, as it does for Azure, which lists its deployments to no key. A vendor at its own endpoint, and `azure_openai`, are refused `{}` |
| `models` | `{"default", "cheap"?}` | writes the provider, the key and the models into the user's `config.yaml` |
| `workspace` | `{"workspace", "approvals": "ask" \| "auto"}` | the first project directory, which must exist. `ask` is the default; `auto` writes `auto_approve: true`, and `ask` writes `false` only over a file that runs everything |
| `daemon` | `{"at_login": true \| false}` | `true` writes the platform's login entry, which starts `troupe-daemon run` at the next login and keeps it up; `false` removes it. The answer is the state, so answering again turns it the other way; nothing is started or stopped now |
| `finish` | `{"start"?: true, "prompt"?}` | records the run as done; for a local setup starts a session in the workspace with `prompt`, or `suggested_prompt`, and answers it as `session`: `{"workspace", "prompt"}` with `session.create`'s answer, or with `"error"` |

A bad answer is `invalid_params` with `data.reason` in one sentence, and the flow stays
where it was. After `finish` the next `setup.get` is a fresh flow with `needed` false,
which is what a client's "Setup" entry re-runs.

#### `mcp.list`, `mcp.add`, `mcp.remove`, `mcp.check`, `skills.list`, `skills.add`, `skills.remove`

The person's own MCP servers and skills, in two layers the daemon reads for every local
session: the user's (`mcp.json` and `skills/` beside `config.yaml`) and the workspace's
(`.troupe/mcp.json` and `.troupe/skills/`), over `config.yaml`'s `mcp:`. **The daemon's
only**, like `config.*`: a worker answers `method_not_found`, since a pod's servers are
its bundle's. `scope` is `user` (the default) or `workspace`, the latter needing a
`workspace`. Both clients manage the one set through these. The paths in the answers
(`path`, `source`, `dir`) are written as a person on the daemon's platform writes them,
for a panel to print.

```json
{"workspace": "/home/me/project", "session_id": "s-9f"}
```
`mcp.list` (`observe`; both optional) → `{"servers": [{"name", "layer", "source",
"transport", "command", "args", "url", "cd", "env", "headers", "permission", "disabled",
"refused", "trust", "notes", "oauth", "auth", "state", "tools", "error"}], "warnings": [...]}`
(`auth` is `{"state", "account", "error", "step_up"}`, below) —
every server the layers give the workspace, merged by name, the workspace's file over
the user's over `config.yaml`. `layer` is `config`, `user` or `workspace` and `source`
the file; `env` is the names of its variables and `headers` the names of the headers it
is sent (Decision 820), never their values; `refused` says why one will not start (an
unset `{env:VAR}`, an `oauth` whose `redirect_uri` is not loopback, a header Troupe sends itself); `trust` is
`trusted` or `pending` for a workspace-level server and null otherwise. `notes` is
`[{"key", "reason"}]`, as `agents.list`'s: a workspace-level server set to `permission:
auto` in a workspace not on `trusted_workspaces` has one `permission` note, since its tools
ask until the workspace is trusted, whatever its start's answer (Decision 830);
`permission` stays what the entry says. The workspace's layer reads nothing from outside
the repository until the workspace is trusted: an `include` from elsewhere (the person's
own `~/.claude.json`, say), or a `.troupe/mcp.json` that is a link out, gives no servers,
and `warnings` names it with the command that trusts the workspace (Decision 830). For a server
that wants the person signed in, `oauth` is `{"client_id"?, "scopes"?, "issuer"?}` as its
entry says (no `client_id` when Troupe introduces itself to the provider), and `auth` is how their sign-in stands — `{"state", "account", "error"}`,
`state` one of `signed_out`, `signing_in` (a browser is out), `signed_in` and `expired`
(it ran out or was refused: sign in again), `account` whose it is when the provider said,
`error` why the last attempt failed — and never a token; both are null for any other
server. With `session_id`, each server also carries the `state`, `tools` and `error`
that `mcp.status` reports for the session, and a server the session runs that no file
names any more is listed too.

```json
{"command_id": "c-14", "scope": "user", "from": "/home/me/.claude/.mcp.json", "link": false}
```
`mcp.add` (`admin`) → `{"path", "from", "added": ["fs"], "skipped": [{"name",
"reason"}], "warnings", "linked"}`. Imports another tool's file — Claude Code's and
Claude Desktop's `mcpServers`, Cursor's, VS Code's `servers`, opencode's `mcp`, Codex's`
config.toml` `[mcp_servers.<name>]` (the person's own Codex file into the `user` scope
only) — copying
its servers into the layer's `mcp.json`, or with `link: true` reading it in place from
then on. `${VAR}` and `${env:VAR}` become `{env:VAR}`; a server with a `${input:…}` or
an opencode `{file:…}` is skipped and said so; `headers` and `env` are kept, and a copy
writes each value written out as the `{env:<SERVER>_<NAME>}` that reads it, never the
value, with a warning naming the variable to set (Decisions 820 and 825); an `oauth` is kept,
`clientId`, `redirectUri` and `callbackPort` read as `client_id` and `redirect_uri`.
Importing again updates.

```json
{"command_id": "c-15", "scope": "workspace", "workspace": "/home/me/project",
 "name": "fs", "server": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "."]}}
```
The same call with `name` and `server` writes one entry, merged onto what the layer has
under that name — `{"disabled": true}` alone turns one off without restating its
command — and answers `{"name", "path", "entry", "warnings"}`, the entry's `env` and
`headers` as names. A name has lower-case letters, digits, `-` and `_`, and no dot.

```json
{"command_id": "c-16", "scope": "user", "name": "fs"}
```
`mcp.remove` (`admin`) → `{"path", "removed": ["fs"]}`. `include` in place of `name`
unlinks a linked file, and `removed` names every server it gave. A server that comes
only from a linked file is refused with `invalid_params` naming the file.

```json
{"session_id": "s-9f", "name": "fs"}
```
`mcp.check` (`admin`) → `{"server": {"name", "layer", "source", "state", "tools",
"error"}}`. With a `session_id`, the session reads its files again for that server and
starts what they say now — which is how one that died is brought back, one just written
is started, and one now `disabled` is stopped — and answers once it is ready or has
failed, or after twenty seconds with what it is then, which may still be `connecting`; a
workspace-level server whose command changed is asked about again first, and answers
`pending`. With `workspace` and `name`, or with `name` and a `server` that was
never written, the server is run once on its own, asked for its tools, and stopped; a
stdio server run so that does not answer `initialize` within twenty seconds is `error`.

```json
{"workspace": "/home/me/project"}
```
`skills.list` (`observe`; `workspace` optional) → `{"skills": [{"name", "description",
"layer", "source", "dir", "linked"}], "skipped": [{"name", "layer", "source", "dir",
"linked", "status", "reason"}]}`. `layer` is, lowest first, `user_agents`
(`~/.agents/skills`), `agents` (an `.agents/skills` from the repository root down to the
workspace, the nearest highest), `user` or `workspace`, and a name is the highest
layer's. `skipped` is every skill the layers hold and do not offer, lowest first:
`status` `skipped` with `reason` naming the directory used (`skipped: <dir> is used`), or
`outside` (`not read: outside the repository`), a link out never read; an
`.agents/skills` linked out whole is one entry with a null `name`. The workspace's
`.troupe/skills` is held to the workspace (`not read: outside the workspace`), and what its
`skills.json` includes from outside the repository is `outside` until the workspace is
trusted, the `reason` naming the command that trusts it, one entry with a null `name`
(Decision 829); `unreadable` is a `SKILL.md` that can't be read, the `reason` saying why.

```json
{"command_id": "c-17", "scope": "user", "from": "/home/me/.claude/skills", "link": true}
```
`skills.add` (`admin`) → `{"path", "from", "added", "skipped", "linked"}`. `from` is a
directory of skills, such as `~/.claude/skills`, or one skill's directory (one holding a
`SKILL.md`): copied into the layer's `skills/`, or with `link` read in place through the
layer's `skills.json`. A directory whose name is not one a skill may have is skipped.

```json
{"command_id": "c-18", "scope": "user", "name": "review"}
```
`skills.remove` (`admin`) → `{"path", "removed"}`; `include` unlinks a linked directory,
as for servers.

**Trust.** A workspace-level server is a command a cloned repository would run, so a
local session starts the workspace's servers only once somebody attached has answered
the question the session asks — a `question_asked` with `call_id` `mcp-trust-<hash>` and
the options `deny`, `once` and `allow`, answered through `question.answer` like an
`ask_user`, so any client can. `allow` is remembered per checkout in the daemon's state
directory, never in the repository, beside a fingerprint of what would run, so a changed
command asks again; `once` runs them for the session; `deny` leaves them `stopped` until
the next session, or until an `mcp.check` with the `session_id` asks again. A workspace on `trusted_workspaces` is not asked. Under
`managed_mcp_servers_only` no local server starts, and `mcp.status` says so for each.

#### `mcp.sign_in`, `mcp.sign_out`

A person's sign-in to one of their own servers that wants *them* rather than a machine
(Decision 741): an entry with a `url` and an `oauth`. **The daemon's only**, like the
rest of this section. The daemon runs the sign-in, because it is the process that calls
the server: it discovers the authorization server from the server's `401` and
protected-resource metadata, signs in as the client the entry names, or, with none,
presents Troupe's client ID metadata document where the authorization server's metadata
says `client_id_metadata_document_supported`, or registers a public client
(`token_endpoint_auth_method: none`, the loopback redirect) at its
`registration_endpoint` (RFC 7591) and keeps it beside the tokens for later sign-ins
(Decision 924); an authorization server with neither answers `invalid_params` asking for
a `client_id`. It makes
the PKCE pair and the `state`, and listens on a loopback port of its own machine for the
browser to come back; the client only opens the URL. The tokens stay in the daemon's
state directory and are never in an answer, an event or a log.

```json
{"command_id": "c-19", "name": "wiki", "workspace": "/home/me/project"}
```
`mcp.sign_in` (`admin`; `workspace` or `session_id` optional, as for `mcp.list`) →
`{"server", "url", "redirect_uri", "expires_at", "scopes"}`: open `url` in a browser on
the daemon's machine; the answer comes back to `redirect_uri`, and the daemon stops
waiting at `expires_at`, five minutes on. `scopes` is what the person is asked to grant.
`mcp.list`'s `auth` says how it stands, and every local session that waits for the
server asks it for its tools once the sign-in lands. A second `mcp.sign_in` for the same
server replaces the first. A server with no `oauth`, one whose `oauth` is refused, and a
workspace-level server the workspace's question has not approved are `invalid_params`; a
name the layers do not give is `not_found`.

**A wider scope** (Decision 872). A server that answers a call `403` with
`WWW-Authenticate: Bearer error="insufficient_scope", scope="…"` wants a scope the
sign-in was not granted. The call's answer is the `sign_in_required` note with `scope`,
the scope the server named, and `mcp.list`'s `auth` carries it as `step_up` until a
sign-in lands. Nothing signs in by itself: the next `mcp.sign_in` the person asks for asks
for what was granted and what the server named, at the authorization server the
server's own metadata names (a `resource_metadata` in the `403` is not followed), and the
tokens held are used until it lands.

```json
{"command_id": "c-22", "all": true}
```
`mcp.sign_out` (`admin`, the same parameters, or `all`) → `{"server", "auth",
"revocation"}`: the sign-in is forgotten on this machine, and the server's sessions show
`sign_in` again. Then the provider is asked to revoke the refresh token (RFC 7009) when
its authorization server's metadata names a `revocation_endpoint`, held to the rules the
token endpoint is (`https`, or `http` on loopback; not link-local, a cloud metadata
address or the unspecified one), with a five-second wait. `revocation` is `{"state",
"reason"}`: `revoked`; `failed`, with `reason`, when it refused, did not answer in time or
could not be reached — the sign-in is forgotten all the same, and the provider still
takes it until it runs out; `unsupported` when the metadata names no revocation endpoint;
`none` when nothing was held. With `all: true` and no `name` it is every server signed in
to on this machine, by whatever name and in whatever workspace, as `troupe logout` asks →
`{"servers": [{"server", "revocation"}]}`. The provider's own session in the browser is the
provider's.

#### `mcp.tools`, `mcp.call`

One of the person's own servers outside any session (Decision 748), for a client that
offers its tools to a session on a pod as tools it hosts (section 8). A pod's session
reads none of the person's files and holds none of their sign-ins, so the client lists
the server's tools here, registers them with the pod, and serves each `tool.invoke` by
calling here: the call is made on the person's machine with their sign-in, and the pod
sees names, schemas, arguments and what came back. **The daemon's only**, like the rest
of this section, and `admin`, since each goes out as the person. Only a server with a
`url` is called: one that runs a command, one that is refused or `disabled`, and a
workspace's server the workspace's question has not approved are `invalid_params`; a name
the layers do not give is `not_found` with `kind: "mcp_server"`.

```json
{"name": "wiki"}
```
`mcp.tools` (`workspace` or `session_id` optional, as for `mcp.list`) → `{"server",
"state", "error", "tools": [{"name", "description", "schema", "files"}]}`: the server asked for
its tools as a local session asks, with the person's sign-in, `state` and `error` as
`mcp.check` reports them, so one that waits for a sign-in is `sign_in` with no tools.
`files: true` on a tool of a server whose entry is marked `stores: files`, which the client
says again when it registers the tool (section 8).

```json
{"command_id": "c-20", "name": "wiki", "tool": "search", "arguments": {"q": "the plan"}}
```
`mcp.call` → `{"server", "tool", "content"}`: the call made with the person's sign-in,
refreshed and made once more on a `401`, and `content` what a local session's model
reads from the same tool — the server's text, anything else named — down to the
`sign_in_required` note once the sign-in has run out, which `mcp.list`'s `auth` then
shows as `expired`, or when the tool wants a scope the sign-in did not grant, with
`scope` (above). A call the server could not take is `unavailable`, with
`data.reason`. A client serving a pod's `tool.invoke` answers it with `{"content"}` as it
came, and names the call in `command_id` by the session and the pod's `call_id`, so a
call the pod sends again after a drop (section 8) is answered from the first rather than
made twice.

#### `workspace.recent` → `{"workspaces": [{"path", "last_used_at", "sessions"}]}`

Most recently used first, at most `limit` of them (20 where it is absent).

#### `workspace.search`
```json
{"query": "trou", "limit": 20}
```
→ `{"workspaces": [{"path", "score"}]}`

#### `worktree.list` → `{"worktrees": [{"path", "branch", "session_id", "checked", "dirty", "ahead", "behind", "added", "removed"}]}`
```json
{"workspace": "/home/me/project", "status": false}
```

Every worktree of the workspace's repository, the checkout first, with the live session
working in it (`session_id`, `null` for none: one in its directory, or in a folder of it
git does not ignore) and whether it has uncommitted or untracked files. How it stands
against the checkout (Decision 840, additive): `ahead` and `behind`
are the commits its branch has that the checkout's branch has not, and the other way
round, and `added` and `removed` the lines it would bring, counted since its branch left
the checkout's, its uncommitted changes and untracked files included, as `worktree.merge`
would commit them. For the checkout itself `ahead` and `behind` are against its upstream
and `added` and `removed` what it has not committed. Each is `null` where git cannot say
(no upstream, a detached checkout). A binary file adds no lines, and an untracked file
over 1 MB or past the first 200 is not counted. Without `workspace`, the worktrees of every
live session's workspace.

The workspace follows git (Decision 881): a folder its repository tracks, or would add,
lists the repository's worktrees, and a folder the repository ignores is a workspace of its
own and lists none, as a directory in no repository does.

The answer comes in bounded time however many worktrees there are. `status: false` asks
for the trees alone: each row is `path`, `branch` and `session_id`, and no tree is looked
at, which is how a client asks whether a workspace is in a repository. Otherwise the daemon
reads the trees' status for about two seconds, several at once, the checkout first, then
the trees a session works in, then the rest in git's order. `checked` says whether it read
a tree's; a tree it did not reach has `checked: false` and `dirty` and every count `null`,
which a client shows as not looked at rather than as clean. A daemon from before this sends
no `checked`, and has read every tree.

#### `worktree.remove`
```json
{"command_id": "c-8", "path": "/home/me/project/../project-troupe-abc", "force": false}
```
Refuses a dirty tree with `conflict` unless `force` is true. git runs from the checkout
the tree belongs to, not inside the tree.

#### `worktree.merge`
```json
{"command_id": "c-9", "workspace": "/home/me/project",
 "path": "/home/me/project-troupe-abc", "message": "troupe: fix the test"}
```
→ `{"merged": true, "branch": "troupe/abc", "committed": true, "output": "...", "removed": true}`

Lands a branch's work on the checkout it came from: anything uncommitted in the
worktree is committed first (as `message`, or a default naming the branch), the branch
is merged into `workspace` with a merge commit (`--no-ff`), and the worktree and branch
are removed. A merge git cannot complete is aborted and answered with `conflict`
(`reason: "merge conflicts"`, `output`: git's words); the worktree is untouched, so the
person can resolve it by hand. One git will not start because uncommitted changes in
the checkout are in its way is `conflict` with `reason: "local changes in the checkout"`
(`output` names the files); nothing is changed. A merge that landed and whose tree git
then could not remove is still answered as a merge, with `"removed": false` and
`removal_error` (git's words); the tree and its branch are left. Refused with
`conflict` while the session in that worktree is mid-turn (`reason` names the session).

#### `worktree.discard`
```json
{"command_id": "c-10", "workspace": "/home/me/project", "path": "/home/me/project-troupe-abc"}
```
→ `{"discarded": true, "branch": "troupe/abc"}`

Removes the worktree and deletes its branch, uncommitted work included. Same refusal
while its session is working.

### Fleet

#### `fleet.get` → `{"sessions": [...]}`, the rows `session.list` gives with no filter. A `fleet` subscription replays nothing; it carries what happens from then on.
#### `watch.set` → `{"command_id", "workspace", "enabled": true, "session_id"}`. Watch mode is
**exclusive per workspace**: enabling it with a `session_id` naming another session than the
one that watches there returns `conflict`. `session_id`, optional, names the session that
watches; without it, the session already watching stays, or else the workspace's session
that is no branch, and a workspace with no session running is `invalid_params`. Enabling it where the same session watches is
answered as it stands; disabling turns off whichever session watches there. A pod's session
never watches (`forbidden`). → `{"enabled", "backend"}`.

#### `watch.get` → `{"workspace"}`. Whether the workspace is watched (Decision 844):
`{"enabled": true, "backend": "native", "session_id": "s-3a"}`, or `enabled: false`,
`backend: "off"` and a null `session_id`. `observe`; the daemon's only. What a status line
shows and what the next toggle turns; `watch_changed` says when it changes.

#### `daemon.stop` → `{}`. Stop the daemon between turns, so `troupe update` can replace its
release (Decision 865). `admin`; the daemon's only, and a worker answers
`method_not_found`. With no session's turn at work the answer is `{"stopping": true}` and the
daemon stops a moment after it, as its idle stop does: sessions seal and close, and every
connection ends. A session that is idle, done, or waiting on a person is not at work. While
one is, nothing stops and the answer says which, for the client to ask again:
`{"stopping": false, "reason": "at_work", "at_work": [{"id": "s-3a", "workspace":
"/home/me/project"}]}`. A daemon a TUI runs inside itself stops when that TUI exits, and
answers `{"stopping": false, "reason": "embedded"}`.

### Session states, dormancy, and activation

| `state` | actor tree | what a client can do |
| --- | --- | --- |
| `pending` | not started | read it; wait. The session exists and has no worker yet |
| `active` | running | everything |
| `dormant` | stopped | read it; an activating command brings the tree back |
| `read_only` | stopped | read it; activating commands return `forbidden`. A session is parked here when its team lost the grant — running, dormant or still `pending` — or its profile is gone, and when a pod could not put its tree back because the directory it was recorded in is gone (Decision 661). A running one is put to sleep on its pod, as an archive does (§7) |
| `erasure_pending` | none | a session somebody erased whose key the plane has not yet destroyed: listed as such and answered by `session.get`; `session.erase` again tries again, and so does the plane every five minutes; opening, minting, redeeming a link to, forking, spawning from, sharing, sealing, keying and signing for it answer `not_found` with `reason: "erased"` (Decisions 756 and 811) |
| `erased` | gone | `not_found` |

`pending` is a remote state and a short one. A `session.create` on a profile that is full
but may still grow answers with a session id, `"state": "pending"` and **no endpoint** —
there is nothing to connect to yet, and inventing an address would be worse than saying
so. The plane has already asked for another worker; `retry_after_ms` says when to ask
again. A refusal happens only where a person set a ceiling, and then it quotes the number
they set.

A session goes `dormant` on its own idle timeout, or on `session.archive`: the daemon's for
a local session, the plane's for a pod session (§7). Waiting on a person counts as idle. A
local daemon never sleeps a session while a client is subscribed to it (§5) — the
person reading it is not handed a state change they did not ask for — and its timeout is
minutes once nobody is
([troupe-daemon](apps/troupe_daemon/README.md#how-long-it-stays-up)). Its log stays, and so
does everything a client can learn from it: `session.list`, `session.get`, `blob.get` and
`subscribe` all work on a dormant session and start nothing. That is deliberate — a session
that woke up because somebody looked at it would never stay dormant. A client reading one
need not know it slept: an activating command brings it back on its own, the stream carries
on from the same `seq`, and what the client sees of it is the log's own lifecycle events
(`session_dormant`, then `agent_restarted`, `session_resumed`, `session_activated` on the
way back), which it may show or ignore.

The **activating** commands are `input.send`, `turn.cancel`, `profile.switch`,
`session.goal.set`, `session.goal.clear`, `session.loop.start`, `approval.respond`,
`question.answer`, `todo.edit`, `tools.register`, `shell.run` and `commands.run`. Each brings a dormant session's tree
back by folding its log before taking effect, and the session logs `session_activated`.

On a pod only the plane brings a session back: it places the session, bumps its epoch and
tells the pod. An activating command for a session whose tree the pod is not running —
whatever the pod has of it on disk — is answered `not_found` with `data.kind` of
`session` and does not run, and a client opens the session through the plane's
`session.open` in `activate` mode ("A session that moves", below). That open checks again
that the session's team exists and holds a grant on its profile, and answers `forbidden`
where it does not.

#### Activation is about the session, not about the pod

Worth stating exactly, because the looser reading forbids something harmless.
"Subscribing to a dormant session never activates it" means **no actor tree and no model
call** — it does not mean no process anywhere and no worker.

A `Session.Reader` is neither an actor tree nor a model call: it is a short-lived process
that folds a log and serves it. So reading a dormant session may start a *worker* — on a
profile that has scaled to zero, it must, or the history would be unreadable — and it
consumes no capacity, reserves no placement and writes no `session_activated`. The
session is exactly as dormant afterwards as it was before.

The two questions are separate everywhere it matters: a session is active or dormant
whatever its profile is running, and a profile has workers or none whatever its sessions
are doing.

#### A session that moves

A pod session is not tied to its pod. A drain, a pod replaced for a new image, a pod that
was lost and another client's activation all leave it dormant where it was — with a
`session_dormant` in its log wherever there was time to write one — and its next
activation places it wherever there is room. Nothing is sent to say so, and there is no
error code for it. What a client connected to the old pod sees is one of three things:
the connection closes and does not come back, `initialize` is refused, or the pod answers
**`not_found` with `data.kind` of `session`**, which is what a pod says about a session
it does not hold. It says so before it runs anything, so a command answered that way did
not happen.

The plane knows where the session is, and a client asks it rather than the old pod: after
a connection that failed, and after that `not_found`, it calls the plane's `session.open`
with the session id again and connects to the `endpoint` with the `token` it is given,
subscribing from its cursor as after any reconnect. It asks in `read` mode, which wakes
nothing. The answer's `state` is the session's as the plane has it: `active` means the
endpoint runs the session, and anything else that the pod only serves its history, so an
activating command goes through `session.open` in `activate` mode first. An activating
command the old pod answered `not_found` may then be sent again, once, with the same
`command_id`. A client gives up after a bounded number of tries and says so, and it stops
at once when the plane answers `not_found` or `forbidden`.

### After a restart

A daemon restart is not visible as an event, because nothing was running to write one.
What a client sees is this:

- every session it could see before is still listed, `dormant`;
- a session that was mid-turn reports `"status": "interrupted"`, which is read from
  the log — a tool call that started and never completed, or a request the model never
  answered — and is therefore true before anything has been restarted; one that was
  waiting on a person — an approval, a question, the budget's question — reports
  `"status": "waiting"`, read the same way;
- **no model call is made.** A session comes back interrupted and stays that way until
  an activating command arrives. Resuming instead would mean a crash loop spends money
  and re-runs shell commands nobody is watching. A daemon may be configured to resume,
  and then it re-runs unfinished tool calls and takes the turn it owed;
- a loop that was running is stopped, `interrupted`, for the same reason: it is
  reported so while the session is dormant and written so when it is activated.

When an interrupted session is activated, the tool calls that never finished are
closed off as errors naming the interruption, so the conversation the model sees has a
result for every call it made. A call that was waiting on a person is not closed off: it
is asked again, under the same id, and an answer that arrived in the meantime — the
`approval.respond` or `question.answer` that woke the session — is handed to it.

---

## 7. Scopes

| scope | grants |
| --- | --- |
| `observe` | `initialize`, `client.mode`, `subscribe`, `unsubscribe`, `session.list`, `session.get`, `session.invites`, `session.read_sealed`, `session.goal.get`, `session.loop.get`, `blob.get`, `fleet.get`, `fs.list`, `fs.read`, `scratch.list`, `agents.list`, `agents.get`, `agents.validate`, `commands.list`, `workflows.list`, `context.get`, `mcp.status`, `mcp.list`, `skills.list`, `workspace.recent`, `workspace.search`, `worktree.list`, `watch.get`, `presence.set`, `identity.get`, `config.get`, `setup.get`, `me.memory.status`, `artifact.list`, `artifact.get`, `artifact.open`, `artifact.read` |
| `control` | everything in `observe`, plus `input.send`, `commands.run`, `turn.cancel`, `profile.switch`, `session.goal.set`, `session.goal.clear`, `session.loop.start`, `session.loop.stop`, `approval.respond`, `question.answer`, `todo.edit`, `fs.upload`, `tools.register`, `tools.unregister`, `memory.get`, `memory.decline`, `onboard.decline`, `me.memory`, `me.memory.put`, `me.memory.history`, `me.memory.rollback`, `memory.in_effect`, `admin.memory.get`, `admin.memory.preview`, `admin.memory.put`, `artifact.publish`, `artifact.share`, `artifact.unshare`, `artifact.rollback`, `artifact.pin`; and `shell.run` and `shell.cancel`, which also need the session's owner or `admin` (Decision 813) |
| `admin` | everything in `control`, plus `session.create`, `session.archive`, `session.pin`, `session.unpin`, `session.erase`, `session.claim`, `session.invite`, `session.uninvite`, `session.fork`, `worktree.remove`, `worktree.merge`, `worktree.discard`, `memory.forget`, `onboard.plan`, `onboard.apply`, `watch.set`, `identity.link`, `identity.unlink`, `identity.sign_out`, `identity.accept_plane_key`, `config.models`, `config.set`, `config.import`, `config.organisation`, `config.memory`, `setup.answer`, `mcp.add`, `mcp.remove`, `mcp.check`, `mcp.sign_in`, `mcp.sign_out`, `mcp.tools`, `mcp.call`, `skills.add`, `skills.remove`, `agents.put`, `agents.delete`, `daemon.stop`, `remote.offer`, `remote.withdraw` |

Locally, the socket's permissions authenticate the user and the connection gets all
three, and so does the loopback TCP token; a daemon mints no narrower token.

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
| `session_id` | the session this token is for; the plane always sets it (a token without one is below) |
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
A role the plane narrows is held the same way: the next command runs with the scopes of
the role the pod was told, so an owner made a collaborator is refused `shell.run` with
`forbidden` and `data.required_scope` of `admin` without waiting for the token to expire.
The ACL narrows and never widens; a wider role arrives with the next token
(`auth.refresh`).

**A token is for its session and no other.** A pod holds several people's sessions, so a
request that names another — as `session_id`, a branch's `parent`, or the id in a
`session:` or `presence:` topic — is refused with `forbidden` and `data.field` saying
which, and so is a subscription to `fleet`. `session.list` and `fleet.get` answer with the
token's own session and none of the others. A token with no `session_id` is held to the
ACL of each session a request names.

**It calls the methods about its session, and no others.** Those are `subscribe` and
`unsubscribe` on its own topics, the two listings above, and every command whose params
require `session_id` (§6) but the five below: `session.get`, `input.send`, `turn.cancel`,
`profile.switch`, `session.goal.*`, `session.loop.*`, `approval.respond`,
`question.answer`, `todo.edit`, `fs.list`, `fs.read`, `fs.upload`, `scratch.list`, `blob.get`,
`mcp.status`, `context.get`, `commands.list`, `commands.run`, `presence.set`, `tools.register`, `tools.unregister`, `shell.run` and `shell.cancel`; and `agents.list`,
`agents.get` and `agents.validate` when they name the session and no `workspace`, which
are its own agents, its bundle's (#594). Everything else a
worker serves is about the pod or a path on it — `session.create`, `agents.list` and the
other two named by a path,
`workflows.list`, `memory.get`, `memory.forget`, `memory.decline`, `workspace.recent`, `workspace.search`,
`worktree.*`, `watch.*`, `identity.*`, `config.*`, `skills.*` and the `mcp.*` methods
but `mcp.status` — and a token for one session is
refused it with `forbidden` and `data.method` naming it. A method a worker does not have
is `method_not_found`, whatever the token, and `initialize` and `auth.refresh` belong to
the connection. The plane mints every token for a pod with a `session_id`; one without is
signed only by tooling that runs its own pod (the end-to-end tests, the benchmark), and
keeps the whole table.

**Archiving, pinning, erasing and forking a pod session are the plane's.** The plane holds
the session's row, its key, its placement and its retention, so a worker refuses
`session.archive`, `session.pin`, `session.unpin`, `session.erase` and `session.fork` to a
token for one session with `forbidden`, `data.method` naming it and `data.reason` of
`done through the plane`. A client archives, pins, unpins and erases a pod session with
the plane's methods of the same names, each `{session_id}` and each for the session's
owner, and forks one with the plane's `session.fork` (Decision 812). The plane's archive pushes `session.dormant` to the pod holding the session, which
seals it, uploads its workspace, deletes its own copy and reports it dormant, giving back
its slot and its budget slice; the answer is the session's row, `dormant`, and the next
activating command brings it back on whichever pod has room. A session that is not
running is answered as it stands, one still `pending` is refused with `conflict`, and one
whose pod does not answer stays as it was, with `unavailable`. The plane's erasure destroys
the session's key itself, as it does a private session's (below), and reaches the pod over
the same control channel, which stops the session there and deletes the pod's copy and
the objects (Decision 811). The answer has the private session's shape: `erased: true`
with `state: "erased"` once the key is gone, and `erased: false` with `state:
"erasure_pending"` where the key manager refused or could not be reached, in which case
asking again tries again, and so does the plane every five minutes.

**Erasing a private session** (Decision 756) has no pod to reach. The plane destroys the
session's key itself, every version, and answers `{session_id, erased, state, head_hash}`:
`erased: true` with `state: "erased"` once the key is gone, and `erased: false` with
`state: "erasure_pending"` where the key manager refused or could not be reached, in which
case asking again tries again, as the plane does every five minutes (Decision 811). The
objects and the copy on the owner's machine go when
the owner's daemon next connects: it asks `session.erasures`, drops its sealer and its copy
of each session named, and answers `session.erased`, on which the plane deletes every
version under the session's prefix, and is named the session again until none is left
(Decision 804). A daemon erasing one of its own (its `session.erase`, Decision 789) asks
the plane's first and does the same at once for the session it named.

### Relayed connections

A laptop's session offered for steering from another device
([Steering from another device](#steering-from-another-device)) is reached through the
plane: a client asks the plane's `/rpc` for `remote.open {session_id}` and gets
`{"session_id", "kind": "remote", "endpoint", "role", "your_role", "token", "expires_at"}`,
then opens `endpoint` (`wss://<plane>/v1/relay/session`, or that path where the plane names
no address of its own) and speaks this protocol on it exactly as to a pod: `initialize`
with the token, `subscribe`, the commands, `auth.expiring` and `auth.refresh`, which asks
`remote.open` again for the token. `remote.list` on the plane lists the sessions offered
to the caller ([Harness methods](#triggers-and-principals-on-the-harness-side)).

The token is for that session alone, at the caller's role, with the audience `troupe-relay`:
it opens no pod and no `/rpc`. The plane answers `auth.refresh` itself, takes `auth` out of
`initialize` before relaying it, and relays nothing else of a token to the laptop.

**What may be asked.** A relayed connection calls the session's own reading — `subscribe`
and `unsubscribe` on its topics, `session.get`, `session.list` (which lists that session
alone), `blob.get`, `agents.list` naming the session, `commands.list`, `presence.set`,
`session.goal.get`, `session.loop.get` — and, at `control`, its steering: `input.send`,
`commands.run`, `turn.cancel`, `profile.switch`, `approval.respond`, `question.answer`,
`todo.edit`. Anything else is `forbidden` with `data.method` and a reason, as is a request
naming another session (`data.field`) or the agents of a path; nothing of the laptop is
reachable: no `fs.*`, `shell.*`, `tools.*`, setting, server, workspace or identity. An
approval answered over the relay is `allow` or `deny`; `allow_session` is `forbidden` with
`data.field` of `decision`, because it would loosen what the session asks, which is the
laptop person's to do at the laptop.

**Checked at both ends.** The plane checks each request against that list, at the role the
offer holds the person to, before relaying it, and asks again whether the offer still
shares the session with them before each steering command. The laptop's daemon checks it
again against its own record of the share, at the narrower of the two roles, and closes a
view the plane opened for somebody it never named. `initialize` answers `capabilities.relayed:
true` and the principal with `via: "plane"`, and every event the person causes carries that
actor.

**Offline.** A laptop that is not connected is `unavailable` with `data.offline_since` at
`remote.open` and at `initialize`; nothing is queued for it. A view ends with the
notification `relay.closed {"reason"}` and the socket closing: `withdrawn`, `the laptop went
offline`, `no longer shared with you`, `the token expired`.

**A person's watch.** What `remote.list` answers is also told as it changes, so a list of
offered sessions need not ask again on a timer. A client opens `wss://<plane>/v1/relay/watch`
(admitted from the same pages as a viewer's door) and sends `initialize` with the person's
plane token, the one `/rpc` takes (a relay token is `unauthenticated` there). The answer
carries `capabilities.remote_changed: true` and `sessions`, the person's list exactly as
`remote.list` answers it; from then on the plane sends the notification below each time that
list changes, an offer made, shared anew or withdrawn, or its laptop come or gone, and only
to the people the change concerns. `remote.list` may be asked on the socket too. The token
is renewed with `auth.refresh` on the open socket, warned of with `auth.expiring` two
minutes before it ends, and the socket closed with `auth.expired` after; a person
deactivated is closed at the next change. A plane from before the watch has no such path,
and a client asks `remote.list` instead.

```json
{"jsonrpc": "2.0", "method": "remote.changed", "params": {"sessions": [
  {"id": "20261024T101500-aB3dE5", "kind": "remote", "owner": "ada@example.test",
   "owner_name": "Ada", "workspace": "billing", "state": "online", "offline_since": null,
   "offered_at": "2026-10-24T10:15:00Z", "your_role": "control", "shares": null}]}}
```

The whole list each time, never a difference, so a client that missed one has missed
nothing the next one does not say. It carries the listing's metadata and nothing a session
said.

**Invitations ride the same watch** (Decision 949). The answer also carries
`capabilities.invites_changed: true` and `invites`, the person's invitations as
`invites.list` answers them, and the plane sends `invites.changed {invites}`, the whole list
again, each time an invitation to that person is made, changed or taken back, or the session
it was into is erased. `invites.list` may be asked on the socket too. A client that does not
know the notification ignores it; a plane from before invitations sends neither, and a client
asks `invites.list` once at each failed dial, as it asks `remote.list`. A client with a view
open under an invitation that is no longer listed closes it, saying it was taken back.

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

**A call outlives its client, for a while.** A registrant that leaves mid-call — a lid
closed, an app restarted — is usually back in a moment, on a fresh connection. The call
it was serving is parked for a grace (`TROUPE_CLIENT_TOOL_GRACE_SECONDS`, 60 s,
[troupe-daemon](apps/troupe_daemon/README.md#how-long-it-stays-up)) and, when a client
registers the tool again inside it — through a fresh consent, as always — is sent to that
client as the same `tool.invoke`: same `call_id`, same `arguments`. Nobody inside the
grace, and the call fails once, with a result naming the tool, saying its client left and
that the call may have run on its machine before it did (Decision 861). The registration
is gone by then (`tools_unregistered`, reason `disconnected`), and the tool leaves the
model's list at its next turn: a tool registered or gone in the middle of a turn changes
the list the turn after, so the tools in front of the turn's thinking stay as they were,
and a call to a gone one fails with a result saying so (Decision 871). A call to a
person's tool after it went, in that turn or a later one, is answered with whose it was
and that their client left, or that they took it back; a name nobody offered the session
is still an unknown tool (Decision 924). Troupe's own
clients send no `tools.unregister` when the person leaves a session: leaving is a drop.
The grace comes out of the call's own timeout, so a dropped laptop is never a hung turn.

**The session is tainted, visibly.** `session_tainted` is durable and appears in every
participant's summary, because a tool running on somebody's laptop is something the others
are entitled to know about. It names the person twice: `actor`, the identity's subject, and
`display_name`, their name as their sign-in gave it (on a pod the plane's, on a laptop the
daemon's from `me`), absent where there is none. A provider's subject may be an opaque
identifier, so a client says the name: "Ada Lovelace offered tools that run on their own
machine: client.notes.search", and the subject where the event has no name.

### `tools.register`

Needs `control`.

```json
{"jsonrpc": "2.0", "id": 7, "method": "tools.register", "params": {
  "command_id": "c-8", "session_id": "s-9f",
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
  "data": {"challenge": "…", "prompt": "Let this session run notes.search on your machine?",
           "tools": ["notes.search"], "reason": "…"}}}
```

With it: `{"registered": ["client.notes.search"], "taint": "personal_connector"}`.

A session that takes no client-hosted tools refuses before it issues a challenge, so nobody
is asked to consent to what it will not take: `forbidden`, with `setting` naming why and a
`reason` to show. On a platform with `managed_mcp_servers_only` the setting is that; on a pod
whose worker profile sets `personalTools: forbid` it is `personalTools`, with `profile`
(Decision 862). Troupe's clients take either as the answer for the attachment and do not
offer again on a later socket of it; a session opened again is offered again.

Registered tools appear as `client.<name>` under the same allowlists, permissions and
approvals as everything else. A client offering one of the person's own servers this way
(`mcp.tools`, `mcp.call`) names each tool `<server>.<tool>`, so the model sees
`client.wiki.search`, which no profile's `mcp.wiki.search` can be. A tool may carry
`"files": true`, where its server's entry says it is where the organisation keeps files
(`stores: files`): the session's harness then names it to its agent as where a file the
person asks for goes first (Decision 956), and nothing else changes.

### `tools.unregister` → `{"unregistered": [...]}`

Also happens on its own when the connection drops.

### `tool.invoke` (request, **server → client**)

```json
{"jsonrpc": "2.0", "id": "srv-42", "method": "tool.invoke", "params": {
  "call_id": "call-1", "name": "client.notes.search", "arguments": {"q": "the thing"}}}
```

The `id` is the server's (`srv-<n>`), and `name` is the tool as the model saw it,
`client.` and all.

The client answers with a result or an error, on the same connection. A client that does
not answer within the tool's timeout gets the call abandoned and the agent gets an error
result — the same contract as any other tool that fails. A client that registers a tool
after another connection of the person's dropped mid-call may be sent that call first,
under the `call_id` the earlier connection was asked with.

### Presence

```json
{"jsonrpc": "2.0", "method": "event", "params": {"topic": "presence:s-9f", "session_id": "s-9f",
  "event": {"ephemeral": true, "type": "presence", "agent": ["root"],
            "data": {"subject": "ada@example.test", "state": "focused",
                     "display_name": "Ada", "agent": ["root"]}}}}
```

An ephemeral event on the session's `presence:<id>` topic (§5); `display_name` and `agent`
are there when known, and `via: "plane"` for somebody attached through the plane's relay,
steering a laptop's session from another device. Ephemeral, always. Presence is published through a path that has no access to the durable
log, so it cannot end up there by accident.

---

## 9. Admin methods

Administration is a separate surface from a session: it runs against the **plane**, and
every method goes through one context that the console, `POST /rpc` and the admin MCP
server all go through. There is no admin method that returns session content —
administration is about profiles, teams, budgets and lifecycle state, and reading what a
session said requires being on its ACL.

Two roles. `platform_admin` comes from an identity-provider group named in the plane's
configuration; `team_admin` is assigned per team by a platform admin and is scoped to
that team.

| method | role | answers |
| --- | --- | --- |
| `admin.overview` | either | fleet health, active sessions, spend per team; for a platform admin, `openbao`: each grant the plane's OpenBao role needs, checked look-only, with the `bao` lines that add one it lacks |
| `admin.profiles.list` | either | profiles with conditions, pods, load and versions; in gitops mode each carries `gitops` (`source`, `generation`, and a `problem` — `refused`, `missing`, `plane_only`, `unwritten` — with `reasons`), and a refused resource with no profile is listed too |
| `admin.profiles.export` | platform | `{profiles, policy, triggers, left_out}`: every profile, the `TroupePolicy` and every `Trigger` as a repository would hold them, each `{name, path, yaml, notes}` (a trigger's also `team`), without what the plane or the cluster writes (`left_out`, of a profile) or keeps (a trigger's key, runs and revisions) |
| `admin.profile.get` | platform | the CR spec, the policy verdict, published vs reported bundle hash, and `gitops` as in the list; `written` and `spec` as the profile wrote them and `extended_by`, the profiles that extend it; with `effective: true`, `effective`: the chain, the profile in effect and each field with the profile it came from |
| `admin.profile.put` | platform | creates or updates a `WorkerProfile`, returning the diff that was applied; `extends` names one profile it extends, resolved by the plane into the resource it writes, and a change rewrites every profile below it (`extended_by`); `managed_by_gitops` in gitops mode |
| `admin.profile.delete` | platform | removes one; `conflict` while profiles extend it; `managed_by_gitops` in gitops mode, except for a profile the cluster has no resource for, whose row alone it deletes |
| `admin.pod.drain` | platform | drains a pod, returning what it held |
| `admin.artifacts.list` | either | `{}` → `[{id, title, kind, visibility, owner, owner_team, team, origin, version, bytes, total_bytes, created_at, published_at, may_take_down}]`, newest published first: every artifact for a platform admin, people's `private` ones included, and for a team admin those of the teams they administer (`team:<name>`) and those their teams own (`owner_team`, Decision 964) alone (Decision 953). Never what one holds. Empty while `artifacts_enabled` is off |
| `admin.artifact.takedown` | either | `{id}` → `{deleted, id}`: every version and byte, its links dead, its owner not asked; a platform admin's for any artifact, a team admin's for their teams' own, another `not_found`. Audited as `artifact.delete` with `by: takedown`. Destructive: over MCP it is confirmed by its `id` |
| `admin.teams.list` | either | teams, with grants, budgets, volumes and retention |
| `admin.team.enable` | platform | makes an IdP group a team; a name another team has is `conflict` unless `link` is true, which links the group into that team |
| `admin.team.update` | either | budget, retention, default visibility, volume, and `github` (`repositories`, `max_pushes`, `max_runs`, `max_attempts`; [github.md](docs/admin/github.md#9-how-far-a-run-may-go)); `allow_unenforced_workers` a platform admin's; keys it does not declare, a team's name and group among them, are left alone; `github` is `managed_by_gitops` in gitops mode, where the `GitHubApp` resource holds it |
| `admin.team.grant` / `admin.team.revoke` | platform | a team's access to a profile |
| `admin.sessions.list` | either | session *metadata*, never content: with the `repository` it was created with and `github`, what it did there (as `admin.runs.list` has it), and `memory`: for a session running on a pod that has had a turn, `current` where that turn read the memory in force for it and `behind` where it read an older version (Decision 947), absent otherwise; `filter.team` narrows to one team, another team's name `not_found` for a team admin |
| `admin.session.erase` | either | erases one, for authorised roles |
| `admin.bundles.list` | either | every version of a channel, each with its `summary` (names of agents, skills and MCP servers) |
| `admin.bundle.get` | either | one version in full: the document, its `detail` (agents with mode and skills, skills with files, MCP servers with the Secret to create), and adoption per profile |
| `admin.bundle.validate` | platform | checks a document the way publishing will, without publishing, each agent by the rules the daemon's `agents.validate` applies (`agent <name>: <what is wrong>`, #594); `{ok: true, summary, hash}` or `invalid_params` with `data.errors` |
| `admin.agent.check` | platform | one agent's definition (`name`, `definition`) checked as a bundle's agent is: `{ok, errors, warnings}`, each `{field, message}` in the words `agents.validate` answers, what the console's agent builder shows at each field (#594) |
| `admin.bundle.publish` / `admin.bundle.retire` | platform | publish a version — refused as `invalid_params` with `data.errors`, one sentence per problem, when the document is malformed or names an MCP host outside `allowedEgress` — or retire one |
| `admin.mcp.check` | either | `{host, allowed}`: whether the cluster policy lets a pod reach an MCP server's host |
| `admin.audit.list` | either | who changed what, with diffs, each change keyed by its path (`spec.llm.model`); a team admin's is the rows about their teams (the team, its triggers, principals and sessions) |
| `admin.profile.choices` | either | `{provider_types, size_classes}`: every provider type `llm.provider` may name, as the protocol's one list carries it (`{name, label, summary, url, default_url, url_example, key, key_var}`), and every size class `{name, sessions_per_worker, summary}`. What a form offers instead of free text. And `models`, each `{name, why}`: what the plane knows a provider serves, from the profile's own model, the models the organisation gives people's machines, the models sessions have been charged for and the models its bundle's agents name (with `profile`, that profile's; without, the organisation's and every session's). The plane never asks a provider for its list; the console's agent builder picks a model from these (#594) |
| `admin.profile.agents` | platform | `{profile, channel, agents, builtins, teams}`: a profile's agents as its bundle in effect has them, each `{name, mode, description, model, delegate, max_turns, skills, permissions, from, channel, builtin, definition, teams: [{team, may}]}`. `delegate` is the bundle's subagents for a primary holding the `delegate` tool, else `null`; `builtin` marks a primary Troupe ships that the profile offers because its bundle has none of that name; `may` is the team's grant resolved for that agent. `channel` is the one the profile follows in effect, `builtins` every agent Troupe ships with its file, to copy from, `teams` the teams granted the profile. The console's profile-first builder (#594) |
| `admin.provisioning.mode` | either | `direct` or `gitops`: whether the plane writes profiles to the cluster, or reads them and the triggers from resources a repository holds and refuses to write them |
| `admin.settings.list` | either | every platform setting with its value, where that value came from (`stored`, `deployed`, `unset`), what changing it does and when it takes effect; a secret is reported as set and never returned |
| `admin.setting.put` | platform | `{key, value}` — parsed against the setting's declared type and refused if it does not fit, or if the deployment owns it |
| `admin.setting.reset` | platform | `{key}` — drops the stored value, so the setting goes back to what the plane was deployed with |
| `admin.clients.get` | either | `{clients: {tui, daemon, desktop}, fleet: {tui, daemon, desktop}}`: each policy `{component, recommended, minimum, blocked, updated_by, updated_at}`, which versions of its clients this plane serves; and each component's clients last seen `{current, behind, refused, people: [{subject, display_name, version, platform, since, seen_at, standing}]}`, counted against the policy as it is now (`standing` is `current`, `behind` the recommended version, or `refused` at the next `initialize`). A team admin's `fleet` is their teams' people ([Client versions](#client-versions)) |
| `admin.clients.put` | platform | `{component, policy: {recommended?, minimum?, blocked?}}` → the component's policy as it now stands, with `changes` and `affected` (`{current, behind, refused}`: its clients last seen, against the new policy). Only the keys sent change, `null` clears one, `blocked` is the whole list; `invalid_params` with `data.field` and `data.reason` for a version SemVer cannot read, a `minimum` newer than `recommended`, or a `recommended` that is blocked. Audited as `clients.put`, with `affected` |
| `admin.signing.get` | either | the plane's signing key: `{algorithm, public_key, fingerprint, version, created_at, versions: [...]}`, every version's newest first; made on first use, and never the key itself, which transit holds and nothing exports ([The plane's signing key](#the-planes-signing-key)) |
| `admin.signing.rotate` | platform | `{fingerprint}`, the current key's, typed back to confirm → the key as it now stands, a new version, with `changes`. Every machine that pinned the old one refuses what the new one signs until its person accepts it. `invalid_params` naming the current fingerprint for any other. Audited as `signing.rotate` with the fingerprints and versions |
| `admin.releases.list` | either | `{releases, source, release_url}`: each release in the plane's object store for `/downloads`, newest first, `{version, state, files}` with `state` `mirrored` (its manifest is there, written last) or `mirroring` (a copy under way on this replica); `source`, where releases are mirrored from; `release_url`, the `client_release_url` setting ([Client versions](#client-versions)) |
| `admin.releases.mirror` | platform | `{version}` → `{version, state: "mirroring", files}`: the release's manifest fetched from `source` and checked against the release keys this plane was built with, then each file it names copied in the background, held to its size and sha256, and the manifest last. `invalid_params` with the sentence for a manifest the keys did not sign, one naming another version, or none. Audited as `release.mirror`, and the copy's end as `release.mirrored` or `release.mirror_failed` |
| `admin.memory.list` | team | `{}` → `{limit, organisation, teams, profiles}`: every memory document the caller may read (#55, Decision 922), each `{scope, name, subject, editable, current}`, `current` the version in force (`{version, hash, bytes, changed_by, changed_at}`) or null. A team admin's `teams` are theirs and their `profiles` empty; the organisation's is `editable` for a platform admin only. `limit` is the bytes a document holds, 8192 |
| `admin.memory.get` | team | `{scope, name, version?, against?}` → `{scope, name, subject, limit, editable, version, text, shown, against, against_text, diff, versions, readers}`: one document at a version (the one in force where none is named), `diff` what that version changed against the one before, or against the version `against` names (what the console sets side by side, with `against_text` that version's text), line by line (`[{op: same/del/add, text}]`), and every version newest first; a profile's has `inherited` besides, the documents of the profiles it extends that its sessions read before its own, the one that extends nothing first, each `{profile, version, hash, bytes, changed_by, changed_at, text}`. `scope` is `organisation`, `team` (its admins and a platform admin; another team's is `not_found`) or `profile` (a platform admin's). A deleted profile's document goes with it, every version. `readers` is who is behind (Decision 947): `{version, behind, sessions}`, `version` the one in force, `behind` how many of `sessions` are, and each session `{session_id, where, owner, profile, team, version, turn_at, behind, activated}`, every running session the document reaches, with the version of this document its last turn ran under (0 for none); a pod's session activated and given no turn yet is `activated: true`, `turn_at: null`, with the version its activation carried. An erased session's row goes with it. `where` is `pod` (active on a pod, which says what it read as each turn begins) or `machine` (named by its daemon at a poll in the last fifteen minutes). `lines` is who wrote each line of the version shown (Decision 951): `[{text, version, by, at, session?, agent?}]`, the version the line came in and who saved it, and an agent's entry's session and agent, derived from the versions and their audit rows; a rollback's lines keep who wrote them in the version rolled back to. `entries` is the version shown as its `## Topic` sections (Decision 957): `[{topic, body, heading, version, by, at, used, session?, agent?}]`, the text before the first heading the entry `General` with `heading: false`, `version`, `by` and `at` those of its newest line, and `used` how many sessions read a version holding it since it came in (approximate: of the one row a session the plane keeps, its last turn's) |
| `admin.memory.preview` | as the put | `{scope, name, text}` or `{scope, name, entries}` → `{subject, version, bytes, limit, unchanged, diff, effect, readers}`, written nowhere: the lines the text changes against the version in force, its size, which sessions read it and when (`effect`, in words), and `readers`, as `admin.memory.get` has them. Refused as the put would be |
| `admin.memory.put` | platform for the organisation's and a profile's; a team's admins for a team's | `{scope, name, text, version}` or `{scope, name, entries, version}` (entries written as sections, as `me.memory.put` writes them) → `{document, changes}`: the next version, over `version`, the one edited (0 for none). `conflict`, naming the version in force, where somebody saved since; `invalid_params` past 8192 bytes; `forbidden`, or `not_found` for a team the caller does not administer, with `data.reason` saying who may change it, which a person's own app shows them. An empty text clears the document; the text in force again makes no version. A running session in its scope on a pod is told (`session.memory`) and reads it from its next turn, a profile's reaching the sessions of every profile that extends it; signed-in machines' sessions read it once their daemon next asks, within five minutes. Audited as `memory.put` on `organisation`, `team/<name>` or `profile/<name>` with the version, size and hash |
| `admin.memory.rollback` | as the put | `{scope, name, to, version}` → `{document, changes}`: version `to`'s text saved as the next version, over `version`, the one in force, so every version stays in the history (Decision 947). Refused as the put is (`conflict`, `not_found` for a `to` there is not); the text in force already makes no version. Audited as `memory.put` with `rolled_back_to` and `note` (`rolled back to v3`) beside the version, size and hash, and told to running sessions as a put is |
| `admin.memory.nudge` | as the put | `{scope, name, session_id}` → `{session_id, where, told, reason?}`: one running session the document reaches (one of `readers`) told what it reads now, again: on a pod `session.memory` is sent and `told` is true; a session on a person's machine is not told (`told: false`, with `reason`), as its daemon asks at its next poll. `not_found` for a session the document does not reach or that is not running. Changes nothing else and is not audited |
| `admin.github.get` | either | the plane's GitHub App: `{configured, app_id, api_url, git_url, installations: [{owner, installation_id}], private_key: {set, type, fingerprint, transit_key, version}, permissions, resource_generation, updated_by, updated_at}`; never the key. In gitops mode also `gitops: {resource, generation, source, problem, reasons}`, the `GitHubApp` resource its settings come from |
| `admin.github.put` | platform | `{app: {app_id?, api_url?, installations?, private_key?}}` (or flat) → the App as it now stands, with `changes`. Only the keys sent change and `installations` is the whole list; `private_key`, the PEM GitHub downloads, is imported into OpenBao transit as a key that cannot be exported and is in no answer afterwards. `invalid_params` with `data.field` and `data.reason`, and nothing written, for anything that does not read. Audited as `github.put`, the key as its fingerprint ([github.md](docs/admin/github.md)). In gitops mode `app_id`, `api_url` and `installations` are `managed_by_gitops`; `private_key` and `webhook_secret` are taken |
| `admin.github.check` | platform | `{ok, checks: [{name, ok, detail, took_ms}], app: {slug, name} | null}`: four named checks, writing nothing: an App ID is set (`App`), OpenBao transit signs with its key (`Private key`), GitHub knows the App by the JWT that key signs (`GitHub`), and every installation set is one GitHub lists for it (`Installations`). A check after one that failed says it was not tried. With `repository` (`owner/name`), a fifth, `Repository`: a token for it is minted with what the App's installation may do there, the repository is read with it, and it is revoked, audited as `github.token`; the answer gains `repository: {name, installation_id, permissions, revoked} | null`, GitHub's list of what the token could do, and never the token (#653) |
| `admin.github.deliveries` | platform | `{limit?}` (50, at most 200) → `[{id, event, action, received_at, outcome}]`, newest first: GitHub's id for each delivery the App's webhook took, and what the plane did with it (the runs it fired, the session it resumed, or why neither). Never a body |
| `admin.github.delete` | platform | `{app_id}`, typed back to confirm, as for every destructive method → the App as it now stands (unconfigured), with `changes`. Forgets the App ID, API URL, installations and which transit key and webhook secret versions are its own; both stay in transit, unused, and a delivery is refused from then on. A session naming a repository is refused from then on. `not_found` where there is no App. `managed_by_gitops` in gitops mode, except for an App the cluster has no `GitHubApp` for (reported missing). Audited as `github.delete`, the key as its fingerprint |
| `admin.identity.check` | either | four named checks with what each proved and how long it took: provider discovery, its signing keys, the endpoints this plane was given, and who actually carries the platform admin group. `{group}` checks a candidate group *before* it is saved |
| `admin.principals.list` | either | a team's service principals: subject, profiles, last use, whether enabled — never a secret or its hash |
| `admin.principal.create` | either | `{team, name, description, profiles, sponsor}` → the principal, with `secret` exactly once; `profiles` must be within the team's grants, and `sponsor`, the person who answers for it, is required |
| `admin.principal.rotate` / `admin.principal.disable` | either | `{subject}`: a new secret shown once, or the end of the credential; a disabled principal is `unauthenticated` at its next call |
| `admin.triggers.list` | either | `{team}` → a team's trigger definitions, each with the `revision` its next firing would use; in gitops mode each carries `gitops` (`resource`, `source`, `generation`, and a `problem` — `refused`, `missing` — with `reasons`), a refused resource of the team with no trigger is listed as `{name, team, gitops}`, and a platform admin also gets those naming no team here, with `team` null |
| `admin.trigger.put` | either | upsert by `team` and `name`; partial on update, so `{team, name, enabled: false}` is a switch-off; returns the trigger, the diff and the `revision` the document now hashes to; `managed_by_gitops` in gitops mode, the switch-off included |
| `admin.trigger.delete` | either | `{team, name}`; the runs go with it, the sessions they made do not; `managed_by_gitops` in gitops mode, except for a trigger the cluster has no resource for |
| `admin.trigger.run` | either | `{team, name}`: fire it now, `manual`; a call by the same caller less than a minute after one before it is that one's run; in either mode |
| `admin.trigger.fix` | either | `{team, name, issue}`: one run of a trigger on a GitHub repository on one issue, by its number or its link on the trigger's repository, read from GitHub first (an open issue, not a pull request; a repository the team lists, private unless the profile allows public ones); `manual`; a call by the same caller on the same issue less than a minute after one before it is that one's run; in either mode; answers as `admin.trigger.run` does, or `invalid_params` with `field: "issue"` and why ([github-runs.md](docs/admin/github-runs.md#fix-this)) |
| `admin.trigger.key.rotate` | either | `{team, name}` → `{team, name, url, key, rotated_at}`: the trigger's own key, shown once, the old one dead at once; in either mode, since the key is never in a resource; a webhook that names no repository only, refused `invalid_params` for any other trigger |
| `admin.runs.list` | either | `{team, trigger?, limit?}` → runs newest first, each with its `state` (`created`, `running`, `waiting`, `done`, `failed`, `skipped`) read from the session's status, its `done_reason` and `failed_reason` (a turn the harness stopped, `tool_failures` or `agent_failed`, which makes the run `failed`), the `revision` and `revision_hash` it actually ran, `reason`, the cap that skipped a skipped run, and `github`: what its session did on GitHub, or `null` (`base`, `branch`, `commit`, `tree`, `pushes`, `pushed_at`, `pull_request: {number, url}`, `rounds: [{commit, state, failing, at}]`, `stopped: {at, reason}`; [github-runs.md](docs/admin/github-runs.md#the-fix-loop)) |
| `admin.trigger.revisions` | either | `{team, name}` → every revision of a trigger, newest first: the number, the hash, who made it and when, and whether it was reconstructed by the migration that introduced them |
| `admin.profile.preview` | platform | what policy makes of a profile and what would change, without writing anything; `extended_by` lists every profile below it as the write would leave it, with its diff, verdict and any problem |
| `admin.provisioners.list` | either | what can make a worker, and which guarantee each substrate does not give: admission policy, network policy, egress by hostname, disruption budget |
| `admin.hosts.list` | platform | `{profile}` → every machine registered to a profile, with whether it has ever enrolled |
| `admin.host.register` / `admin.host.rotate` | platform | register a machine against a profile and mint the secret it enrols with, shown once; or a new secret for one, keeping the machine. Either answers `ca` too, the PEM of the CA that signed the control port's certificate, which the machine pins: it enrols over TLS only. Refused (`unavailable`) while the control port has no certificate |
| `admin.host.enabled` | platform | stop a machine enrolling, or let it again |
| `admin.groups.list` | either | every identity-provider group the plane knows about, which is what a team links to; one that looks like another held twice (the same display name under another id) carries `looks_duplicated: {others, likely}`, else `null`; each carries `linked` (whether a team draws on it) and `last_seen_at` (its last sign-in; `null` for one only SCIM pushed) |
| `admin.identity.duplicates` | platform | `{people, groups}`: sets that look like one person or group held twice, the same email or display name under different keys, each `{by, people \| groups, likely}` with where each row came from (`sign-in` or `scim`) and the mismatch it most likely comes from. Nothing is merged on this evidence; rows that shared an `externalId` were merged when the plane upgraded ([Decision 899](docs/decisions/0899-one-row-per-person-and-scim-delete-removes.md)). A set `by: "external_id"` is a refused adoption, and names its `subject` and SCIM's `row` |
| `admin.identity.adopt` | platform | `{row, subject, confirm}` → `{subject, row, row_subject, folded, kms_names_left, via}`: settles a refused adoption, SCIM's `row` being the person under `subject`. A row a sign-in made under the subject is folded into it, which takes the subject (`folded` names it, `kms_names_left` any key-manager name left behind); with none, the next push or sign-in under the subject adopts the row. `not_found` once the pair is settled; refused for a row under the subject that SCIM named by another `externalId`. Audited `person.adopt` ([Decision 914](docs/decisions/0914-trigger-keys-run-minute-and-settling-adoptions.md)) |
| `admin.team.link` / `admin.team.unlink` | platform | draw a team's members from one more group, or stop; `admin.team.unlink.preview` says first who would lose access and how many sessions they can open |
| `admin.team.disable` | platform | remove a team; `admin.team.disable.preview` says first what goes with it: grants, administrators, service principals, triggers, group links, and the sessions left with no team |
| `admin.team.admin.add` / `admin.team.admin.remove` | platform | make somebody an administrator of one team, or take the role away |
| `admin.session.erase.preview` | either | what erasing a session will do, before doing it: what it holds, that its key is destroyed so no backup recovers it, and how many forks survive it |
| `admin.bundle.preview` | either | what publishing a document would change against the channel's current version, and which teams lose an entitlement |
| `admin.integrations.list` | either | MCP servers carried by more than one profile, every host anything here dials with whether the cluster policy allows it, and each trigger's notification target |
| `admin.connections.list` | either | who has connected a personal credential to which person-mode server, and whose identity each session carries |
| `admin.run.review` | either | marks the run behind a session as looked at, by whoever asks |
| `admin.audit.verify` | platform | checks the audit trail's hash chain: `result` is `ok`, or the first row that does not verify with its `reason` (`altered`, `chain_broken`) |
| `admin.setting.effective` | either | for a setting decided at more than one rung: the value in force, the rung that decided it, and every rung that had an opinion |
| `admin.person.budget` | platform | sets or clears a person's own monthly spend ceiling, in millionths, across every team they are in |
| `admin.budget.explain` | platform | every spend ceiling that applies to a person, narrowest first: which would bind, what each has left, its period, and the rung that set it |
| `admin.provider.get` / `admin.provider.check` | either | the identity provider's sign-in settings, each with where it came from (a secret as set or not) and the URLs to register at the provider; or a candidate tested without saving it |
| `admin.provider.put` / `admin.provider.reset` | platform | save the identity provider, or put every sign-in setting back to what the plane was deployed with |
| `admin.scim.get` | either | the SCIM connector: the URL the provider pushes to, whether a token is set, when it was rotated and last used, and whether pushed groups become teams |
| `admin.scim.rotate` / `admin.scim.delete` / `admin.scim.update` | platform | mint the connector's token and return it once, forget it, or change the connector's switch |

Membership is never editable: it comes from the identity provider, and a method to change
it would be a second source of truth for who is in a team.

### The same methods as MCP tools

    POST /mcp

Streamable HTTP, one JSON-RPC message per request, protocol revision `2025-06-18`.

Two kinds of bearer token are accepted, because there are two kinds of caller. A
**plane** token, the same one `/rpc` takes, from a caller that already holds one. Any
other MCP client does OAuth against the identity provider — there is no step in that flow
where it could obtain a plane token — and presents what the provider issued: an id_token
addressed to the client id, or an access token addressed to `api://<client-id>` (one
provider's convention) or to `<base>/mcp`, which the scope the plane advertises
(`<base>/mcp/admin`) produces. Both are verified in full against the provider's published keys, the
configured issuer and that closed list of audiences, and both resolve to the same person,
because the subject is the same claim in each.

A 401 from `/mcp` carries `WWW-Authenticate: Bearer realm="troupe-plane",
resource_metadata="<base>/.well-known/oauth-protected-resource"`, and that document
(RFC 9728, served at the bare path and at `/.well-known/oauth-protected-resource/mcp`)
names the resource, the authorization server and the scope to ask for. Troupe is a resource
server and deliberately not an authorization server: running one would mean holding a
second set of credentials for the same people. Stateless: no session id is issued and none
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

### Trigger revisions

A trigger's row is mutable and a run's provenance is not. Every firing names a
**revision**: the trigger document as it stood, frozen, and addressed by the `sha256:`
hash of its canonical form — the same convention a bundle uses, for the same reason.

The document is `profile`, `agent`, `principal_id`, `prompt_template`, `terms`,
`visibility`, `review`, `notify`, `concurrency` and `source`. It is **a property of the
document, not of the source**: nothing in the hash says how a firing arrived, so a
schedule, a webhook, an API call and a person's hand name the same revision when the
document has not moved. `enabled` is not in it — switching a trigger off does not change
what a run would be.

Three consequences a client may rely on:

* A `trigger.put` that changes nothing creates no revision, and an edit back to a
  previous wording lands on that revision rather than making a third.
* A run names exactly one revision, for as long as the run exists. A firing that
  overlaps an edit resolves once, before it writes anything; a retry of a failed run
  re-reads the revision the run recorded.
* A session made by a trigger carries `origin.revision` — the hash — so the session
  itself says which wording made it, without a join through the run.

### Triggers and principals on the harness side

These methods on the plane's `/rpc` are not administrative, because a caller other
than an admin uses them:

| method | scope | who | answers |
| --- | --- | --- | --- |
| `trigger.fire` | control | the trigger's principal, or an admin of its team | `{trigger (name, `team/name` or id), idempotency_key, event}` → the run and, when a session was made, the same `{session_id, endpoint, token}` `session.create` returns. The run names the `revision` and `revision_hash` it ran. The same key returns the same run, the same revision and a fresh token; over the trigger's `concurrency` the run is `skipped` and has no session |
| `session.grant` | control | the session's owner, or an admin of its team | `{session_id, subject, role}` (`owner`, `collaborator`, `viewer`; default collaborator) → mirrored in the plane's ACL and pushed to the pod holding the session as `acl.changed` |
| `session.invite` | control | a pod session's owner or an admin of its team; a private session's owner | `{session_id, subject, role, keys}` → `{session_id, invite: {subject, display_name, email, role, invited_by, invited_at}, pushed}`: a person invited by name (Decision 949), `subject` their subject or their email, `role` `observe` (default) or `control`. A pod session's is its grant made visible: the ACL row (`viewer` or `collaborator`) pushed to the pod as `acl.changed`, and the pod told `invite.changed`, which gives the log `session_invited`. A private session's `control` steers it while its owner offers it (Decision 952), and it carries `keys: [{key_version, slot}]`, where its owner's daemon put each generation of its key in the invitee's own slot (`troupe/people/<invitee>/invited/<session_id>/k<n>-<random>`), one for each of the session's `key_version`; the plane keeps the paths and cannot read what is there. `forbidden` with `reason: "not on this profile's teams"` and `profile` for a person the pod session's profile does not cover, `"shares no team with this session's owner"` for a private one; a platform admin is always invitable; `not_found` for nobody of that name. Inviting again changes the role. The invitee's watch is told (`invites.changed`) |
| `session.uninvite` | control | as `session.invite` | `{session_id, subject}` → `{session_id, subject, rekey_due, pushed}`: the invitation taken back. A pod session's ACL row goes and the pod is pushed `acl.changed` with `role: null`, refusing the person's next command, and `invite.changed` (`session_uninvited`); a private session's copies of its key in their slot are destroyed with the plane's credential, and the session is `rekey_due` until its owner's daemon reports a new key (`session.rekeyed`). `not_found` for a person not invited |
| `session.invites` | observe | anybody who may see the session, or is invited into it | `{session_id}` → `{session_id, invites: [{subject, display_name, email, role, invited_by, invited_at}]}`: whom it is shared with, the oldest first |
| `session.invite_slot` | control | a private session's owner | `{session_id, subject}` → `{session_id, subject, display_name, prefix, key_version}`: where to put the session's key for a person about to be invited, the invitee's own `troupe/people/<name>/invited/<session_id>/`, after the same refusals `session.invite` makes, so nothing is put anywhere for somebody it would refuse |
| `session.keys` | observe | a person invited into a private session | `{session_id}` → `{assertion, expires_at, audience, key_manager, session_id, key_version, last_seq, keys: [{key_version, slot}]}`: where each generation of the session's key was put for the caller, and an assertion for their own name, which their daemon spends at the key manager to read them. `not_found` for anybody not invited, and for a session erased or being erased |
| `session.rekeyed` | control | a private session's owner | `{session_id, key_version, keys: [{subject, slot}]}` → the session row: sealed from now on under generation `key_version` of its key (`<session_id>.k<n>` beside the first), put in the slot of every person still invited; no longer `rekey_due`. `conflict` for a version that is neither the session's nor the next, `invalid_params` with `missing` where a person still invited has no key in it. The same version again is a retry |
| `invites.list` | observe | anybody, for themselves | `{}` → `{invites: [{session_id, kind, title, profile, state, owner, owner_name, role, invited_by, invited_by_name, invited_at, offered, offline_since}]}`: the invitations to the caller, newest first, not those into a session erased or being erased. `offered` is a private session's: whether its owner offers it for steering now, which is when a `control` invitation steers it (Decision 952); null for a pod session. `offline_since` is when the laptop offering it went, while the plane still lists the offer offline (its daemon killed, the machine asleep), as `remote.list` has it, and `offered` is then false; null otherwise |
| `people.search` | observe | anybody | `{query, session_id?, limit?}` → `{people: [{subject, display_name, email}]}`: active people whose name, email or subject starts with `query`, among those who share a team with the caller and, with a `session_id` the caller may invite into, those its profile covers. At most `limit` (10 by default, 25 at most); never the caller, nor the session's owner |
| `session.review` | control | anybody who can see the session | `{session_id}` → sets `reviewed_by`/`reviewed_at` on the session and its run, audited as `session.review` |
| `initialize` | observe | anybody | `{protocol_version, client_info: {name, version, platform?}, capabilities}` → `{protocol_version, server_info: {name: "troupe-plane", version}, principal, client_update, policy: {revision}}`: the handshake over `/rpc`, where `principal` is what `me` answers (with `organisation: {name}`, the organisation's name as the plane is called, Decision 957), `client_update` is this plane's word on the client's version, or `update_required` signed as such, and `policy.revision` a digest of the two signed answers ([Client versions](#client-versions)) |
| `me.client_versions` | observe | anybody | `{}` → `{tui, daemon, desktop}`, each `{recommended, minimum, blocked}`: what `troupe update` installs by, asked on its own because the client that most needs it is the one `initialize` refuses; with `release: {url}`, where releases are (null for GitHub's), and `signed`, the same as `{versions, release}` signed by the plane's key ([The plane's signing key](#the-planes-signing-key)) |
| `me.client_defaults` | observe | anybody | `{}` → `{configured, provider, base_url, auth, models: {default, cheap, expensive}, defaults, enforced}` — what an administrator says people's own machines should talk to (the *Client defaults* settings), for a client to pre-fill its model settings with. `key_help` is the organisation's word on where a key comes from, a URL or a sentence (the `client_key_help` setting), for a client to show beside its key field, null where it says nothing. Each person supplies their own key, unless an administrator chose to hand one key to everybody (`client_key`): then `defaults` carries it as `api_key`, below each person's own, and anybody signed in may read it, which is what choosing it means. `configured` is false, and the rest null, until a provider is set. `defaults` is the same in a config file's shape, only what is set, and `enforced` the `client_enforced` setting, `{}` when unset, per-tool `permissions` among what it may hold (Decision 907): the organisation's document a machine reads below its person's file and holds every layer to (Decision 869, `config.organisation`). A plane from before them answers without the two, and a client reads its old fields as the defaults. With `signed`: the whole answer signed by the plane's key ([The plane's signing key](#the-planes-signing-key)) |
| `me.clients` | observe | anybody, for themselves | `{}` → `{clients: [{component, version, platform, since, seen_at, standing, recommended}]}`: which version of each of the caller's own clients (`tui`, `daemon`, `desktop`) the plane last saw at `initialize`, and how it stands against the policy now (`current`, `behind` the `recommended` version, or `refused` at its next `initialize`), as `admin.clients.get` says it of the people an administrator sees ([Client versions](#client-versions)). Nobody else's. A plane from before it has no `me.clients` |
| `me.memory` | observe | anybody | `{sessions?, blame?, entries?}` → `{documents: [{scope, name, version, hash, updated_at, text}], user, organisation: {name}}`, `user` with `lines` where `blame` is true, as `admin.memory.get` has them (Decision 951), and each document and `user` with `entries` where `entries` is true, as `admin.memory.get` has them (Decision 957; the poll does not ask it); `organisation` is the organisation's name, for "Everyone at <name>"; with `entries`, `roles: {platform_admin, team_admin}` too, whether the caller is a platform admin and the teams they administer by name, so a client offers to change the organisation's level or a team's only where `admin.memory.put` would take it (the plane still decides at every save): the memory documents a person's own machine reads into every session on it (#55, Decision 922), the organisation's and then each of the caller's teams', by name, then the caller's own (`scope: "user"`, `name: null`, Decision 943); never another team's or another person's, and never a profile's, since no laptop session runs on one. The organisation's are instructions from the organisation, read-only to agents; each document holds at most 8192 bytes. `user` is the caller's own as they edit it, `{version, text, hash, bytes, limit, changed_by, changed_at}`, `version` 0 where they have none, which is what a save names. With `signed`, as `memory` ([The plane's signing key](#the-planes-signing-key)); the daemon keeps the answer as `<state>/memory.json` after every link that brings a token and every five minutes while it holds one, gives a changed one to the sessions running there, and drops it when the person signs out (`config.memory`). A plane from before it has no `me.memory`, and a machine keeps the copy it had. `sessions` is what the daemon says with every ask of what each session running on the machine read at its last turn (Decision 947), `[{session_id, turn_at, documents: [{scope, name, version, hash}]}]`, never a document's text, a title or a workspace: kept for the caller alone, at most 64 a call, as the `machine` rows of `admin.memory.get`'s `readers`; a row of a pod's session or another person's is left as it is |
| `me.memory.preview` | observe | anybody, for themselves | `{text}` → `{version, bytes, limit, unchanged, diff, effect}`: what saving `text` as the caller's own memory would do, written nowhere, the lines it changes against the version in force (`op` `same`, `del` or `add`) and its size against the limit; refused as the save would be. What the console's Mine previews with |
| `me.memory.put` | control | anybody, for themselves | `{text, version}` or `{entries, version}` → `{changed, entry: null, user}`: the caller's own memory as they wrote it, or as entries `[{topic, body}]` written as `## Topic` sections in their order, each heading as given (one without a topic, first only, is the text before the first heading; a body holds no `## ` heading of its own), the next version over `version`, the one edited (0 for none); `conflict`, naming the version in force, where it was saved elsewhere since; `invalid_params` past 8192 bytes. Or `{append, topic?}` → `{changed, entry, topic, user}`: one entry, folded onto one line and at most 1024 bytes, added as `- <entry>` at the end of the section on `topic` (`Notes` for none; found as topics compare, made at the end where there is none, Decision 957) and never in place of what is there, which is what a daemon sends for an agent's `remember` with `level: "me"`; refused past the limit, naming `troupe memory --edit`. Every version is kept with who saved it, audited as `memory.put` on `user/<subject>` with the version, size and hash and never the text; the caller's running sessions on pods are told (`session.memory`) and read it from their next turn. No administrator's method reads, lists or changes anybody's (`admin.memory.*` refuses the scope). A service principal has none (`forbidden`) |
| `memory.in_effect` | observe | anybody, for themselves | `{team?, profile?}` → `{team, profile, organisation: {name}, levels, entries}`: what a new session of the caller's in `team` (one of theirs; their first by name where none is named, `null` for a person in none; another is `not_found`) reads, on `profile` where one they may use through that team is named (`not_found` otherwise), as one list of topics (Decision 957). `levels` is the chain, lowest first, `[{scope, name, version, entries}]`: the organisation's, the team's, the profile's chain (the one that extends nothing first), the caller's own. `entries` is every entry in effect, a topic where it first comes and its closest level's entry there, `{topic, body, heading, version, by, at, used, level: {scope, name}, replaces: [{level, topic, body}]}`, `replaces` the lower levels' entries on its topic it replaced, closest first. Topics compare by their words, case and spacing aside; the text before a document's first heading (`heading: false`, topic `General`) replaces nothing and is never replaced; two levels of one rank replace neither. A session's prompt is built by the same rule. A service principal is `forbidden` |
| `me.memory.history` | observe | anybody, for themselves | `{version?, against?}` → `{versions, version, text, against, against_text, diff}`: every version of the caller's own memory `{version, hash, bytes, changed_by, changed_at}`, newest first, one version's text (the one in force where none is named) beside another's (the version before it where none is named) and the line diff between them (Decision 954). `not_found` for a version there is not; a service principal is `forbidden` |
| `me.memory.rollback` | control | anybody, for themselves | `{to, version}` → as `me.memory.put` answers: version `to`'s text as the next version, over `version`, the one in force as the caller read it (`conflict` where it was saved since; `not_found` for a `to` there is not). Audited as `memory.put` with `rolled_back_to` and the note `rolled back to v<to>`, so its lines keep who wrote them |
| `me.connections.list` | observe | anybody | the MCP servers on the caller's profiles that act as *them*, each with its `slot` and whether they have `connected` it. Whether, never what: the plane can see that a slot has a version and cannot read one |
| `me.connections.grant` | control | anybody, for themselves | `{slot}` → `{assertion, expires_at, audience, key_manager: {address, mount, auth_path, role, name, path}}`. **No value crosses the plane**: it answers a short-lived assertion for the caller's own name at the key manager (`name`, the segment of `path` under `troupe/people/`, not always their subject: Decision 755). The client exchanges it with the key manager itself for a token scoped to its own subtree, and then writes the value directly. The same grant is how a person removes one — deletion is theirs, always |
| `session.register` | control | anybody, for their own private sessions | `{session_id, device, epoch, head_hash, last_seq, object_bytes, workspace_bytes, title, claim}` → the session row. Idempotent on the id: the first call mints epoch 1, a later one is a seal report. A seal carries the `epoch` the device holds and is refused with `stale_version` if another device has moved past it; `last_seq` never goes backwards. `claim: true` takes the session over on this device, bumping the epoch conditionally — two devices sending the same `epoch` produce one winner, and the loser learns it lost on its next seal rather than by being told, and stops sealing (issue #433) |
| `session.presign` | control | anybody, for their own private sessions; a person invited into one, to `get` and `head` | `{session_id, method (`get`/`put`/`head`), keys, epoch}` → `{expires_in, urls}`, one signed URL per key, good for five minutes. Every key must be under `sessions/<session_id>/` and at most 64 per call. **The bytes never cross the plane**: it holds an object-storage credential scoped to signing and no key for what it signs for, which is the narrowest revision of Decision 90 that lets a laptop seal at all. `epoch`, optional, is the one the caller holds: a daemon sealing names it on every `put`, and one another device has claimed past is refused with `stale_version` and signed nothing, so the device that lost the session learns it before it writes under the prefix rather than at the report after (issue #441, Decision 800). Without one it signs as before, for a restore and a daemon from before 0.8.6 |
| `session.objects` | observe | anybody, for their own private sessions, and a person invited into one | `{session_id, prefix}` → `{keys}` under `sessions/<session_id>/`. A caller with no object-storage credential cannot list — a listing is signed against the bucket, not against a key it does not yet know — so the plane lists for it. A `prefix` may narrow the listing and may not widen it; one that is not under the session's own is ignored |
| `session.assertion` | control | anybody, for their own private sessions | `{session_id}` → `{assertion, expires_at, audience, key_manager: {address, mount, auth_path, role, name, path}}`, the same shape `me.connections.grant` answers and for the same reason. The path is `troupe/people/<name>/sessions/<session_id>`; the person policy covers their own subtree and no pod role covers any of it. A daemon makes or finds the session's key under `name`, and under the subject it is linked as only where a plane from before Decision 755 answers none. The session must already be registered, which is what makes this a statement about a session the plane agrees is theirs |
| `session.erasures` | control | anybody, for their own private sessions | `{device}` → `{erasures: [{session_id, erased_at}]}`: the caller's private sessions whose key is destroyed and whose erasure this `device` has not acknowledged. A daemon asks when a client links it with a plane token. A session whose key is not yet destroyed is tried again first and is not listed until it is (Decision 756) |
| `session.erased` | control | anybody, for their own erased private sessions | `{session_id, device}` → `{session_id, device, deleting, objects_deleted}`: this device has stopped sealing the session and erased its copy, and the plane deletes every version of every object under `sessions/<session_id>/` and records the device once none is left. `deleting: false` with how many went when that is done within the call; `deleting: true` and no count when it takes longer than the call waits (five seconds), and the plane carries on and records the device when it is done. `unavailable` with `objects_deleted` and `objects_left` where the object store refused or failed some: the device is not recorded, and `session.erasures` names the session to it again, which tries again (Decision 804). `not_found` for a session that is not the caller's, not private or not erased: saying a session is erased does not erase it |

| `remote.list` | observe | anybody | `{}` → `{sessions: [{id, kind: "remote", owner, owner_name, workspace, state, offline_since, offered_at, private, your_role, shares}]}`: laptop sessions offered for steering from another device that are the caller's own or shared with them ([Relayed connections](#relayed-connections)). `state` is `online` while the laptop's connection is up, else `offline` since `offline_since`; `your_role` is `owner`, `control` or `observe`; `shares` only for the owner. `workspace` is the last name of its folder, never a path; nothing a session says is kept. `private` is a private session offered with its owner's consent (Decision 952): somebody it is shared with holds a role only while they also hold an invitation into it, the narrower of the two |
| `remote.open` | observe | the owner, or a person the session is shared with | `{session_id}` → `{session_id, kind: "remote", endpoint, role, your_role, token, expires_at}`: where to attach, and a token for that session alone at the caller's role, audience `troupe-relay`, at most fifteen minutes. Asked again for a fresh one. `not_found` for anybody else; `unavailable` with `offline_since` for a laptop that is away; `forbidden` with `data.team` where a team of the owner's does not allow offering |
| `remote.grant` | control | anybody | `{device}` → `{grant, device}`: a laptop daemon's own sign-in for steering, asked at its first offer (Decision 928). One per person and device, a new one replacing the last; the plane keeps its hash, and records `remote.grant` in the audit with the device. `forbidden` with `data.team` where a team of the caller's does not allow offering (`teams.remote_offering_allowed`) |
| `artifact.list` | observe | anybody | `{mine?, shared?, teams?, visibility?}` → `{artifacts, profiles, teams, enabled, publish_organisation, public_links, gallery_url}`: the artifacts the caller may see, newest published first (Decisions 948, 950 and 953): their own, those a link gave them, the organisation's, those of each team they are in (`teams`) and of each profile they are granted (`profiles`); a team admin sees their teams' too, and a platform admin every one but another person's `private` ones. `mine: true` narrows to their own, `shared: true` to those a link gave them, `teams: true` to the teams' own (of the teams they are in or administer; every team's for a platform admin), `visibility` to one. Each is `{id, title, kind, visibility, scope, owner, owner_team, mine, role, origin: {session_id, profile, agent, where}, team, version, current, pinned, bytes, url, created_at, published_at, may_delete, may_edit, may_transfer, public_links, public}`: `scope` is the gallery tab it is under for the caller, `mine`, `private` (their own private one), `organisation`, `team:<name>`, `profile:<name>` or `shared` (a link alone reached it), so a client tabs by it without working out membership; `owner` is the person who published it and `owner_team` the team it belongs to, or `null` (Decision 964): a team's is owned by every member and administrator of that team, whose `role` is `owner` and `mine` true as the person's are when no team owns it, and they see it whatever its visibility; `may_transfer` is whether the caller may move whose it is with `artifact.transfer`; `role` is `owner`, `edit` or `view`; `version` the newest and `current` the one its address serves; `public` whether a public link opens it now. `public_links` beside the list is the administrator's `artifacts_public_links`. With `artifacts_enabled` off, `enabled: false` and none |
| `artifact.get` | observe | anybody who may see it | `{id}` → the artifact with `versions: [{n, hash, bytes, files: [{path, sha256, content_type, bytes}], published_by, published_at, note, rolled_back_to, url}]`, newest first; for its owner also `shares` (as `artifact.share` answers `share`) and `public_links_allowed`. One the caller may not see is `not_found`, as one that is not there |
| `artifact.open` | observe | anybody who may see it | `{id, version?}` → `{url, expires_in}`: a one-time address on the artifacts host, good for a minute, that signs the caller in there with a cookie of that host's own and opens the artifact, or that version. `unavailable` where the plane was deployed with no artifacts host |
| `artifact.publish` | control | anybody, privately, to a team they are in, a profile they are granted or the organisation (`artifacts_publish_organisation`); a platform admin to any team | `{title, kind, visibility?, owner?, files: [{path, content_type?, bytes}] or upload, id?, note?, session_id?, agent?}` → the artifact as `artifact.get` answers it. `owner` is whose it is (Decision 964): `me`, `team` (the team of a `team:<name>` visibility; `invalid_params` with any other) or `team:<name>`, a team the caller is in (a platform admin any there is), refused as a publish to that team is; unsaid, one published to a team is that team's and any other the caller's own. `kind` is `html`, `markdown` or `file`; `visibility` is `private` (the default: the owner and whoever their links reach, nobody else, not a team admin), `organisation`, `team:<name>` (its members; a team the caller is not in is `forbidden`, the sentence naming theirs, and its bytes count against that team's quota) or `profile:<name>`; `bytes` is base64; a path is relative, each part between its `/` at most 255 bytes, and does not start with `v<n>`; `upload` is a handle from `artifact.upload.begin` instead of `files`. `id` is `artifact.put`: the next version of one the caller owns or holds an edit link to, keeping its kind, and only an owner moves its `visibility`; one naming `owner` is `invalid_params`, since whose it is moves by `artifact.transfer` alone. A file is at most 16 MiB and a version 64 MiB (`payload_too_large`); the team's artifacts, every stored byte counted, at most its `artifact_quota_bytes`. A refused version leaves no object behind. Audited as `artifact.publish` with the version, hash, note, session, `owner_team` where a team owns it, `by: "edit link"` for an editor's, and any visibility it moved from, never the content |
| `artifact.put` | control | the owner, or an edit link's holder | `{id, files or upload, base?, note?, title?, visibility?}` (with `base`, `files` may be left out) → the artifact: version n+1 at the same `url`. Without `base` the files are the whole version; with `base`, the version an edit was made on, the files not sent are carried from it as they are (their objects not copied), and `conflict` if a version was published after it; with `base` and neither `files` nor `upload`, every file is carried, which is how its owner moves its `visibility` or retitles it without sending it again. `visibility` is the owner's alone (`forbidden` for an editor) |
| `artifact.rollback` | control | the owner, or an edit link's holder | `{id, version}` → the artifact: that version's files as the next version, noted `rolled back to v<n>`, nothing copied. Audited as `artifact.rollback` with `rolled_back_to` |
| `artifact.pin` | control | the owner | `{id, version}` → the artifact, its address now serving that version while newer ones are published; `version: null` unpins, back to the newest. Audited as `artifact.pin` |
| `artifact.read` | observe | anybody who may see it | `{id, path, version?}` → `{id, version, path, content_type, text}`: one text file of a version (the current one if none), for an editor; `invalid_params` for one that is not UTF-8 or past a mebibyte |
| `artifact.preview` | control | the owner, or an edit link's holder | `{id, base?, path, text, content_type?}` → `{url, expires_in}`: an address on the artifacts host, `/p/<nonce>/`, good for an hour, that serves `text` as `path` over version `base` (the current one if none) with its other files, under the artifacts host's policy, which a client frames. Nothing is published, and whether its person may still put is read at every request |
| `artifact.upload.begin` | control | anybody who may publish | `{files: [{path, size, content_type?}]}` → `{upload, expires_in, urls: [{path, url}]}`: a URL for each file, presigned for a PUT into the object store for fifteen minutes, under the limits a publish has. `artifact.publish` or `artifact.put` then names `upload`; the plane reads each file back, refuses one that is missing or not the size announced, and spends the handle. Another person's handle is `not_found` |
| `artifact.share` | control | the owner | `{id, role: view or edit, expires?, public?}` → `{token, url, share}`: a link, `https://<artifacts host>/s/<token>` (with a trailing `/` for a public one), shown this once; the plane keeps its SHA-256. `share` is `{id, role, public, state, expires_at, revoked_at, created_by, created_at, used_by: [{person, first_used_at, last_used_at, revoked_at}]}`. `expires` is ISO 8601 in the future. `public: true` is `forbidden`, naming `artifacts_public_links`, unless that setting is on; then it is view only and needs `expires` within 90 days. Audited as `artifact.share` |
| `artifact.unshare` | control | the owner | `{id, share}` revokes that link for everybody; `{id, person}` (a subject) revokes that person from every link to it → `{revoked, id, share or person}`. Audited as `artifact.unshare` |
| `artifact.redeem` | observe | anybody signed in | `{token}` → `{id, role, url}`: the link's role for the caller from now on, recorded with when (`artifact.share.used` in the audit the first time), and a one-time address that opens it, as `artifact.open` answers. `not_found` for a link that expired, was revoked, revoked this person or is not one. The console spends a link here when its artifacts host sent a signed-out viewer to `#/artifacts/link/<token>` |
| `artifact.public` | control | the owner | `{id, enabled}` → the artifact: its own switch for its public links; off, none of them opens, whatever the setting. Audited as `artifact.public` |
| `artifact.delete` | control | an owner (its person, or a member or admin of the team that owns it), or a takedown by a platform admin (any, a `private` one too) or by an admin of the team a `team:<name>` one is for | `{id}` → `{deleted, id}`: every version and every byte. Audited as `artifact.delete` with `by` (`owner` for any owner's, the owning team's people included, or `takedown`) and the session it came from |
| `artifact.transfer` | control | its person, to a team they are in; a platform admin, any artifact to any team or back; an admin of the team that owns it, back | `{id, to}` → the artifact as `artifact.get` answers it (Decision 964). `to` is `team:<name>`, which makes it that team's (its members and admins its owners, the person who published it kept on the row), or `me`, which takes it back from the team and makes the caller its person, since the one who published it may be gone. A member who does not administer the owning team is `forbidden`; a person's own to a team they are not in is `forbidden`, naming theirs; a team's to another team is a platform admin's alone; `me` on one no team owns is `invalid_params`; one the caller may not see is `not_found`, but a platform admin moves a `private` one too, as they take one down. Audited as `artifact.transfer` with `from` (`person` or `team:<name>`), `to` and the title |

**A pod's agent adds to its person's own memory** with `session.memory.put {session_id,
scope, append, topic?, epoch?}` over the pod's control connection (Decision 943), the one write of
memory an agent has. The plane takes whose memory it is from the session's row, as it takes
`kms.assertion`'s subject, so a pod writes only for the owner of a session it holds
(`not_found` otherwise, `conflict` at a stale `epoch`); `scope` is `user` or absent, and any
other level is refused as `forbidden`, the organisation's, a team's and a profile's being
read-only to agents. The entry is added as `me.memory.put`'s `append` adds it, recorded in
the audit with the session it came from; the answer is `{entry, topic, changed, version}`.

**A pod's agent publishes an artifact** with `session.artifact.publish {session_id, epoch?, agent?, title, kind, visibility, owner?, files or upload, id?}` over the pod's control connection (Decision 948): the plane takes who published it from the session's row, as for `session.memory.put`, counts it against the session's team and records its profile, and checks the rest as `artifact.publish` checks it for that person, `owner` included (one published to a team is the team's unless it says `me`, Decision 964) (`not_found` for a session the pod does not hold, `conflict` at a stale `epoch`). Files whose base64 passes about 2.5 MB go first by `session.artifact.upload.begin {session_id, epoch?, files: [{path, size, content_type?}]}`, which answers as `artifact.upload.begin` does with a handle for the session's owner; the pod sends each file to its URL and publishes naming `upload`. An artifact is read only on the artifacts host, never on the plane's: `GET /a/<id>/` is the current version, `/a/<id>/<path>` its files, `/a/<id>/v<n>/` a version, every answer sandboxed under a policy that runs only the artifact's own scripts, connects nowhere but that host and is framed by the plane's pages alone; `GET /enter?ticket=` is where `artifact.open`'s address goes; a viewer with no cookie on that host is sent to the console's `#/artifacts/open/<id>[/v<n>]`, which signs them in and comes back with `artifact.open`'s address for that version. `GET /s/<token>` is a link: a viewer that host's cookie names is given its role and sent to `/a/<id>/`, and anybody else to the console's `#/artifacts/link/<token>`, which signs them in and spends it with `artifact.redeem`; a public link's artifact is served without a sign-in under `/s/<token>/`, only while `artifacts_public_links` and the artifact's own switch are on. `GET /p/<nonce>/` is an edit's preview from `artifact.preview` (Decision 950).

**A pod's session says what memory each turn reads** with `session.memory.read {session_id,
documents, epoch?}` as the turn begins (Decision 947): `documents` is what the session holds,
each `{scope, name, version, hash}`, never the text. The plane keeps it as what the turn runs
under and answers `{session_id, current: true}`, or, where the session is behind the versions
in force, `{session_id, current: false, memory}` with the documents `session.memory` would
carry, which the pod gives the session before the turn starts, so a `session.memory` lost
between two turns leaves no turn on the versions before it; what is kept is then the versions
sent. `not_found` for a session the pod does not hold, `conflict` at a stale `epoch`. A pod
that gets no answer within two seconds runs the turn on what it holds. The plane's
`session.memory` push to a pod, as a save sends it: `{session_id, epoch, memory}`, every
document the session now reads, taken at the session's next turn; `admin.memory.nudge` sends
it again for one session.

#### Between the plane and a pod, for a session

Over the pod's control connection, as JSON-RPC: a push is a request the pod answers, a
notification is not answered, and the one the pod asks is marked so.

| method | sent | params | what the pod does |
| --- | --- | --- | --- |
| `session.activate` | push, when the plane places a session on the pod: created, woken, moved | `{session_id, epoch, team, owner_subject, profile, agent?, source?, usage_seq, entitlements, memory, bundle pin, terms, repository?, fork?, prompt?}`; `prompt` on the first activation only | starts the session's tree under that epoch and answers; refused, the plane releases what it held. Answered, the plane keeps `memory` as what the session holds (it is among the readers as `activated` until its first turn) and sends the `invite.changed` lines the session's log missed while no pod held it |
| `session.memory` | notification, at a save of a document the session reads, and at `admin.memory.nudge` | `{session_id, epoch, memory}`: every document the session now reads | gives them to the session, which reads them from its next turn |
| `session.memory.read` | asked by the pod, as each turn begins | `{session_id, documents, epoch?}`: what the session holds, each `{scope, name, version, hash}` | runs the turn on the `memory` the answer carries where `current` is false, else on what it holds; with no answer in two seconds, on what it holds |
| `acl.changed` | push, at a grant, an invitation made or changed, or one taken back | `{changes: [{session_id, subject, role}]}`; `role: null` for one taken back | updates its mirror of the session's access, which its next command from that person is checked against |
| `invite.changed` | push, at an invitation made or taken back while the pod holds the session, and at its next activation for one made while none did | `{session_id, type, invite: {subject, display_name?, role?, by, by_name?}}`, `type` `session_invited` or `session_uninvited` | writes the event of that type in the session's log |

A daemon exchanges its grant at `POST /auth/relay {grant}` → `{token, expires_at, subject,
device}`: a fifteen-minute token whose audience is `troupe-relay-laptop` and which names the
device, taken by `/v1/relay` for that device and by nothing else, neither `/rpc` nor a pod
nor a viewer's door. 401 for a grant the plane does not hold, one released, or one unused for
thirty days; 403 where the person is deactivated or a team of theirs forbids offering. `POST
/auth/relay/release {grant}` is always 204, and records `remote.release`.

The laptop's own half is the WebSocket at `/v1/relay`, which a daemon dials with that
token, or a plane token, and which a page that names an `Origin` cannot open: `initialize` with
`capabilities.device`, then `relay.sync {offers: [{session_id, workspace, share}]}` → `{offers:
[{session_id, shares}], refused}` (every other offer of that person's from that device is
dropped), `relay.offer {session_id, workspace, share, private}` → `{shares}`, `relay.withdraw
{session_id}`, and `auth.refresh`; the plane sends `relay.open {viewer, session_id, person,
role}`, `relay.frame {viewer, data}` (one protocol message, as text) and `relay.close
{viewer, reason}`, and the daemon sends `relay.frame` and `relay.close` back. `private` (and
the plane's own row of the session) marks a private session's offer; each `relay.offer` is
in the audit as `remote.offer` with the device, `private` and how many it is shared with,
and nothing a frame carries is written anywhere. An invitation into an offered private
session made or taken back rechecks its views at once; one whose person no longer holds it
closes with *Your invitation into this private session was taken back: you no longer steer
it.*

`session.register`, `session.presign`, `session.objects` and `session.assertion` answer
`not_found` with `reason: "erased"` for a session that is erased or `erasure_pending`: a
daemon still running it would otherwise seal into the erased prefix, or make a fresh key
where the destroyed one was.

### Private sessions

A private session belongs to a person, not a team. It runs on their own machine, is
sealed under `troupe/people/<name>/sessions/<id>`, and is never placed on a pod. The
plane's row carries `kind: "private"`, no `team`, no `profile` and no worker — sizes,
sequence numbers, hashes and a `device` name, and nothing else. A team admin does not see
it; a platform admin sees a count and a size.

**Invited into one** (Decision 949). A person the owner invites follows a private session
with keys of their own: its owner's daemon puts a copy of each generation of the session's
key in the invitee's slot, `troupe/people/<invitee>/invited/<session_id>/`, which any
person's credential may create in and only the invitee's may read, and the plane keeps the
paths. Taking the invitation back destroys those copies, and the owner's daemon seals what
follows under a new generation, `troupe/people/<name>/sessions/<session_id>.k<n>`, which only
the people still invited are given; the row's `key_version` is the generation sealed under
now, and `rekey_due` is true while a new one is owed. A segment is sealed under one
generation, and a reader holding several tries each: AES-GCM verifies under one only. An
erasure destroys the invitees' copies and then every generation, and is `erasure_pending`
until all are gone.

A session's JSON carries `kind` and, for a private one, the `device` that last sealed
it, and `bundle_version` — the configuration it was pinned to when it was created,
which does not move when a newer version is published. A session whose agent
definitions changed underneath it would be a different session halfway through.
 `sessions.list` takes `kind` (`team` or `private`) alongside its other filters, so one
list can show both and either can be asked for on its own. `kind` is not `visibility`:
`visibility` is who else on the team may see a session and defaults to `private`, so an
unshared team session has always been visibility-private and is not a private session.

A person-mode MCP server reaches its far side as the session's **owner**, fixed at
activation and recorded in `session_created`. The credential is in the key manager under
`troupe/people/<name>/mcp/<slot>`; the plane never holds it and cannot read it, and a
pod reads it with a token it exchanged for an assertion naming that person. `<name>` is
the person's name at the key manager, fixed when the plane first knew them and unchanged
when a switched `subject_claim` moves their subject (Decision 755); the plane's answer to
`kms.assertion` carries it as `key_manager.name`, and the pod reads under it rather than
under the owner it was told at activation. Where nobody
has connected, the tool answers a result the model can read —
`{"error": "not_connected", "server": …, "hint": …}` — and the session carries on.

`POST /auth/exchange` takes `{"client_id": "svc:<team>/<name>", "client_secret": …}` as
well as `{"id_token"}`, and answers the same plane token with `kind: "service"`, `team`
and `profiles` claims.

`POST /auth/breakglass` takes `{"token": …}`, the deployment's break-glass token, and
answers `{token, expires_at, subject}`: a plane token for the break-glass subject, carrying
`breakglass: true`, that is a platform admin in no team until it expires, with nothing to
refresh it; `expires_at` is ISO 8601, UTC, at most the fifteen minutes any plane token
lasts. It answers the `admin.*` methods and `me`, and every other method is `forbidden`. A wrong token is 403 `{"error": "refused"}`,
and both outcomes are audited as `admin.breakglass` with the caller's address. A plane
with no token configured answers 404 with no body, and `GET /.well-known/troupe` says
`breakglass: false` there and `true` where the door exists. `me` answers `breakglass:
true` for the token and `false` for everybody else, so a client can mark what it shows.

### Client versions

A plane holds, per component — `tui` (the terminal, `troupe`), `daemon`
(`troupe-daemon`) and `desktop` (the desktop app) — which versions of its clients it
serves (Decision 868): a `recommended` version, a `minimum`, and a `blocked` list.
Administrators change it with `admin.clients.put`; a plane with nothing set serves every
version. Versions are ordered as SemVer orders them, so `0.13.0-beta` comes before
`0.13.1-beta` and before `0.13.0`; a policy names versions as releases are numbered.

`/rpc` keeps no connection, so its `initialize` is a call like any other, and a client
makes it when it connects. The component is read from `client_info.name` — `troupe` and
`troupe-headless` are `tui`, `troupe-daemon` is `daemon`, `troupe-gui` is `desktop` — and
judged by `client_info.version`:

- **on a blocked version, or below `minimum`**: refused with `update_required`. The
  client says so in a sentence and does not go on; `data.reason` is that sentence, and
  `data.signed` the refusal signed by the plane's key as `update_required`, for an hour
  ([The plane's signing key](#the-planes-signing-key)):

  ```json
  {"code": -32016, "message": "update_required", "data": {
    "component": "tui", "version": "0.12.0-beta", "minimum": "0.13.0-beta",
    "recommended": "0.13.1-beta", "blocked": false, "run": "troupe update",
    "reason": "This plane needs troupe 0.13.0-beta or later, and this is 0.12.0-beta: run troupe update, which installs 0.13.1-beta.",
    "signed": {"algorithm": "ed25519", "fingerprint": "SHA256:...", "document": "...", "signature": "..."}}}
  ```

  A client that pinned the plane's key acts on the refusal only as that key signed it,
  for its own component and version: an unsigned one, one another key signed, or one
  for another version, is said as why and not acted on.

- **otherwise**: served, and the answer carries the policy with what it means for that
  version: `"client_update": {"component": "tui", "recommended": "0.13.1-beta",
  "minimum": "0.13.0-beta", "blocked": [], "action": "suggest"}`, where `action` is
  `suggest` below `recommended` and `none` at it or past it; and `"policy": {"revision":
  "<sha256 hex>"}`, a digest of what `me.client_versions` and `me.client_defaults` would
  say now, which moves when either does. It is no word of the plane's on anything: a
  client that asks again every little while fetches the signed answers only when it moved.

A client the plane cannot place — no `client_info`, or a name it does not know, as a
script's — is held to nothing and gets `client_update: null`. So is a client from before
this, which sends no `initialize` to `/rpc` at all: the policy reaches the clients that
ask. The version is the client's word; the refusal is a service to the person, telling
them what they need, and not a way to keep anybody out.

**The plane records which version each person's clients run** (#657). A client it served
is recorded per person and component: `client_info.version`, `client_info.platform` where
the client gives one (a short label such as `linux/x86_64`, at most 64 characters), when
that version was first seen from them and when they were last seen. One record per person
and component, moved on by each `initialize` and never a history; a refused client, one
the plane cannot place, and a service principal are not recorded, and a person's records
go with them. Nothing in a person's own answer changes: the records are for administrators,
whose `admin.clients.get` answers them beside the policy as `fleet`, and whose
`admin.clients.put` says how many clients a change holds (`affected`).

`troupe update`, signed in, asks `me.client_versions` and installs the `recommended`
version, never a blocked one and never one below `minimum`, moves backwards only when the
person names the version, and is still held to the release key: the plane can hold a
version back or name one, and cannot make a client install anything the key did not sign. The daemon makes the same `initialize` when a client
links it with a token (`identity.link`); refused, it asks the plane nothing more until the
next handshake, and `identity.get` carries the sentence as `update_required`.

**A policy changed on the plane reaches the clients already connected** (#657). While it
holds a token the daemon makes the handshake again every thirty seconds: its version is
judged again, and where `policy.revision` moved it fetches `me.client_defaults` and
`me.client_versions`, checked against the pinned key. A changed organisation's document is
kept, told to every client as `config.changed` (scope `org`, the keys that changed), and
given to every session running on the machine, which takes it as its next turn begins and
says so in a line (`config_note`, key `organisation`); a changed version policy is told as
`config.changed` with scope `versions`, `path` the plane's URL and the keys that changed,
and the desktop app asks again what to update to.

The desktop app makes it too, as `troupe-gui`, when it is signed in: at start and once a
day (Decision 874). Refused, it keeps to the sessions on its own computer and offers to
update itself, which is why `data.run` is `null` for it; served with `action: "suggest"`,
it offers the update quietly, as the terminal says it in a line. Its update is the
`desktop` component's `recommended` version from `me.client_versions`, held to the same
`minimum` and `blocked` list, and to the release key. The page hands the policy's `signed`
to the app's shell as it came, and the shell checks it itself against the key the daemon
pinned (`identity.get`'s `plane_key`) before it takes the version, the limits or
`release.url` from it; it takes no URL from the page.

Where releases are is the plane's too: `me.client_versions` names `release.url` (the
`client_release_url` setting), each release at `<url>/v<version>/` as GitHub lays them out,
or null for GitHub's. `troupe update` and the desktop app install from there. The plane can
serve them itself: `GET /downloads/v<version>/<file>` answers a short-lived presigned URL
(302) for a file in its object store under `releases/v<version>/`, and a bare 404 with no
body for anything else, whatever the policy says of the version: which versions are refused
is said only by the signed, signed-in `me.client_versions`. Anybody may fetch one, since the
release key's signature on the manifest is the check, as it is on GitHub, and no client
installs a version the policy it holds refuses. `admin.releases.mirror` copies a release
there from where releases are published, its manifest checked against the release keys
first; `admin.releases.list` says which are kept.

### The plane's signing key

A plane signs what it tells people's machines with an Ed25519 key of its own (#657), held
in OpenBao's transit engine where nothing can export it, and separate from the release
key. `GET /.well-known/troupe-signing-key` serves its public half, made on first use:

```json
{"algorithm": "ed25519", "public_key": "<base64 of 32 bytes>",
 "fingerprint": "SHA256:<unpadded base64 of its SHA-256>", "version": 1,
 "created_at": "2026-10-18T08:00:00Z"}
```

and `/.well-known/troupe` names it as `plane.signing_key`. A plane from before it has
neither, and signs nothing; its answers are taken as they always were, said in a line.

`me.client_versions`, `me.client_defaults` and `me.memory` carry `signed` beside their fields:

```json
"signed": {"algorithm": "ed25519", "fingerprint": "SHA256:...",
  "document": "{\"body\":{...},\"expires_at\":\"...\",\"kind\":\"client_versions\",\"plane\":\"https://troupe.example\",\"signed_at\":\"...\"}",
  "signature": "<base64 of 64 bytes>"}
```

`document` is the text that was signed: canonical JSON (section 4's rules) of `kind`
(`client_versions`, `client_defaults` or `memory`), `plane`, `signed_at`, `expires_at` (a week
after) and `body`, the answer. `initialize`'s `update_required` carries one in its `data` too,
of kind `update_required`, its body the refusal's fields, and `expires_at` an hour after.
`signature` is plain Ed25519 (RFC 8032) over its bytes. A
client checks the bytes it was sent, then parses them, and takes the body from there:

- **At sign-in** it pins the key the plane serves, per plane, as SSH pins a host key.
  The terminal and the daemon keep one file, `<state>/plane-keys.json`, and the desktop
  app reads the daemon's (`identity.get`).
- **Every signed answer** must be signed by the pinned key, as the kind asked for, and not
  past `expires_at`; once a key is pinned, an unsigned answer is refused too. A refusal is
  a sentence, and the answer is not acted on: `troupe update` goes on as without a plane,
  and the daemon keeps the organisation's document it had.
- **A changed key** is kept as offered and trusted for nothing until a person accepts its
  fingerprint: `troupe plane-key accept`, `identity.accept_plane_key`, or the desktop app.
  The console shows the key, and rotates it (`admin.signing.rotate`).
- **The kept copy** of the organisation's document carries the signature, and is checked
  whenever it is read: a copy changed on the machine is refused with a sentence. Past
  `expires_at` it still holds until a fresh one replaces it.

### Errors

`forbidden` with `data.required_role` when the caller's role is not enough, and
`not_found` for a team a `team_admin` may not see — because whether a team exists is
itself something a person who cannot see it should not learn.

`managed_by_gitops` with `data.kind` (`WorkerProfile` or `Trigger`), `data.name` (a
trigger's as `team/name`), `data.source` (the repository the deployment names, or `null`)
and `data.reason` when a write reaches something a repository holds: on a plane in gitops
mode, `admin.profile.put`, `admin.profile.delete`, `admin.trigger.put` and
`admin.trigger.delete`. The change is a commit to that repository. The attempt is in the
audit trail with `outcome: refused`.

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
| -32005 | `not_found` | `data.kind` with what was not found (`name`, `id`, `session_id` or `run_id`), or `data.session_id` or `data.reason` alone |
| -32006 | `conflict` | e.g. dirty worktree, watch already held |
| -32007 | `stale_version` | `data.session_id`, `data.reason` |
| -32008 | `capacity` | no room; `data.profile`, `data.max_sessions`, `data.reason` |
| -32009 | `resync_required` | also sent as a notification (§5) |
| -32010 | `unavailable` | a dependency is down; `data.reason`, sometimes `data.detail` |
| -32011 | `rate_limited` | reserved: no server answers it today |
| -32012 | `payload_too_large` | `data.limit` |
| -32013 | `consent_required` | `data.challenge`, `data.prompt`, `data.tools` |
| -32014 | `budget_exhausted` | the team has nothing left to reserve; `data.team`, `data.reason` |
| -32015 | `managed_by_gitops` | an admin write to what a repository holds (§9); `data.source` |
| -32016 | `update_required` | the plane does not serve this client's version: below its minimum, or blocked (§9, Client versions); `data.component`, `data.version`, `data.minimum`, `data.recommended`, `data.blocked`, `data.run`, and the sentence in `data.reason` |

A line that is not JSON, or not a JSON-RPC message, is answered with `parse_error` or
`invalid_request` (id `null`) and the connection goes on. A message over the limit
(`payload_too_large`), a request before `initialize`, and a binary WebSocket frame (closed
with 1003) end the connection.

---

## 11. Schemas and compatibility

Machine-readable JSON Schema for every message and event lives in
[`protocol/schema/v1/`](protocol/schema/v1/) and is committed to the repository. It is
generated from the same definitions the server uses, so it cannot drift from them. One
durable type the server writes is not among them yet: `agent_woken` (§4).

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
    "principal":{"subject":"local:me","kind":"user"}, …}}

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
← {"jsonrpc":"2.0","id":4,"result":{"accepted":true,"command_id":"c-3"}}
← … events: user_input, llm_request, llm_delta (ephemeral), llm_response …

→ {"jsonrpc":"2.0","id":5,"method":"approval.respond","params":{"command_id":"c-4",
    "session_id":"s-1","call_id":"call_1","decision":"allow"}}
← {"jsonrpc":"2.0","id":5,"result":{"accepted":true}}
```

---

## 13. Writing a client

1. Connect and send `initialize`. Keep the negotiated `scopes`.
2. `subscribe` to `fleet` for the session list, to `session:<id>` at `detail`, and to
   `presence:<id>` if it shows who else is there
   for one session.
3. Fold durable events into your view; render ephemerals as they arrive and expect
   to lose some.
4. Track the highest `seq` you have processed. On reconnect, re-subscribe with
   `from_seq` set to it.
5. Give every command a fresh `command_id`, and retry with the *same* one after a
   disconnect — it is a no-op if the server already saw it.
6. Ignore event types and fields you do not recognise.

---

## 14. Which protocol carries which boundary

Four protocols appear in Troupe and it is not obvious from any one of them why the other
three exist. This table is the answer, written once so that nobody has to infer it — and so
that the next integration is recognised as one of these four rather than invented as a
fifth.

Read the direction column first. Most of the confusion about MCP, ACP and A2A is that each
of them can run in either direction, and which direction it is running in decides everything
about what it may touch.

| protocol | direction | boundary it crosses | what it carries | where it is enforced |
| --- | --- | --- | --- | --- |
| **Troupe's own** | client → daemon or plane | a person and their session | everything in this document: subscribe, steer, approve, administer | scopes, §7 |
| **ACP** | editor → daemon | a person's editor and their session | the same session, reached the way an ACP client already knows how to reach one | the same scopes, on the same socket |
| **ACP** | session → a subprocess agent | the session and an agent somebody else wrote | a bundle entry naming an ACP agent, served through the mount table | entitlements, and the mount table |
| **MCP** | session → a server | the session and a tool somebody else runs | tools the model may call, as the profile or as the person | entitlements, egress policy, credential slots |
| **MCP** | admin client → plane | an administrator and the admin surface | the methods of §9, as tools | the same admin roles, §9 |
| **A2A** | another agent → a profile | an agent framework and a whole profile | a task in, an answer out, streamed over SSE when asked; the facade opens a session for the task and follows its events, and an approval it waits on is the task's `input-required` | the facade exchanges the caller's credential and calls `/rpc` as that principal |

### The rules that fall out of it

**A protocol is a way in, never a second set of permissions.** Every row is enforced by the
mechanism that was already there: ACP on the daemon socket gets the scopes that socket gives,
admin MCP gets the admin roles, the A2A facade holds no credential of its own and acts as
whoever called it. There is no row where speaking a different protocol grants anything, and a
proposed integration that would need one is the signal to stop.

**Inbound protocols reach a session; they do not become one.** An ACP client's session *is* a
Troupe session — created by `session.create`, subscribed at `detail`, ended when the session
ends. It is not a parallel object with its own lifetime, which is what makes a transcript the
same whoever was watching.

**Outbound protocols are entitlements.** An MCP server and an ACP agent are both *things the
bundle names and the grant narrows*. Neither is configuration a session can acquire at
runtime, and both go through the mount table, which is what makes a subprocess agent no more
dangerous than a tool call.

**The mount table is the only filesystem.** ACP defines filesystem and terminal operations,
and they map onto the mounts a session already has rather than onto the disk. An ACP agent
that asked for a path outside them is refused exactly as a tool would be — the refusal is not
special-cased for ACP, because the check is not in the ACP layer.

### Where each one is not used

* **ACP does not administer.** There is no ACP route to §9; an editor that wants to publish a
  bundle uses the admin surface like anything else.
* **MCP does not steer a session.** Tools are called *by* a model inside a session. A person
  driving a session uses this protocol, and the admin MCP server exposes administration
  rather than conversation.
* **A2A does not attach a person.** The facade follows the session and turns what happens
  into the task's updates; the calling agent sees a task, never the session's events, and
  answers an approval only as the task's next message. Somebody who wants to watch it
  happening wants this protocol.
