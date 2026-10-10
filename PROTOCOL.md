# The Troupe protocol, version 1

This document is complete on its own. Everything needed to write a Troupe client is
here; no Elixir is involved — and every Troupe client is written this way, because none
of them lives in the repository that implements the server. A reference client in ~220
lines of Python standard library sits in that repository as a test fixture, at
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
`$HOME/.troupe/run/daemon.sock` when `XDG_RUNTIME_DIR` is unset.

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
port the kernel chose, and publishes it as a second entry in the same discovery file:

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

`params.client_info.name` says which client this is, and a daemon names the sessions a
connection creates or wakes to the model provider by it (Decision 787): `troupe` is the
terminal UI, `troupe-headless` its headless run, `troupe-gui` the desktop app, and any
other name is `other`. The name itself never leaves the daemon.

The response:

```json
{"jsonrpc": "2.0", "id": 1, "result": {
  "protocol_version": "1",
  "server_info": {"name": "troupe-daemon", "version": "0.2.0", "instance_id": "kP3u_2fQ8xA"},
  "capabilities": {"worktrees": true, "branches": true, "watch": true, "remote": false,
                   "private_sessions": true},
  "principal": {"subject": "local:martin", "display_name": "martin", "kind": "user"},
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
| `watch` | `watch.set` is served, and `fs_changed` events arrive |
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

`kind` is `text` (the answer as it arrives), `reasoning` (the model's thinking, shown
apart from the answer and never part of `llm_response`'s prose), `tool_use_start` (`id`,
`name`) or `tool_input` (`fragment`). Every completed model message also lands as a
durable `llm_response`, so dropping deltas loses nothing but smoothness.

### Event types

Durable:

| type | `data` |
| --- | --- |
| `session_created` | `workspace`, `profile`, `visibility`, `bundle_version`, `kind` (`team`/`local`), `owner`, `origin`, `parent` |
| `agent_started` | `profile`, `mode`, `bundle_version` |
| `agent_restarted` | `replayed_events` |
| `user_input` | `source` (`user`/`watch`/`tui_todo_edit`/`loop`/`harness`/`shell` — `loop` is an iteration of `session.loop.start`, `harness` the note the harness gives a model whose reply was cut or empty, or that keeps calling a tool that fails, and `shell` what the agent was given of the person's own commands, each of which a client draws from its `user_shell` instead), `text`, `command_id` — the send it was taken from, as its `input_accepted` names it; absent from a `harness` or `shell` note, which nobody sent, and from a log written before 0.5.2 |
| `user_shell` | `run_id`, `command`, `output`, `ended`, `agent`, `exit_status`, `reason`, `timeout_ms`, `duration_ms`, `command_id` — a command the person ran with `shell.run`, written by the root agent under their actor when it ended. `output` is its combined stdout and stderr, the tail capped at `tool_output_limit` with the `read_output` marker when it was cut; `ended` is `exited` (with `exit_status`), `timeout`, `killed` (`shell.cancel`) or `failed` (it could not start, `reason` says why); `agent: false` is one kept from the agent (Decision 813) |
| `input_queued` | `command_id`, `author`, `text` |
| `input_accepted` | `command_id`, `author` |
| `llm_request` | `model`, `message_count`, `tools`, `profile`, `prompt_bytes` — what the prompt was made of (see below); `system_changed`, `tools_changed`, `turn_context` — what changed in front of what the agent had sent (see below) |
| `llm_response` | `message` (`role`, `content`: blocks of type `text`, `tool_use`, `tool_result` or `reasoning` — the last is the model's thinking, `provider`-bound, replayed only to the provider that made it and carried by `Message.text` nowhere), `usage` (`input_tokens`, `cache_read`, `cache_write`, `output_tokens` — disjoint, so the first three sum to the prompt's length), `stop_reason`, `model`, `gateway`; `thinking_resent`, `thinking_dropped` — what became of the thinking the call handed back (see below) |
| `llm_error` | `reason` — a sentence a person can act on: a blown context window, rejected credentials, an unknown model, a rate limit the backoff outlasted, with the provider's words in brackets; `note` — a root's, the words its conversation was given about the failure, which a replay puts back; `stopped` — the call the agent gave up on when it did not answer within `llm_timeout_ms`, and stopped (see below) |
| `truncated` | `reason` (`max_tokens`: the output cap cut the reply; `empty`: it had neither text nor a tool call), then one of `note` (the model was asked again), `calls` (tool calls cut mid-argument, answered with an error and not run) or `final: true` (asked once already; the agent ends `output_truncated` or `empty_reply`) |
| `tool_call_started` | `call_id`, `name`, `args`, `identity`, `principal` |
| `tool_call_completed` | `call_id`, `name`, `ok`, `content`; `exit_status` or `timed_out` — how a `shell` call's command ended: `exit_status` when it exited, `timed_out: true` when its timeout killed it. Absent on every other tool and on a `shell` call that ran no command. `ok` is true for a command that ran, whatever its status, and the model reads `content` alone, which still ends in `[exit status N]` for a non-zero exit, so a reader that tells a failing command from a passing one reads `exit_status` rather than the text |
| `tool_results` | `results` |
| `todo_updated` | `items`, `source` |
| `profile_switched` | `from`, `to`; and `layer` (`builtin`, `bundle`, `user` or `project`, where the new agent was read from), `tools_added` and `tools_removed` (the tool names the new agent holds that the old did not, and the other way round) and the switch's `command_id`, under the actor who switched it (Decision 841) |
| `instructions_loaded` | `budget`, `used`, `searched`, `files` — what the agent's system prompt was read from at this turn: the instruction files (`AGENTS.md`, `.agents/AGENTS.md` and `.troupe/rules`, and the other tools' files listed as not read) and the project brief, as `context.get` lists them, each with `scope`, `path`, `size`, `chars`, `budget`, `share`, `status`, `reason`, `trimmed`, `skipped`, `imported_by`, `unfollowed`, `rule`, `applies` and `hash`. Read as the turn began and held for the rest of it. Written when the set of files, or what one of them holds, changed since the agent's last turn, so a quiet log means the same files were read again |
| `goal_set` | `text`, `command_id` — the session's goal, written by the root agent under the actor who set it (`session.goal.set`) |
| `goal_cleared` | `command_id` |
| `loop_started` | `loop_id` (`loop-<n>`), `max_iterations`, `max_failures`, `goal`, `command_id` — a loop towards the goal, written by the session under the actor who started it (`session.loop.start`) |
| `loop_iteration_started` | `loop_id`, `iteration`, `command_id` — the command id the iteration's input carries, which the root's `input_accepted` echoes |
| `loop_iteration_finished` | `loop_id`, `iteration`, `outcome` (`continue`: the turn ended and the goal is not met; `complete`: the agent called `goal_complete`; `failed`: the turn ended in an error; `stopped`: the loop stopped around it), `detail` |
| `loop_stopped` | `loop_id`, `reason` (`goal_complete`, `max_iterations`, `failures`, `budget`, `requested`, `cancelled`, `goal_cleared`, `interrupted`, `agent_done`), `iterations`, `detail`, `summary` (the evidence `goal_complete` gave), `command_id` (the `session.loop.stop` that asked) |
| `delegation_started` | `call_id`, `agent`, `child_path` (the parent's path and `<agent>#<n>`; `n` goes on counting across restarts, so a path names one child), `task`. The child writes its `agent_done` before the parent's `tool_call_completed` for the call, and is stopped once the parent has its result: from then on it is only its log. A delegation a restart closes as interrupted or takes up again leaves a child nothing starts again, so the restart closes that child's part of the log, and the part of each agent under it: a `tool_call_completed` for each call still open, then `agent_done` with `reason: interrupted` |
| `compacted` | `summary`, `reason` (`threshold`, or `context_overflow` when the provider refused the prompt and the turn is sent again after compacting), and the summariser's own model call as `llm_request` and `llm_response` say one: `model`, `prompt_bytes`, `usage`, `gateway` (absent from a log written before 0.8.2) |
| `budget_exhausted` | `limit` |
| `budget_ask_started` | `call_id` (`budget-<n>`), `dimension`, `used`, `limit`, `detail` — the budget is spent and the agent asks before its next model call; the question itself is a `question_asked` under the same `call_id`, answered with `question.answer`. Its `question` says what the limit protects against, what the session has used and spent, and what the raise on offer would cost; its `options` are sizes and scopes — `+25 turns this run`, `+50 turns this session`, `no limit this session`, `+50 turns this workspace`, `stop` — and a typed amount (`50`, `+50 turns`, `+50k tokens`, `+15 min`, with `run`, `session` or `workspace` after it) is an answer too (Decision 699) |
| `budget_ask_answered` | `call_id`, `decision` (`allow`: one more slice of the original size, `grant` says how much; `always`: the limit the question was about, named in `lifted` — `max_turns`, `max_input_tokens`, `max_output_tokens` or `wall_clock` — is lifted for this agent and its subagents, and the others still ask; `raise`: `limit` goes up by `amount` — turns, tokens or milliseconds — for `scope` `run` (given back at the turn's end), `session` or `workspace`, the last also written to the project's file named in `path`, or `note` says why it was not; `unclear`: the answer could not be read, `note` says why, and the question is asked again under the next id; `deny`: `budget_exhausted` follows). An `always` without `lifted`, from a log written before Decision 687, lifted the limit its `budget_ask_started` named |
| `budget_warning` | `dimension`, `used`, `limit`, `fraction`, `detail` — once per dimension per agent, at `budget_warn_at` |
| `tool_failures_ask_started` | `call_id` (`failures-<n>`), `tool`, `failures`, `detail` — one tool has failed `failures` times in a row and the agent asks before its next model call whether the turn goes on; the question itself is a `question_asked` under the same `call_id`, with options `stop` / `continue`, answered with `question.answer` |
| `tool_failures_ask_answered` | `call_id`, `decision` (`continue`: the tool's count starts again; `stop`: a `user_input` from `harness` saying why, then `turn_ended` with `reason: tool_failures`) |
| `agent_done` | `reason` (`finished`, `budget_exhausted`, `output_truncated`, `empty_reply`, `refused`, `tool_failures`, `llm_error` — a subagent whose model request failed, after the `llm_error` that says why; a root rests instead; `interrupted` — a subagent a restart took down, written by the restart, see `delegation_started`), `summary`, `limit`, `turn` — what the agent's last turn cost, a subagent's whole task (see below); absent from one a restart wrote |

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
| `agent_woken` | `from`, `source` — a root agent that had finished took new input as a turn |
| `input_after_done` | `source` — input a done agent did not take (its budget is spent) |
| `cancelled` | `turn` — what the cancelled turn had cost (see below); `stopped` — the model call the cancel stopped, when one was in flight (see below) |
| `turn_ended` | `reason` — the agent's turn is over and it waits for input: the model answered without asking for a tool, or a root's request failed and the `llm_error` just before says why. The durable twin of `agent_state` reaching `idle`, for a client that was not listening when it happened; a cancelled turn ends with `cancelled` instead, and a finished agent with `agent_done`. `reason` is there only when the harness ended the turn: `tool_failures`, a tool kept failing and the answer to `tool_failures_ask_started` was `stop`; `agent_failed`, the root agent crashed as often as it may be restarted, `detail` says what it raised, and the session stops after it, to come back dormant (Decision 727). Neither turn is taken up again by a restart. `turn` — what the turn cost (see below); absent from an `agent_failed` one |
| `approval_requested` | `call_id`, `tool`, `args`, `agent_path` — open until its `approval_decided`, its call's `tool_call_completed` (a cancel, or a tool that timed out waiting, ends the call with no decision), or a `cancelled` on the agent that asked or on one above it |
| `approval_decided` | `call_id`, `tool`, `decision`, `actor` |
| `approval_resolved` | `call_id`, `resolved_by` |
| `question_asked` | `call_id`, `agent_path`, `question`, `options` (`[{label, description}]`), `multiple`, `preview` — the agent's `ask_user`; answered with `question.answer`. `preview`, where there is one, is text the question is about, for a client to show as it is beneath it: the prompt a workspace's command would send, when it asks before it is first sent (`commands.run`). Open until its `question_answered`, its call's `tool_call_completed` (a cancel, or a tool that timed out waiting, ends the call with no answer), or a `cancelled` on the agent that asked or on one above it. The budget's and the failure guard's question have no call; each also ends with its `budget_ask_answered` or `tool_failures_ask_answered`, the only word there is when nobody is there to ask, and one a cancel ended is asked again at the next turn with another `question_asked` under the same `call_id` |
| `question_answered` | `call_id`, `text`, `actor` |
| `command_declined` | `name`, `reason`, `command_id` — a workspace's command that asked before it was first sent (see `commands.run`) and was not: `reason` says why and how to run it later, and `command_id` is the `commands.run` that asked |
| `onboarded` | `target` (`repo`: the workspace's `.troupe/`; `workspace`: an `AGENTS.md` of the workspace's, Decision 827; `user`: the person's config directory), `path` (from that root), `file` (as a person reads it), `source` (the other tool's file it was made from: relative to the workspace, or `~/`), `source_hash` (the sha256 of that file, lowercase hex), `action` (`created` or `replaced`) — a file the `onboard_write` tool wrote, which asks first (Decision 823); the file records the same provenance itself, or `.troupe/onboarded.json` does for it |
| `onboarding_suggested` | `reasons`, `message`, `workspace`, `command`, `proposals`, `onboarding_version`, `onboarded_version`, `survey_version`, `brief_version`, `due`, `brief_due`, `counts` — what onboarding would do in the session's workspace, said at every start while onboarding is due or the brief is outdated and the person has not said no for that version (Decisions 827 and 835); nothing was written. `due` is onboarding's (`first`, `outdated` or `none`) and `brief_due` the brief's (`first`, `stale`, `outdated` or `none`), as `onboard.plan` has them; `counts` is the workspace's files a client would ask about (`files`, `write`, `create_agents_md`), and `onboard.plan` lists them. `reasons` holds `first` (other tools' files are there and nothing is onboarded: `proposals` counts what `troupe onboard` would propose by kind, `instructions`, `rules`, `agents`, `commands`, `skills`, `workflows`, `mcp`), `outdated` (the workspace was onboarded under `onboarded_version` of the onboarding rules, older than this build's `onboarding_version`) and `brief` (the brief was written by `brief_version` of the librarian's survey, older than `survey_version`). `message` says all of it in one line for a client to show as it is; `command` is what to run. Not on a pod |
| `session_dormant` | `last_seq` |
| `session_activated` | `epoch`, `pod` |
| `session_resumed` | `dormant_ms`, `moved` |
| `trigger_fired` | `source`, `idempotency_key`, `principal`, `revision`, `payload_digest` |
| `files_skipped` | `files` — the agent, skill, command and workflow files a session found at a start and did not read, each `{kind, name, path, reason}`: on a pod, a working copy's file of a name its bundle has or a built-in agent's, which those beat unless the profile sets `repositoryOverridesBundle`; in a git worktree, one the main checkout has not committed (Decision 826); a workspace's `.troupe/` file, or directory, that is a link out of it, a skill whose `SKILL.md` can't be read, and what a workspace's `skills.json` links from outside the repository while the workspace is not trusted (Decision 829). A directory not looked into has a null `name`. Written when the list differs from the one the log last recorded, so an empty list says the files went away |
| `fs_changed` | `path`, `hash`, `size` |
| `acl_granted` / `acl_revoked` | `subject`, `role` |

Ephemeral: `llm_delta`, `progress`, `presence`, `summary_diff`, and `shell_started` and
`shell_output` while a person's command runs (`shell.run`).

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

Neither key is present in events written before this release. A reader folding an old
log gets the tokens and no cost, which is what was true.

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
it answered: one still streaming when `llm_timeout_ms` ran out, or one a cancel stopped
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
the session's turn context, with `system_prompt: stable`: the sections it carried, of
`instructions`, `goal` and `task_list`. On `llm_response`, `thinking_resent: true` says the
provider refused the thinking the call handed back as bound to another conversation and
the call was sent once more without it (Decision 805), and `thinking_dropped` how many
thinking blocks Anthropic's thinking-binding beta dropped instead, with
`thinking_binding: drop_block`; each is absent when nothing happened. None of the five is
in events written before 0.9.1.

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
  archived, erased — for every session the principal can see. `fleet` ignores
  `from_seq`.
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

Every command takes a client-generated **`command_id`**: a string unique per
connection lifetime (a UUID or `c-<counter>` is fine).

**The response is an acknowledgement, not the effect.** `input.send` returns
"accepted", not the model's answer. Effects arrive as events carrying the
originating `command_id`, which is how a client reconciles an optimistic render.

**Replaying a `command_id` is a no-op** that returns the original acknowledgement.
This makes every command safe to retry after a disconnect.

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
 "prompt": "fix the test", "visibility": "private", "worktree": "auto",
 "parent": "s-3a", "config": {"auto_approve": false, "watch": true}}
```
→ `{"session_id": "s-9f", "workspace": "/home/me/project", "worktree": null, "branch": null,
"parent": "s-3a"}`

`worktree`: `"auto"` (default) creates a git worktree on `troupe/<slug>` when the
workspace already has a live session; `"never"` reuses the directory; `"always"`
always branches.

`workflow`: run the prompt as a named **workflow**: the step list at
`<workspace>/.troupe/workflows/<name>.json` (or the built-in `default` pipeline) is
rendered around the prompt as the plan the `workflow` agent starts from, and `profile`
defaults to `workflow`. `workflows.list {workspace}` says which names exist. A workflow
is meant for a worktree of its own (`worktree: "always"`), since its subagents write.

`parent`: the session this one is a **branch** of — a second agent a person started
from the first one's screen. The daemon records it in `session_created`, returns it in
every listing, and refuses an id it does not know (`invalid_params`, field `parent`).
It changes nothing about how the session runs: a branch is a session (Decision 646).
A client that shows a workspace's branches together groups by `parent`; the parent's
agent reads a finished branch's summary with the `read_branch` tool. Servers that do
this say `branches: true` at `initialize`.

`config` carries the session settings a client may choose, and only those:
`auto_approve`, `watch`, `profile`, `full_send` (no `budget_warning`s). Everything else in the configuration — where state
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
"last_active_at", "pinned", "kind", "sync", "device"}]}`

`filter.parent` selects the branches of one session.

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

#### `session.archive` → `{"session_id"}`; makes a dormant session with no local cache.

#### `session.pin` / `session.unpin` → exempt from retention.

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

#### `turn.cancel` → `{"command_id", "session_id"}`. Valid from any state.

Each tool call the cancel stops is closed before `cancelled` is written: a
`tool_call_completed` with `ok: false`, then the turn's `tool_results`. A restart takes
up nothing a cancel stopped: no call runs again, no approval is asked for again, and no
model call is made for the cancelled turn.

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

#### `shell.cancel` → `{"command_id", "session_id", "run_id"}`

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
from its prose: on the loop's turns, and only there, the agent is offered
`goal_complete {summary}`, and an iteration in which it completes that call ends the
loop with reason `goal_complete`. An iteration that ends without one is followed by
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
can check that the file it read is the file the event announced. Reading a directory,
or a file larger than the server's cap, is `invalid_params`.

#### `fs.upload`
```json
{"command_id": "c-9", "session_id": "s-9f", "path": "notes.md", "content": "…"}
```
→ `{"path", "bytes"}`: the path relative to the workspace, and how many bytes were
written.

Needs `control`: putting a file into a workspace is steering the session. The write is
recorded as an `fs_changed` event, carrying the file's `hash` and `size`, whose actor is
the client that uploaded it, not the session.

#### `agents.list`
```json
{"workspace": "/home/me/project"}
```
→ `{"agents": [{"name", "description", "source", "notes", "layer", "model", "tool_count",
"read_only", "max_turns", "worktree", "available", "reason"}], "skipped": [{"name", "path",
"reason"}]}` — the primary agents a session in that
workspace may be created with, resolved as `session.create` resolves them (built-ins, the
machine's `agents/`, the project's `.troupe/agents/`). `source` is `builtin`, `global`
or `project`. A worker answers from its bundle instead, so a client offers exactly what
`profile` may name wherever the session will run. `skipped` is each agent file found and
not read, with why: one that is a link out of the workspace (`not read: outside the
workspace`; a `.troupe/agents` linked out whole is one entry with a null `name`,
Decision 829), in a git worktree one the main checkout has not committed, or one that does
not parse, with what is wrong in words (`not read: mode must be primary or subagent, not
"main"`, Decision 841), which the session's `files_skipped` carries too. Additive.

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

#### `agents.get`, `agents.validate`, `agents.put`, `agents.delete`, and `agents.changed`

An agent read whole, checked, written and taken away (#503, Decision 841). Both clients
manage one set through these and never write the directories themselves, so the checks
and the choice of layer happen in one place. Reading and checking answer on a daemon and
on a worker; writing is the daemon's, like `mcp.*` (Decision 700), and on a pod
`agents.put` and `agents.delete` are `forbidden` with `reason` "On a pod the agents come
from the profile's bundle and are read-only here: change them in the console".

```json
{"name": "plan", "workspace": "/home/me/project"}
```
`agents.get` (`observe`; `workspace` or `session_id`, or neither for the person's own and
the built-ins) → one definition, as the session would run it: every key of an
`agents.list` row, plus `mode` (`primary` or `subagent`), `tools` (`"all"` or the list),
`permissions` (`{"<tool>": "auto"|"ask"|"deny"}`), `budget_share`, `skills` (`"all"` or
the list), `prompt` (the instruction, the file's body), `path` (the file, `null` for a
bundle's ACP agent), `text` (the file as it is on disk, frontmatter and all, for an
editor), `editable` and `editable_reason` (`null` when editable; otherwise a sentence: a
built-in is changed by a copy in a scope, a bundle's agent in the console, and on a pod
none here), `also` (`[{"layer", "path"}]`, the files of the same name in lower layers this
one hides, nearest first: what answers once this one is taken away) and `running`
(`[{"session_id", "parent"}]`, with a `session_id`: the windows of that session's family,
the session, its branches and, for a branch, the session it came from and its other
branches, that run this agent now; empty without one). With a `session_id` the
definitions are that session's (on a pod its bundle's), read again from their files as a
switch would read them. A name nothing defines is `not_found` with `kind: "agent"`.

```json
{"source": "---\nmode: primary\n---\nYou review.\n", "name": "review", "workspace": "/home/me/project"}
```
`agents.validate` (`observe`) → `{"ok": false, "errors": [{"field", "message"}],
"warnings": [{"field", "message"}]}`, writing nothing. `field` is a frontmatter key
(`mode`, `tools`, `model`, …), `permissions.<tool>` for one permission, `frontmatter`
when it is not YAML, `name`, or `prompt` and `description` for the warnings. Errors: a key
no agent has (the keys are `description`, `mode`, `model`, `tools`, `permissions`,
`max_turns`, `budget_share`, `skills` and `override`, and onboarding's `imported_*`);
`mode` missing or not `primary`/`subagent`; `tools` or `skills` not `"all"` or a list; a
tool that does not exist (with the nearest that do); a permission not `auto`, `ask` or
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
`args` (`{"name", "required", "kind"}`, where `kind` is `window`, `file` or `text`, for
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
and all, for a palette to show before it runs (Decision 814). A name a
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
"Conventions", "Notes"], "text": "...", "refresh_due": false, "refresh_held_until": null}`

The **project brief**: what earlier agents learned about the repository, read into
every agent's system prompt and written by the `remember` tool and the `librarian`
agent. `status` is `absent` (no facts), `stale` (never built, older than
`memory_max_age_days`, or a command or convention it holds rests on a file that changed or
went since it was last checked, Decision 838), `fresh` or `disabled` (`memory: false` in the workspace
config). A `librarian`'s run that ends as it meant to builds it, whether or not it
rewrote any of it.
One brief per repository: a worktree's is the main checkout's. `refresh_due` is whether
a client should start a `librarian` session on the workspace now, which is what
`memory_auto_refresh` asks of it: the workspace is in a git repository (never true in a
directory none holds, such as a home directory), the brief is `absent` or `stale`, and no librarian has
started on it in the last `memory_max_age_days` without its being built since. A
librarian's run that failed, was cancelled or wrote nothing is tried again that much
later, not in every new session; `refresh_held_until` is when (or `null`), for a
client to say why it started none. `memory.forget` forgets that try with the brief.

#### `memory.forget` → `{"command_id", "workspace"}` deletes the brief. `admin`.

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
null, "version": 1}, "refusal": null}`

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
machine a worker runs on onboarding is never due, and `refusal` is the sentence saying it
runs on the person's own machine.

#### `onboard.apply` → `{"workspace", "ids": [...]}` or `{"workspace", "all": true}` (`command_id` optional)
→ `{"written": [{"id", "shown", "action"}], "refused": [{"id", "reason"}]}`. Writes the
files named, or with `all` every one whose `question` is `write` (an `AGENTS.md` that is not
there is written only when its id is named), each with its provenance (Decision 823), and
never over a file that changed since it was shown. `action` is `created` or `replaced`; an
id that names no file the plan holds now is refused with a sentence. Once a call has
answered every file the plan held, the workspace is recorded as onboarded under this
build's rules. `admin`: it writes into the repository and into the person's config
directory.

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
"unfollowed": [{"import": "docs/gone.md", "reason": "missing"}], "hash": "sha256:…"},
{"scope": "root", "path": "/home/me/project/CLAUDE.md", "size": 0, "chars": 0,
"budget": 16000, "share": 0.0, "status": "skipped",
"reason": "not read: run troupe onboard", "trimmed": 0, "skipped": [],
"imported_by": null, "unfollowed": [], "hash": null},
{"scope": "brief", "path": "/home/me/project/.troupe/memory.md",
"size": 0, "chars": 0, "budget": 6000, "share": 0.0, "status": "absent", "reason": null,
"trimmed": 0, "skipped": [], "imported_by": null, "unfollowed": [], "hash": null}]}`

The **provenance of the prompt**: every file the session's next system prompt is read
from, in the order it is read — the person's own `<config>/AGENTS.md` (`user`), the
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
at the repository root, and Cursor's root `.cursorrules` and `.cursor/rules/*.mdc` are
each listed after the directory's own file as `skipped`, so nobody debugs a file that was
never loaded. Copilot reads its file at the repository root only, so one in any other
directory is listed as `skipped` with a reason of its own (Decision 806). `skipped` on a
file is always empty now that no other name stands for `AGENTS.md`, kept for the clients
that read it. An `.agents/AGENTS.md` in the root or one of those directories (Decision
822) comes right before that directory's file, in its scope.
`reason` says in words why a file is left out, the same words `/context` prints, and is
null for a file that reached the prompt and for a brief `absent` or `disabled`: `not
read: run troupe onboard`, `not read: outside the repository` (`outside the config
directory` for the person's own), `not read: permission denied` (or another reason the
system gave), `not read: Copilot's file counts only at the root`, or `left out: the
budget was spent on nearer files`.
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

#### `config.get`, `config.models`, `config.set`, `config.import`, and `config.changed`

The machine's own settings — the provider, key and models every local session starts
from, and every other key of `config.yaml` — for a settings screen, so the desktop app and
the terminal UI show and change the same settings (#57). **The daemon's only**: a worker
answers `method_not_found`, because a pod's provider is its profile's business — or
`forbidden` to a token for one session, like every method not about its session (§7).
They edit `config.yaml` at the scopes of the configuration ladder: the user's file in the
daemon's config directory (`user`), a workspace's `.troupe/config.yaml` (`project`) and its
git-ignored `.troupe/config.local.yaml` (`local`). A client names a scope and never a
path, because the daemon is the process whose environment decides which file a session
reads. There is no second settings file.

```json
{"workspace": "/home/me/project"}
```
`config.get` (`observe`; `workspace` optional) → `{"config_dir", "path", "exists",
"provider", "base_url", "auth", "api_key_set", "api_key_source", "models": {"default",
"cheap", "expensive"}, "overrides": [{"source", "detail"}], "workspace", "trusted",
"files", "keys", "warnings", "errors"}`. The first fields are what the user's **file**
says, since that is what the model panel's save changes. The key is never in the answer:
`api_key_set` says whether one is in force and `api_key_source` where from (`file`, `env`
or null; a daemon before Decision 828 also said `opencode`). `overrides` names what beats
the file anyway: a project's `.troupe/config.yaml` (only when `workspace` is given) or a
`TROUPE_*` variable; opencode's settings beat nothing, being copied in (`config.import`)
and never read for a session. `config_dir` and `path` are written
as a person on the daemon's platform writes them, for a screen to print.

`keys` is every key the schema knows (`protocol/schema/config/v1.json`), as a session in
`workspace` would read it (`troupe config --explain`): `{"key", "value", "layer",
"source", "default", "scopes", "secret", "label", "doc"}`. `layer` is the one that set the
value in effect — `default`, `user`, `project`, `local`, `env` or `cli` — and
`source` its file or variable. A secret's `value` is `****`, or the `{env:VAR}` a file
wrote when the variable is not set; never the secret. `scopes` are the scopes `config.set`
writes the key to here: only `user` without a workspace, for the trust list, and for a key
marked trusted while the workspace is not; none for `version` and `$schema`. `label` is
the name a settings page shows the key by and `doc` its help, the same in both clients and
in the generated reference. `files` is each scope's file, `{"scope", "path", "exists"}`;
`trusted` whether the workspace is; `warnings` what loading warned about. A file that is
refused leaves `keys` empty and says why in `errors`. These fields were added for #57; a
daemon from before answers without them, and a client that finds no `keys` sets no single
key (below).

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
that it does), `version` and `$schema`, which the writer keeps, a value the loader would
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
A client reads `config.get` again for the values. A file edited by hand is not announced:
the daemon reads the files when a session starts and at every `config.get`, so nothing
of its own is stale, and a screen sees the edit the next time it asks.

```json
{"command_id": "c-13", "from": "opencode"}
```
`config.import` (`admin`) → the `config.get` answer after the write, plus `"imported":
{"from", "providers", "kept", "default"}`. Copies opencode's providers into the file's
`providers:` block (type, base URL, auth style, models, and the key as opencode has it
written: an `{env:VAR}` stays a reference, a literal key is copied), once: a session never
reads opencode's config (Decision 828). A provider the file already names is kept as it is
and listed under `kept`; opencode's default model becomes `models.default` only when the file
has none. `from` is `opencode`, the only source; with no opencode providers the call fails
with `invalid_params`. Nothing is written when nothing would change.

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
"done"}], "answers", "detected", "key_storage", "offered", "suggested", "check",
"suggested_prompt", "daemon", "session"}`. `needed` says whether a client should offer the
questions: nothing recorded, no `config.yaml`, and no model that can be asked.
`completed` is `null` or `{"completed_at", "choice", "subject"}`, recorded once for every
client in the daemon's state directory. `step` is the step to answer next — `where`,
`provider`, `key`, `models`, `workspace`, `daemon`, `finish` — and `steps` the ones this path
takes, since a plane finishes at once and reused settings skip the key and the models.
`daemon` says whether the daemon starts when this user logs in (Decision 762):
`{"at_login", "kind": "startup_folder" | "launch_agent" | "systemd" | "autostart",
"path", "command"}`, the entry's file and the `troupe-daemon` it starts, `command` being
`null` when there is none to start.
`detected` is what is already here: `env` (which of `ANTHROPIC_API_KEY` and
`OPENAI_API_KEY` are set, names only), `opencode` (`path`, `providers`, `default`),
`config` (the file, as `config.get` reports it, plus `usable`) and `plane` (`url`,
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
| `provider` | `{"provider": "anthropic" \| "openai", "kind"?: "anthropic" \| "openai" \| "gateway" \| "litellm", "base_url"?, "auth"?}`, or `{"reuse": "opencode" \| "config"}` | a gateway and a LiteLLM proxy are `openai` with their URL; `reuse` copies opencode's providers in as `config.import` does, or keeps a `config.yaml` that works, and goes to `workspace` |
| `key` | `{"api_key"}`, `{"env": "VAR"}` (kept as `{env:VAR}`) or `{}` for a gateway that wants none | checked with a real request, the provider's model listing: `check` is `{"state": "ok" \| "refused" \| "unknown", "reason"}`. Refused stays on `key`; `ok` fills `offered` (`{"id", "context", "max_output", "input", "output"}`, prices per million tokens) and `suggested` (`{"default", "cheap"}`, a safe answer); `unknown` goes on with nothing listed |
| `models` | `{"default", "cheap"?}` | writes the provider, the key and the models into the user's `config.yaml` |
| `workspace` | `{"workspace", "approvals": "ask" \| "auto"}` | the first project directory, which must exist; writes `auto_approve`. `ask` is the default |
| `daemon` | `{"at_login": true \| false}` | `true` writes the platform's login entry, which starts `troupe-daemon run` at the next login and keeps it up; `false` removes it. The answer is the state, so answering again turns it the other way; nothing is started or stopped now |
| `finish` | `{"start"?: true, "prompt"?}` | records the run as done; for a local setup starts a session in the workspace with `prompt`, or `suggested_prompt`, and answers it as `session` (`session.create`'s answer, or `{"error"}`) |

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
"refused", "trust", "notes", "oauth", "auth", "state", "tools", "error"}], "warnings": [...]}` —
every server the layers give the workspace, merged by name, the workspace's file over
the user's over `config.yaml`. `layer` is `config`, `user` or `workspace` and `source`
the file; `env` is the names of its variables and `headers` the names of the headers it
is sent (Decision 820), never their values; `refused` says why one will not start (an
unset `{env:VAR}`, an `oauth` with no `client_id`, a header Troupe sends itself); `trust` is
`trusted` or `pending` for a workspace-level server and null otherwise. `notes` is
`[{"key", "reason"}]`, as `agents.list`'s: a workspace-level server set to `permission:
auto` in a workspace not on `trusted_workspaces` has one `permission` note, since its tools
ask until the workspace is trusted, whatever its start's answer (Decision 830);
`permission` stays what the entry says. The workspace's layer reads nothing from outside
the repository until the workspace is trusted: an `include` from elsewhere (the person's
own `~/.claude.json`, say), or a `.troupe/mcp.json` that is a link out, gives no servers,
and `warnings` names it with the command that trusts the workspace (Decision 830). For a server
that wants the person signed in, `oauth` is `{"client_id", "scopes"?, "issuer"?}` as its
entry says, and `auth` is how their sign-in stands — `{"state", "account", "error"}`,
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
Claude Desktop's `mcpServers`, Cursor's, VS Code's `servers`, opencode's `mcp` — copying
its servers into the layer's `mcp.json`, or with `link: true` reading it in place from
then on. `${VAR}` and `${env:VAR}` become `{env:VAR}`; a server with a `${input:…}` or
an opencode `{file:…}` is skipped and said so; `headers` are kept, and a copy writes a
header whose value is written out as the `{env:<SERVER>_<HEADER>}` that reads it, never
the value, with a warning naming the variable to set (Decision 820); an `oauth` is kept,
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
failed; a workspace-level server whose command changed is asked about again first, and
answers `pending`. With `workspace` and `name`, or with `name` and a `server` that was
never written, the server is run once on its own, asked for its tools, and stopped. A
stdio server that does not answer `initialize` within twenty seconds is `error`.

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
the next session. A workspace on `trusted_workspaces` is not asked. Under
`managed_mcp_servers_only` no local server starts, and `mcp.status` says so for each.

#### `mcp.sign_in`, `mcp.sign_out`

A person's sign-in to one of their own servers that wants *them* rather than a machine
(Decision 741): an entry with a `url` and an `oauth` naming a client registered with the
server's authorization server. **The daemon's only**, like the rest of this section. The
daemon runs the sign-in, because it is the process that calls the server: it discovers
the authorization server from the server's `401` and protected-resource metadata, makes
the PKCE pair and the `state`, and listens on a loopback port of its own machine for the
browser to come back; the client only opens the URL. The tokens stay in the daemon's
state directory and are never in an answer, an event or a log.

```json
{"command_id": "c-19", "name": "wiki", "workspace": "/home/me/project"}
```
`mcp.sign_in` (`admin`; `workspace` or `session_id` optional, as for `mcp.list`) →
`{"server", "url", "redirect_uri", "expires_at"}`: open `url` in a browser on the
daemon's machine; the answer comes back to `redirect_uri`, and the daemon stops waiting
at `expires_at`, five minutes on. `mcp.list`'s `auth` says how it stands, and every
local session that waits for the server asks it for its tools once the sign-in lands. A
second `mcp.sign_in` for the same server replaces the first. A server with no `oauth`,
one whose `oauth` is refused, and a workspace-level server the workspace's question has
not approved are `invalid_params`; a name the layers do not give is `not_found`.

`mcp.sign_out` (`admin`, the same parameters) → `{"server", "auth"}`: the sign-in is
forgotten on this machine, and the server's sessions show `sign_in` again. The
provider's own session in the browser is the provider's.

#### `mcp.tools`, `mcp.call`

One of the person's own servers outside any session (Decision 748), for a client that
offers its tools to a session on a pod as tools it hosts (section 8). A pod's session
reads none of the person's files and holds none of their sign-ins, so the client lists
the server's tools here, registers them with the pod, and serves each `tool.invoke` by
calling here: the call is made on the person's machine with their sign-in, and the pod
sees names, schemas, arguments and what came back. **The daemon's only**, like the rest
of this section, and `admin`, since each goes out as the person. A server with a `url`:
one that runs a command, one that is refused or `disabled`, and a workspace's server the
workspace's question has not approved are `invalid_params`; a name the layers do not
give is `not_found`.

```json
{"name": "wiki"}
```
`mcp.tools` (`workspace` or `session_id` optional, as for `mcp.list`) → `{"server",
"state", "error", "tools": [{"name", "description", "schema"}]}`: the server asked for
its tools as a local session asks, with the person's sign-in, `state` and `error` as
`mcp.check` reports them, so one that waits for a sign-in is `sign_in` with no tools.

```json
{"command_id": "c-20", "name": "wiki", "tool": "search", "arguments": {"q": "the plan"}}
```
`mcp.call` → `{"server", "tool", "content"}`: the call made with the person's sign-in,
refreshed and made once more on a `401`, and `content` what a local session's model
reads from the same tool — the server's text, anything else named — down to the
`sign_in_required` note once the sign-in has run out, which `mcp.list`'s `auth` then
shows as `expired`. A call the server could not take is `unavailable`, with
`data.reason`. A client serving a pod's `tool.invoke` answers it with `{"content"}` as it
came, and names the call in `command_id` by the session and the pod's `call_id`, so a
call the pod sends again after a drop (section 8) is answered from the first rather than
made twice.

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

#### `worktree.merge`
```json
{"command_id": "c-9", "workspace": "/home/me/project",
 "path": "/home/me/project-troupe-abc", "message": "troupe: fix the test"}
```
→ `{"merged": true, "branch": "troupe/abc", "committed": true, "output": "..."}`

Lands a branch's work on the checkout it came from: anything uncommitted in the
worktree is committed first (as `message`, or a default naming the branch), the branch
is merged into `workspace` with a merge commit (`--no-ff`), and the worktree and branch
are removed. A merge git cannot complete is aborted and answered with `conflict`
(`reason: "merge conflicts"`, `output`: git's words); the worktree is untouched, so the
person can resolve it by hand. Refused with `conflict` while the session in that
worktree is mid-turn (`reason` names the session).

#### `worktree.discard`
```json
{"command_id": "c-10", "workspace": "/home/me/project", "path": "/home/me/project-troupe-abc"}
```
→ `{"discarded": true, "branch": "troupe/abc"}`

Removes the worktree and deletes its branch, uncommitted work included. Same refusal
while its session is working.

### Fleet

#### `fleet.get` → the same shape `subscribe` to `fleet` would replay as a snapshot.
#### `watch.set` → `{"command_id", "workspace", "enabled": true}`. Watch mode is
**exclusive per workspace**; enabling it where another session already watches returns
`conflict`.

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
`question.answer`, `todo.edit`, `tools.register` and `shell.run`. Each brings a dormant session's tree
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
| `observe` | `initialize`, `subscribe`, `unsubscribe`, `session.list`, `session.get`, `session.goal.get`, `session.loop.get`, `blob.get`, `fleet.get`, `fs.list`, `fs.read`, `agents.list`, `agents.get`, `agents.validate`, `commands.list`, `workflows.list`, `memory.get`, `context.get`, `mcp.status`, `mcp.list`, `skills.list`, `workspace.recent`, `workspace.search`, `worktree.list`, `presence.set`, `identity.get`, `config.get`, `setup.get` |
| `control` | everything in `observe`, plus `input.send`, `commands.run`, `turn.cancel`, `profile.switch`, `session.goal.set`, `session.goal.clear`, `session.loop.start`, `session.loop.stop`, `approval.respond`, `question.answer`, `todo.edit`, `fs.upload`, `tools.register`, `tools.unregister`, `memory.decline`, `onboard.decline`; and `shell.run` and `shell.cancel`, which also need the session's owner or `admin` (Decision 813) |
| `admin` | everything in `control`, plus `session.create`, `session.archive`, `session.pin`, `session.unpin`, `session.erase`, `session.claim`, `worktree.remove`, `worktree.merge`, `worktree.discard`, `memory.forget`, `onboard.plan`, `onboard.apply`, `watch.set`, `identity.link`, `identity.unlink`, `identity.sign_out`, `config.models`, `config.set`, `config.import`, `setup.answer`, `mcp.add`, `mcp.remove`, `mcp.check`, `mcp.sign_in`, `mcp.sign_out`, `mcp.tools`, `mcp.call`, `skills.add`, `skills.remove`, `agents.put`, `agents.delete` |

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
`question.answer`, `todo.edit`, `fs.list`, `fs.read`, `fs.upload`, `blob.get`,
`mcp.status`, `context.get`, `commands.list`, `commands.run`, `presence.set`, `tools.register`, `tools.unregister`, `shell.run` and `shell.cancel`. Everything else a
worker serves is about the pod or a path on it — `session.create`, `agents.list`,
`workflows.list`, `memory.get`, `memory.forget`, `memory.decline`, `workspace.recent`, `workspace.search`,
`worktree.*`, `watch.set`, `identity.*`, `config.*`, `skills.*` and the `mcp.*` methods
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
grace, and the call fails once, with a result naming the tool and saying its client left;
the tool is off the model's list by then (`tools_unregistered`, reason `disconnected`).
The grace comes out of the call's own timeout, so a dropped laptop is never a hung turn.

**The session is tainted, visibly.** `session_tainted` is durable and appears in every
participant's summary, because a tool running on somebody's laptop is something the others
are entitled to know about.

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
  "data": {"challenge": "…", "prompt": "Let this session run 1 tool on your machine?",
           "tools": ["notes.search"]}}}
```

With it: `{"registered": ["client.notes.search"], "taint": "personal_connector"}`.

Registered tools appear as `client.<name>` under the same allowlists, permissions and
approvals as everything else. A client offering one of the person's own servers this way
(`mcp.tools`, `mcp.call`) names each tool `<server>.<tool>`, so the model sees
`client.wiki.search`, which no profile's `mcp.wiki.search` can be.

### `tools.unregister` → `{"unregistered": [...]}`

Also happens on its own when the connection drops.

### `tool.invoke` (request, **server → client**)

```json
{"jsonrpc": "2.0", "id": 42, "method": "tool.invoke", "params": {
  "call_id": "call-1", "name": "notes.search", "arguments": {"q": "the thing"}}}
```

The client answers with a result or an error, on the same connection. A client that does
not answer within the tool's timeout gets the call abandoned and the agent gets an error
result — the same contract as any other tool that fails. A client that registers a tool
after another connection of the person's dropped mid-call may be sent that call first,
under the `call_id` the earlier connection was asked with.

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
| `admin.profiles.list` | either | profiles with conditions, pods, load and versions; in gitops mode each carries `gitops` (`source`, `generation`, and a `problem` — `refused`, `missing`, `plane_only`, `unwritten` — with `reasons`), and a refused resource with no profile is listed too |
| `admin.profiles.export` | platform | `{profiles, policy, triggers, left_out}`: every profile, the `TroupePolicy` and every `Trigger` as a repository would hold them, each `{name, path, yaml, notes}` (a trigger's also `team`), without what the plane or the cluster writes (`left_out`, of a profile) or keeps (a trigger's key, runs and revisions) |
| `admin.profile.get` | platform | the CR spec, the policy verdict, published vs reported bundle hash, and `gitops` as in the list |
| `admin.profile.put` | platform | creates or updates a `WorkerProfile`, returning the diff that was applied; `managed_by_gitops` in gitops mode |
| `admin.profile.delete` | platform | removes one; `managed_by_gitops` in gitops mode, except for a profile the cluster has no resource for, whose row alone it deletes |
| `admin.pod.drain` | platform | drains a pod, returning what it held |
| `admin.teams.list` | either | teams, with grants, budgets, volumes and retention |
| `admin.team.enable` | platform | makes an IdP group a team |
| `admin.team.update` | either | budget, retention, default visibility, volume; `allow_unenforced_workers` a platform admin's; keys it does not declare, a team's name and group among them, are left alone |
| `admin.team.grant` / `admin.team.revoke` | platform | a team's access to a profile |
| `admin.sessions.list` | either | session *metadata*, never content |
| `admin.session.erase` | either | erases one, for authorised roles |
| `admin.bundles.list` | either | every version of a channel, each with its `summary` (names of agents, skills and MCP servers) |
| `admin.bundle.get` | either | one version in full: the document, its `detail` (agents with mode and skills, skills with files, MCP servers with the Secret to create), and adoption per profile |
| `admin.bundle.validate` | platform | checks a document the way publishing will, without publishing; `{ok: true, summary, hash}` or `invalid_params` with `data.errors` |
| `admin.bundle.publish` / `admin.bundle.retire` | platform | publish a version — refused as `invalid_params` with `data.errors`, one sentence per problem, when the document is malformed or names an MCP host outside `allowedEgress` — or retire one |
| `admin.mcp.check` | either | `{host, allowed}`: whether the cluster policy lets a pod reach an MCP server's host |
| `admin.audit.list` | either | who changed what, with diffs, each change keyed by its path (`spec.llm.model`) |
| `admin.provisioning.mode` | either | `direct` or `gitops`: whether the plane writes profiles to the cluster, or reads them and the triggers from resources a repository holds and refuses to write them |
| `admin.settings.list` | either | every platform setting with its value, where that value came from (`stored`, `deployed`, `unset`), what changing it does and when it takes effect; a secret is reported as set and never returned |
| `admin.setting.put` | platform | `{key, value}` — parsed against the setting's declared type and refused if it does not fit, or if the deployment owns it |
| `admin.setting.reset` | platform | `{key}` — drops the stored value, so the setting goes back to what the plane was deployed with |
| `admin.identity.check` | either | four named checks with what each proved and how long it took: provider discovery, its signing keys, the endpoints this plane was given, and who actually carries the platform admin group. `{group}` checks a candidate group *before* it is saved |
| `admin.principals.list` | either | a team's service principals: subject, profiles, last use, whether enabled — never a secret or its hash |
| `admin.principal.create` | either | `{team, name, description, profiles}` → the principal, with `secret` exactly once; `profiles` must be within the team's grants |
| `admin.principal.rotate` / `admin.principal.disable` | either | `{subject}`: a new secret shown once, or the end of the credential; a disabled principal is `unauthenticated` at its next call |
| `admin.triggers.list` | either | `{team}` → a team's trigger definitions, each with the `revision` its next firing would use; in gitops mode each carries `gitops` (`resource`, `source`, `generation`, and a `problem` — `refused`, `missing` — with `reasons`), a refused resource of the team with no trigger is listed as `{name, team, gitops}`, and a platform admin also gets those naming no team here, with `team` null |
| `admin.trigger.put` | either | upsert by `team` and `name`; partial on update, so `{team, name, enabled: false}` is a switch-off; returns the trigger, the diff and the `revision` the document now hashes to; `managed_by_gitops` in gitops mode, the switch-off included |
| `admin.trigger.delete` | either | `{team, name}`; the runs go with it, the sessions they made do not; `managed_by_gitops` in gitops mode, except for a trigger the cluster has no resource for |
| `admin.trigger.run` | either | `{team, name}`: fire it now, with a manual idempotency key naming the caller and the minute; in either mode |
| `admin.trigger.key.rotate` | either | `{team, name}` → `{team, name, url, key, rotated_at}`: the trigger's own key, shown once, the old one dead at once; in either mode, since the key is never in a resource |
| `admin.runs.list` | either | `{team, trigger?, limit?}` → runs newest first, each with its `state` (`created`, `running`, `waiting`, `done`, `failed`, `skipped`) read from the session's status, its `done_reason` and `failed_reason` (a turn the harness stopped, `tool_failures` or `agent_failed`, which makes the run `failed`), and the `revision` and `revision_hash` it actually ran |
| `admin.trigger.revisions` | either | `{team, name}` → every revision of a trigger, newest first: the number, the hash, who made it and when, and whether it was reconstructed by the migration that introduced them |

Membership is never editable: it comes from the identity provider, and a method to change
it would be a second source of truth for who is in a team.

### The same methods as MCP tools

    POST /mcp

Streamable HTTP, one JSON-RPC message per request, protocol revision `2025-06-18`.

Two kinds of bearer token are accepted, because there are two kinds of caller. `troupe mcp`
bridges a **plane** token, the same one `/rpc` takes, because the CLI already holds
credentials. Any other MCP client does OAuth against the identity provider â€” there is no
step in that flow where it could obtain a plane token â€” and presents what the provider
issued: an id_token addressed to the client id, or an access token addressed to
`api://<client-id>`. Both are verified in full against the provider's published keys, the
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

`troupe mcp` bridges this endpoint over stdio for a client that cannot send a bearer
header, minting and renewing the plane token from the credentials `troupe login` stored:

    claude mcp add troupe -- troupe mcp

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

Three methods on the plane's `/rpc` that are not administrative, because a caller other
than an admin uses them:

| method | scope | who | answers |
| --- | --- | --- | --- |
| `trigger.fire` | control | the trigger's principal, or an admin of its team | `{trigger (name, `team/name` or id), idempotency_key, event}` → the run and, when a session was made, the same `{session_id, endpoint, token}` `session.create` returns. The run names the `revision` and `revision_hash` it ran. The same key returns the same run, the same revision and a fresh token; over the trigger's `concurrency` the run is `skipped` and has no session |
| `session.grant` | control | the session's owner, or an admin of its team | `{session_id, subject, role}` (`owner`, `collaborator`, `viewer`; default collaborator) → mirrored in the plane's ACL and pushed to the pod holding the session as `acl.changed` |
| `session.review` | control | anybody who can see the session | `{session_id}` → sets `reviewed_by`/`reviewed_at` on the session and its run, audited as `session.review` |
| `me.client_defaults` | observe | anybody | `{}` → `{configured, provider, base_url, auth, models: {default, cheap, expensive}}` — what an administrator says people's own machines should talk to (the *Client defaults* settings), for a client to pre-fill its model settings with. **Never a key**: anybody signed in may ask, so each person supplies their own. `configured` is false, and the rest null, until a provider is set |
| `me.connections.list` | observe | anybody | the MCP servers on the caller's profiles that act as *them*, each with its `slot` and whether they have `connected` it. Whether, never what: the plane can see that a slot has a version and cannot read one |
| `me.connections.grant` | control | anybody, for themselves | `{slot}` → `{assertion, expires_at, audience, key_manager: {address, mount, auth_path, role, name, path}}`. **No value crosses the plane**: it answers a short-lived assertion for the caller's own name at the key manager (`name`, the segment of `path` under `troupe/people/`, not always their subject: Decision 755). The client exchanges it with the key manager itself for a token scoped to its own subtree, and then writes the value directly. The same grant is how a person removes one — deletion is theirs, always |
| `session.register` | control | anybody, for their own private sessions | `{session_id, device, epoch, head_hash, last_seq, object_bytes, workspace_bytes, title, claim}` → the session row. Idempotent on the id: the first call mints epoch 1, a later one is a seal report. A seal carries the `epoch` the device holds and is refused with `stale_version` if another device has moved past it; `last_seq` never goes backwards. `claim: true` takes the session over on this device, bumping the epoch conditionally — two devices sending the same `epoch` produce one winner, and the loser learns it lost on its next seal rather than by being told, and stops sealing (issue #433) |
| `session.presign` | control | anybody, for their own private sessions | `{session_id, method (`get`/`put`/`head`), keys, epoch}` → `{expires_in, urls}`, one signed URL per key, good for five minutes. Every key must be under `sessions/<session_id>/` and at most 64 per call. **The bytes never cross the plane**: it holds an object-storage credential scoped to signing and no key for what it signs for, which is the narrowest revision of Decision 90 that lets a laptop seal at all. `epoch`, optional, is the one the caller holds: a daemon sealing names it on every `put`, and one another device has claimed past is refused with `stale_version` and signed nothing, so the device that lost the session learns it before it writes under the prefix rather than at the report after (issue #441, Decision 800). Without one it signs as before, for a restore and a daemon from before 0.8.6 |
| `session.objects` | observe | anybody, for their own private sessions | `{session_id, prefix}` → `{keys}` under `sessions/<session_id>/`. A caller with no object-storage credential cannot list — a listing is signed against the bucket, not against a key it does not yet know — so the plane lists for it. A `prefix` may narrow the listing and may not widen it; one that is not under the session's own is ignored |
| `session.assertion` | control | anybody, for their own private sessions | `{session_id}` → `{assertion, expires_at, audience, key_manager: {address, mount, auth_path, role, name, path}}`, the same shape `me.connections.grant` answers and for the same reason. The path is `troupe/people/<name>/sessions/<session_id>`; the person policy covers their own subtree and no pod role covers any of it. A daemon makes or finds the session's key under `name`, and under the subject it is linked as only where a plane from before Decision 755 answers none. The session must already be registered, which is what makes this a statement about a session the plane agrees is theirs |
| `session.erasures` | control | anybody, for their own private sessions | `{device}` → `{erasures: [{session_id, erased_at}]}`: the caller's private sessions whose key is destroyed and whose erasure this `device` has not acknowledged. A daemon asks when a client links it with a plane token. A session whose key is not yet destroyed is tried again first and is not listed until it is (Decision 756) |
| `session.erased` | control | anybody, for their own erased private sessions | `{session_id, device}` → `{session_id, device, deleting, objects_deleted}`: this device has stopped sealing the session and erased its copy, and the plane deletes every version of every object under `sessions/<session_id>/` and records the device once none is left. `deleting: false` with how many went when that is done within the call; `deleting: true` and no count when it takes longer than the call waits (five seconds), and the plane carries on and records the device when it is done. `unavailable` with `objects_deleted` and `objects_left` where the object store refused or failed some: the device is not recorded, and `session.erasures` names the session to it again, which tries again (Decision 804). `not_found` for a session that is not the caller's, not private or not erased: saying a session is erased does not erase it |

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
| -32015 | `managed_by_gitops` | an admin write to what a repository holds (§9); `data.source` |

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
| **MCP** | admin client → plane | an administrator and the admin surface | the methods of §9, as tools | the same admin scopes, §9 |
| **A2A** | another agent → a profile | an agent framework and a whole profile | a task in, an answer out; no sessions, pods or events | the facade exchanges the caller's credential and calls `/rpc` as that principal |

### The rules that fall out of it

**A protocol is a way in, never a second set of permissions.** Every row is enforced by the
mechanism that was already there: ACP on the daemon socket gets the scopes that socket gives,
admin MCP gets the admin scopes, the A2A facade holds no credential of its own and acts as
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
* **A2A does not attach.** It has no events, no subscriptions and no approvals — a task goes
  in and an answer comes out. Somebody who wants to watch it happening wants this protocol.
