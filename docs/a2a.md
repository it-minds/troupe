# The A2A facade

`apps/troupe_a2a` makes every Troupe profile an agent that other agents can call over
the [A2A protocol](https://a2a-protocol.org): JSON-RPC 2.0 over HTTP, an agent card per
profile, and server-sent events for streaming. LiteLLM's A2A gateway, another agent
framework, or a script sends a task to `/a2a/<profile>` and gets an answer back without
learning anything about sessions, pods or the human protocol.

The facade is a client. It uses the same public APIs as the TUI — the plane's `/rpc`
and the worker WebSocket — holds no database and no credential of its own, and `mix
troupe.boundaries` holds it to `troupe_protocol` alone. What it must remember between
requests is the session row: the task id **is** the session id, and the plane records
`origin: {"kind": "a2a", "caller": …, "task": …}` at create. A restarted facade answers
`tasks/get` the same way, from the plane.

## Routes

| route | auth | what |
| --- | --- | --- |
| `GET /healthz` | none | liveness |
| `GET /a2a/<profile>/.well-known/agent-card.json` | optional | the agent card |
| `POST /a2a/<profile>` | required | A2A JSON-RPC: one request per POST |
| `GET /a2a/tasks/<id>/artifacts/<hash>` | required | an artifact's bytes |

## Who is calling

Every request but the card and the health check carries an `Authorization` header,
and the facade acts as the principal it names. Two kinds of caller, one exchange:

| header | who | exchanged as |
| --- | --- | --- |
| `Bearer svc:<team>/<name>:<secret>` | a plane service principal | `{"client_id", "client_secret"}` |
| `Basic base64(svc:<team>/<name>:<secret>)` | the same, for clients that can only send Basic | `{"client_id", "client_secret"}` |
| `Bearer <id_token>` | a person, with an identity provider token | `{"id_token"}` |

The exchange is `POST /auth/exchange` on the plane. The plane token it returns lasts at
most fifteen minutes and is cached per credential until a minute before it expires;
the cache holds a digest of the credential, never the credential. There is no
facade-wide credential that can reach every profile: a compromised facade holds
nothing more than each caller's own short-lived plane token, and it cannot see a
session its principal does not own or sit on the ACL of, because the plane decides
that, not the facade.

LiteLLM's A2A gateway is one caller with one principal, owned by a team and granted
the profiles it may call.

## The card

`GET /a2a/<profile>/.well-known/agent-card.json` needs no token. Without one the card
is rendered from the URL alone — the name, where to call, the bearer scheme, one skill
named for the profile — and says `supportsAuthenticatedExtendedCard: true`. With a
credential on the same `GET`, or through `agent/getAuthenticatedExtendedCard`, the
card carries what `profiles.list` says about the profile: the bundle's skills as A2A
skills (`id` = the skill's name), and `version: "bundle:<channel>/<version>"`, so a
caller can tell when the capability behind the card changed.

```json
{"name": "reviewer", "description": "Troupe profile reviewer",
 "url": "https://a2a.example.com/a2a/reviewer",
 "version": "bundle:stable/7", "protocolVersion": "0.3.0",
 "capabilities": {"streaming": true, "pushNotifications": false, "stateTransitionHistory": true},
 "securitySchemes": {"bearer": {"type": "http", "scheme": "bearer"}}, "security": [{"bearer": []}],
 "authentication": {"schemes": ["Bearer"]},
 "defaultInputModes": ["text/plain", "text/markdown"],
 "defaultOutputModes": ["text/markdown", "application/octet-stream"],
 "skills": [{"id": "review-checklist", "name": "review-checklist",
             "description": "How we review a pull request at IT Minds", "tags": ["troupe", "reviewer"]}]}
```

## The mapping

| A2A | Troupe |
| --- | --- |
| `message/send` with no task | `session.create {profile, prompt: <the text parts>, visibility, origin: a2a}` as the caller's principal; the task id is the session id |
| `message/send` on a task | `session.open activate`, then `input.send` on the worker socket |
| `message/send` with `configuration.blocking: true` | the same, then the socket is held until the task is at rest and the answer is in the response |
| `message/stream` | the same, then `subscribe session:<id> detail` translated into `status-update` and `artifact-update` events over SSE; the first event of a new task is the task itself |
| `tasks/resubscribe` | a reader's subscription from `metadata.lastSeq + 1`, never an activation |
| `tasks/get` | the plane row's `status` and `done_reason` while the task is being worked on; a reader over `session.open read` when the task is at rest or `historyLength > 0`, which is where the answer, the artifacts and the history come from |
| `tasks/cancel` | `turn.cancel`, then `session.archive` |
| `input-required` | `approval_requested` — the status message names the tool and its arguments in a `data` part; the caller's next `message/send` on that task with a first part `{"kind": "data", "data": {"decision": "allow" \| "deny" \| "allow_session", "call_id": …}}` becomes `approval.respond`; free text on a waiting task is refused with a hint, because text cannot answer a yes/no the log will record as a decision |
| task states | `submitted` (row created) → `working` (thinking/acting) → `input-required` (waiting) → `completed` (a root turn ended, or `agent_done` with reason `finished`) / `failed` (`llm_error`, `budget_exhausted`, `interrupted`, any other `agent_done`) / `canceled` |
| `pushNotificationConfig/*` | `PushNotificationNotSupportedError`; the card says so |

The final answer of a task is the text of the last root `llm_response` in the turn that
ended it, or `agent_done.summary` when the agent used `finish`. The facade returns it
as the task's `status.message`. It is a rendering of the log, done by the facade with a
reader, never stored in the plane.

A message on a task that has already completed continues its session: a Troupe session
can always take another input, and a follow-up that started a fresh session would have
lost everything the first one knew. `contextId` is the task id, and a message that
names only a `contextId` addresses that task.

Every `status-update` carries `metadata.lastSeq`, the sequence number of the event it
came from. A client that loses its stream sends it back as `metadata.lastSeq` on
`tasks/resubscribe` or on its next `message/stream` and misses nothing; events from
before the head are delivered without `final`, so an approval that was answered an hour
ago does not end the new stream.

## Artifacts

Two kinds, both already in the log:

* **Published files.** A `published {destination, hash, bytes}` event becomes an
  artifact whose `artifactId` is the hex of the hash, whose `name` is the destination,
  and whose one `file` part has `uri: <public>/a2a/tasks/<id>/artifacts/<hex>`. The
  route serves it by `fs.read` of the destination on the session's mounts, through a
  reader, with the caller's own token.
* **Large tool results and blobs.** A blob reference in a `tool_call_completed` result
  or in an `llm_response` becomes a `file` part served from `blob.get` the same way.

The bytes' SHA-256 is checked against the hash before anything is sent; a mismatch is
a `502`. The facade invents nothing: an artifact exists because an event says so, and
it is fetched through the session's own access checks.

## Costs and limits

* **Reading a finished task costs a reader pod.** `tasks/get` on a task at rest, or
  with history, and every artifact fetch opens a reader on a pod of the profile; the
  facade caches nothing across calls, so a caller that polls a finished task in a loop
  pays for it. A task being worked on is answered from the row alone.
* **Streaming is a socket per stream**, capped per replica by `TROUPE_A2A_MAX_STREAMS`
  (429 beyond). A stream that outlives its pod token is refreshed with `token.mint` and
  `auth.refresh` on the open socket.
* **No push notifications** in this release.

## Running it

The chart's `a2a` block, off by default: `a2a.enabled: true`, `a2a.host`, a TLS secret or
`a2a.publicUrl`, and `a2a.visibility: team` if tasks should be visible to the caller's team.
Enabling it also admits the facade's pods to the plane's HTTP port. Each caller is a
service principal of a team granted the profiles it may call. Variables:
[admin/configuration.md A.4](admin/configuration.md#a4-a2a-facade-troupe_a2a).
