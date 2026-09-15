# Stage 6 â€” the five things to take, done our way

A review of `different-ai/openwork` found five places where they have something we do
not. This is the plan to have those five things, built the way this repository builds
things: durable events as the record, one process for each thing that must be
serialised, a projection where a query needs to be fast, and a cache that can be thrown
away without losing a number.

None of it is a port. Their control plane is a Node service over MySQL that writes a row
per fact; ours is a BEAM cluster that already writes a hash-chained event per fact and
throws most of them away at the plane boundary. The interesting work is deciding which
of their tables we already have as a log, and which of their loops we already have as a
process.

Part 1 is **built** â€” `ARCHITECTURE.md` Â§15 describes what landed and `REPORT.md`'s
stage 6 section proves it. It stays here as the record of what was intended, including
the four places where the build deviated (all named in `DECISIONS.md` 287â€“303). The
other four are not built.

| Part | One line | Size |
| --- | --- | --- |
| [1. Token accounting](#1-token-accounting) â€” **built** | Cost becomes a fold over the log, batched through a pod-local cache into a ledger that is already built. | large |
| [2. Entitlements below the profile](#2-entitlements-below-the-profile) | A grant may name which of a bundle's agents, skills and servers a team gets. | medium |
| [3. Credentials that belong to a person](#3-credentials-that-belong-to-a-person) | An MCP server may authenticate as the session's owner, with the value in OpenBao and the plane never holding it. | medium |
| [4. Trigger revisions](#4-trigger-revisions) | A run names an immutable, content-addressed revision instead of a row somebody has since edited. | small |
| [5. Proving it on a cluster](#5-proving-it-on-a-cluster) | The end-to-end suite that `scripts/remote-up` has been waiting for, and CI that runs it. | medium |

---

## Threads that run through all five

* **The log is the record; a table is a projection.** Every number stage 6 adds already
  exists as a durable event on a pod, or becomes one. The plane's rows are derived, and
  a pod that has been out of touch catches the plane up by re-folding, not by replaying a
  queue it kept in memory.
* **A cache may be lost.** Every cache here is ETS owned by a process that can die.
  Losing one costs a fold, a query or a round trip â€” never a number, never a decision.
* **Idempotency is content-addressing.** A bundle is its hash, a trigger revision becomes
  its hash, a usage record is the gateway's request id. The same argument each time: two
  systems that must agree join on something neither of them invented.
* **One process per serialised thing, and let it crash.** `TeamBudget` per team,
  `Singleton` for the scheduler, a new pod-local usage collector. No new locks, no new
  advisory-lock table; the BEAM already gives us the mutual exclusion those are for.
* **Telemetry is for looking, never for counting.** `[:troupe, :llm, :stop]` already
  fires (`agent/server.ex:851`) and a handler that raises is detached without a word.
  Accounting rides the log, and the telemetry stays exactly where it is.

---

## 1. Token accounting

### Brings, takes, already in place

**Brings.** A team can be told what it spent, by session, by model and by person. A
budget stops meaning "we reserved this much" and starts meaning "this much is gone".
`cost_micros`, which is on the wire, in the column and in `session.status` and has
always been zero, becomes true.

**Takes.** Three fields on one durable event; a pod-local collector with an ETS table
and a batch; one new control-channel method; a watermark carried on the session index;
and a panel page that reads a cached sum.

**Already in place â€” nearly all of it.**

* `usage_records` exists, is append-only, and is unique on the gateway's request id
  (`priv/repo/migrations/20260101000004_ledger_and_audit.exs:15-30`).
* `Ledger.record/1` is idempotent and reports `{:duplicate, existing}` as a success
  rather than an error, because a replaying worker has done nothing wrong
  (`ledger.ex:33-46`).
* `TeamBudget` holds `spent_micros` in process state and moves it on a non-duplicate
  record, so the hot path costs no query (`team_budget.ex:112-125`).
* The plane handles `usage.record` on the control channel and routes it to the session's
  team (`control/connection.ex:313-333`).
* `Reconcile` compares a window of the ledger against the gateway by request id and
  reports missing, extra and mismatched separately (`reconcile.ex:1-26`).
* The worker's link has `usage/2`, which casts a `usage.record` notification
  (`plane/link.ex:84-88`).
* `llm_response` is a durable log event carrying input and output tokens
  (`agent/server.ex:842-850`).

### What is missing today, precisely

| Gap | Where |
| --- | --- |
| `Link.usage/2` is never called. The whole ledger path is built and nothing feeds it. | `plane/link.ex:84`, no callers |
| `Troupe.LLM.Response` has no model, no gateway request id and no cost. The adapter reads `response.private[:troupe]` and discards `response.headers`. | `llm/request.ex:100`, `llm/providers/openai.ex:107-111` |
| The `llm_response` event carries two integers. Model, request id and cost are not in the log, so they cannot be re-folded. | `agent/server.ex:844-848` |
| The link's queue is capped at 10 000 and drops the oldest on overflow, which `Reconcile` names as the usual cause of `missing` drift. | `plane/link.ex:41,409-411`, `reconcile.ex:10-22` |
| Nothing knows how far the plane has got. A reconnecting pod cannot tell which reports landed. | `plane/link.ex:90-94` (index carries seq, not usage seq) |
| `Summary` folds a `"cost" => 0.0` that nothing ever writes to. | `session/summary.ex:33` |

### Design

#### 1a. Three fields, and cost stops being a second write path

`Troupe.LLM.Response` gains `gateway_request_id` and `cost_micros` beside the `model`
it already has. Both are read from the gateway's response headers in the shared HTTP
path: LiteLLM returns `x-litellm-call-id` and `x-litellm-response-cost`, and the
adapters keep every header they do not recognise out of the struct.

**We do not build a price table.** OpenWork maintains one, with a weekly workflow to
refresh it, because their gateway is theirs and the price is theirs to know. Ours is
LiteLLM, which has already priced the call by the time it answers, and we already have a
nightly job whose whole purpose is to catch the ledger disagreeing with the gateway. Take
the gateway's number; where the header is absent, record the tokens with `cost_micros: 0`
and let `Reconcile` report it as `missing` cost rather than invent one. A number we made
up would reconcile against itself.

`llm_response` then carries:

```json
{"message": {...}, "stop_reason": "end_turn",
 "usage": {"input_tokens": 4120, "output_tokens": 380},
 "model": "anthropic/claude-opus-5",
 "gateway": {"request_id": "â€¦", "cost_micros": 18400}}
```

Adding keys to an event is what the schema-compatibility rule permits and
`mix troupe.schema.diff` enforces. An old event without `gateway` folds to a record with
a zero cost and a synthesised request id of `"seq:<session_id>:<seq>"`, so a session
sealed before this stage still accounts for its tokens and is distinguishable in
reconciliation from one that had a real id.

The consequence is the point: **cost is a fold, not a write.** The fold that turns
`llm_response` into token totals already exists (`log/fold.ex:135-145`), and
`Log.replay_from/2` already answers "everything after this sequence"
(`session/log.ex:68-72`). A pod that has been out of touch for an hour does not replay a
queue held in memory; it folds the log forward from a watermark and sends what the plane
has not got.

One consequence to expect rather than be surprised by: `llm_response` is a witnessed
type (`log/fold.ex:63`), so adding `model` and `gateway` to it moves the fixture fold
hash and CI will say so. That is the check doing its job. Record the new hash in the same
commit as the field, with the reason, which is what `Troupe.Log.FoldTest` is for.

#### 1b. The collector: an ETS table and one batch

Writers are agent processes, several per session, each finishing a turn on its own
schedule. Sending each one a message to a collector would put a mailbox between a turn
and its next tool call.

```
Troupe.Worker.Usage            (GenServer, owns the table, one per pod)
  table: :troupe_usage         (:public, :set, write_concurrency: true)
  key:   {session_id, seq}     â€” the log's own sequence, already monotonic per session
  value: %{model:, input_tokens:, output_tokens:, cost_micros:, request_id:, at:}
```

* **Writers never call the owner.** `Troupe.Worker.Usage.put/2` is `:ets.insert/2` from
  the agent process. A slow flush, a plane outage or a dead collector costs the turn
  nothing.
* **The owner drains on an interval** (`Process.send_after`, 2 s, and immediately at
  1 000 rows) with `:ets.select/2`, sends one `usage.batch`, and deletes only what the
  plane acknowledged with `:ets.select_delete/2`. A row written during the flush has a
  higher key and is picked up next time.
* **`handle_continue(:first_flush, â€¦)`** after `init/1`, so a pod that restarts with a
  backlog does not wait an interval to start emptying it.
* **`terminate/2` flushes best-effort and correctness does not depend on it.** The log
  is the record; a flush lost to a SIGKILL is recovered by the fold.

Keying on the log's sequence rather than a counter of our own is what makes the
watermark free: there is already exactly one monotonic number per session, and it is the
one the index reports.

#### 1c. The watermark, and the end of a drift class

`sessions` gains `usage_seq`: the highest log sequence whose usage the plane has
recorded for that session. It moves in the same transaction as the records it accounts
for, and it rides back to the pod on the index reconciliation a reconnect already owes
(`plane/link.ex:90-94`).

A pod that reconnects therefore learns, per session, where the plane got to, and folds
the log forward from there. The link's bounded queue stops being an accounting risk:
dropping a `usage.batch` under back-pressure now costs a re-fold rather than a
permanently missing record, and `Reconcile`'s `missing` category loses its usual cause.

`usage.batch` is added to the control channel; `usage.record` stays for one release, the
same compatibility rule `config.updated` got in stage 5. A batch is idempotent per
record â€” `Ledger.record/1` already is â€” so a retried batch is a batch of duplicates and
moves no total.

#### 1d. Reading it back, and the cache that makes that cheap

`TeamBudget` already caches the running total in process state, so the enforcement path
needs nothing. What is slow is a panel or an `admin.overview` asking for a breakdown, and
`Ledger.spent_micros/1` on a `TeamBudget` restart, both of which are `sum` over an
append-only table that only grows.

`Troupe.Plane.Ledger.Cache` is the same shape as `Troupe.A2A.Plane.Cache`
(`a2a/plane/cache.ex`), which is the shape this repository already uses for this: a
named public ETS set, a GenServer that owns it and sweeps, entries with an expiry,
readers that never call the owner. Keyed on `{team_id, from, to, group_by}`, invalidated
on write by `TeamBudget` â€” which is the only writer, and is already one process per
team, so the invalidation is serialised for free.

**Rollups are not in this stage.** OpenWork folds raw rows into hourly and then daily
buckets because they run every organisation's traffic through one gateway. At the small
release's volume, `usage_records` with an index on `(team_id, occurred_at)` and this
cache answer every question the panel asks. What this stage does owe is the *decision*
about growth: a retention setting that deletes raw records older than the retention
window after a daily rollup exists, and a note in `REPORT.md` naming the row count at
which to build it. Building a rollup pipeline for a table with fifty thousand rows in it
is the kind of work that looks like progress.

### Done items

1. A session that runs three turns produces three `usage_records` rows with the right
   model, tokens and cost, and `admin.overview` shows the team's spend move.
2. Killing `Troupe.Worker.Usage` mid-session loses no record: the collector restarts,
   folds from `usage_seq`, and the ledger ends with exactly the rows the log implies.
3. Stopping the plane for a minute while a session runs, then starting it: no duplicate
   rows, no missing rows, and `Reconcile` reports zero drift against a fixture gateway.
4. A batch delivered twice moves `spent_micros` once.
5. A session sealed before this stage folds to records with zero cost and synthesised
   request ids, and `Reconcile` reports them as cost-missing rather than as extra.
6. `Ledger.Cache` returns the same numbers as an uncached query, and a write invalidates
   it; clearing the table changes no answer.

### What the build changed

Four deviations, all in `DECISIONS.md` 287â€“303:

* **The two gateway fields live in a `Troupe.LLM.Gateway` struct** under
  `response.gateway`, not as two flat fields on `Response`. "The gateway said nothing"
  and "the gateway said this was free" are different facts and reconcile differently, and
  a struct is where that distinction survives.
* **Reconciliation gained an `unmetered` category** rather than reporting a pre-gateway
  call as `missing` cost. The plan had that backwards: `missing` means the gateway billed
  something the ledger never saw, and a call from before there was a gateway is the
  opposite. Unmetered rows are not drift and do not make a comparison dirty.
* **`Link.usage/2` was removed rather than kept.** The new worker only sends batches; the
  plane keeps handling `usage.record` for one release so an older pod image still works.
* **A charge dated in the future is dated now.** Not in the plan; found by a test, because
  a pod with a fast clock writes charges into a window no report asks about.

And one thing the plan asked for that was not built: rollups stay deferred, as Â§1d said
they should, and so does the retention setting that would go with them.

---

## 2. Entitlements below the profile

### The problem

A grant is one row, `(team, profile) â†’ role, volume_mode`, unique on the pair
(`migrations/20260101000001_identity.exs:81-93`). Everyone granted a profile gets the
whole bundle: every agent, every skill, every MCP server. The only way to give one team
less is a second profile, which costs a namespace, a `WorkerProfile`, a warm pod and an
image pull.

OpenWork's answer is a grant table per level of their hierarchy. Ours should not be three
tables, because we do not have their hierarchy â€” we have one document per channel, and
the thing that needs narrowing is which of its entries a team may see.

### Design

#### 2a. A child table, and absence means everything

```
grant_entitlements
  grant_id  references grants on delete: :delete_all
  kind      "agent" | "skill" | "mcp_server"
  name      the entry's name in the bundle
  mode      "allow" | "deny"
  unique on (grant_id, kind, name)
```

**No rows for a grant means no restriction**, which is exactly what every existing grant
means today, so the migration changes nothing and needs no backfill. Within a kind,
`allow` rows are an allowlist and `deny` rows subtract; a kind with only `deny` rows is
everything except those. Deny wins where both are present, because the two ways to write
the same intent should not disagree and the safe reading is the one that grants less.

A name that no longer exists in the current bundle is kept, not pruned: a bundle can be
rolled back, and an entitlement that vanished with a publish and did not come back with
the revert would be a silent widening.

#### 2b. Resolution happens at create, and lands in the log

`Bundles.offering/1` becomes `Bundles.offering/2`, taking the resolved set. Everything
that already calls it gets narrower answers for free:

* `profiles.list` shows a person the agents, skills and servers *they* may use
  (`harness.ex:865-877`).
* `agent_for/2` refuses an agent the team may not run, with the names it could have had,
  before placement and before a budget reservation (`harness.ex:280-289`).
* `session.activate` gains `entitlements` â€” the params are already an explicit keyword
  list with `nil`s rejected (`worker/plane/commands.ex:48-62`), so this is one more key.

The bundle itself is untouched. It stays one content-addressed document with one hash;
there are no derived bundles, no per-team hashes and nothing new to invalidate. What
narrows is the *session*, and `session_created` records the set, so the log answers "what
was this session allowed to see" for as long as the log exists. A `config_upgraded` at
activation re-resolves and records the set again, because a publish can add an entry a
team is not entitled to.

#### 2c. On the pod

* **Agents and skills** are filtered where definitions are loaded from the bundle
  directory. A definition that is not entitled is not in the search order, so nothing
  further has to know.
* **MCP discovery stays pod-wide.** It happens once at start and again on a bundle
  change, deliberately, because asking four servers for their tool list at every create
  would put somebody else's latency on the create path (`worker/mcp.ex:3-11`). The filter
  applies where the session's tool list is composed, not at discovery. A session that may
  not use `jira` does not see `mcp.jira.*`; the pod still knows the tools exist.
* **One team, one set.** A person picks the team they create under (`harness.ex:432-445`),
  so a session's set is that team's, not an intersection over their teams. Simpler to
  explain and simpler to audit, and a person in two teams with different entitlements can
  create two sessions.

#### 2d. Where an admin does it

The panel's grant editor gains three checklists rendered from the channel's current
bundle, and `admin.team.grant` accepts an `entitlements` list. `Audit` already records
`team.grant` with a diff (`audit.ex:29-46`), and a diff of entitlement names is a diff of
names, so nothing about redaction changes.

### Done items

1. A team granted a profile with no entitlement rows behaves exactly as today, proven by
   the existing grant tests passing unchanged.
2. A team entitled to one of two skills gets one skill in `profiles.list`, one line in
   the agent's prompt, and `not_found` from the `skill` tool for the other.
3. An agent the team may not run is refused at `session.create` with the names it could
   have had, and no placement or budget reservation is made.
4. A session's `session_created` names its entitlement set; a publish that adds a server
   the team may not use produces a `config_upgraded` whose set does not include it.
5. A `deny` row beats an `allow` row for the same name.

---

## 3. Credentials that belong to a person

### The problem

A bundle's MCP server names one `credential_ref`, which the operator turns into one
`secretKeyRef` in the profile's namespace (`operator/resources.ex:645-675`). Every
session on that profile therefore reaches Jira as the same service account, and the far
side cannot tell one person from another. "Connect Jira as yourself" is not expressible.

The plane must never hold the value. That is not a preference; it is the property that
makes a compromised plane worth less than a compromised pod, and every part of this
design exists to keep it.

### Design

#### 3a. A mode on the entry

`mcp_servers[].credential_mode` is added to bundle schema 1, `"profile"` by default,
which is exactly today's behaviour and needs no migration of any published bundle.

* **`profile`** â€” unchanged. `credential_ref` names an environment variable, the operator
  writes a `secretKeyRef`, the pod reads it.
* **`person`** â€” `credential_ref` is not a variable name but a *slot* name. The value
  lives in OpenBao at `troupe/people/<subject>/mcp/<slot>`, and neither the plane nor
  the operator ever reads it.

A bundle may not set both a `secretRef` on the `WorkerProfile` and `person` mode for the
same server; the validator refuses it at publish, because a server with two credentials
is a server whose identity depends on which code path ran.

#### 3b. How a pod reads it, without the plane seeing it

We already do this once. `Troupe.KMS` puts a session's data key at
`troupe/teams/<team>/sessions/<id>` and the pod reads it with a credential scoped to the
team; the plane can destroy a key and cannot read one (`kms.ex:5-20,44`). The same
shape, one path up:

1. OpenBao gets a JWT auth role whose policy is templated:
   `path "troupe/people/{{identity.entity.aliases.<accessor>.metadata.sub}}/mcp/*" { capabilities = ["read"] }`.
2. At activation the plane mints a short-lived assertion through transit â€” the same
   signer that already mints session tokens (`plane/tokens/credential.ex`) â€” with the
   session's `owner_subject` as `sub` and OpenBao as the audience.
3. The pod exchanges it for a Bao token that can read exactly that person's slots and
   nothing else, and holds it in memory for the life of the session, as it already does
   for the data key.

A pod running Ann's session cannot read Bo's credential, because the assertion it holds
names Ann. A stolen plane mints assertions and reads nothing.

The GUI spec already reserves `troupe/people/<subject>/sessions/*` for private sessions
under the same auth method. This is the second tenant of a path shape we had already
decided on, which is the argument for it being the right one.

#### 3c. How a person connects

`me.connections.list` and `me.connections.grant` on the harness API. `grant` does **not**
take a value. It returns a short-lived Bao token scoped to the caller's own slot, and the
client writes the value to OpenBao directly â€” the same presign shape the GUI spec uses
for private-session objects, and for the same reason: the plane is not on the path of a
secret it is not allowed to see.

`me.connections.revoke` deletes the slot. Deletion is the person's, always; an admin can
retire the server from the bundle but cannot read or remove somebody's credential, and
the panel says so where it lists who has connected.

#### 3d. When nobody has connected

The tool exists and answers with a reason rather than failing at the transport:

```json
{"error": "not_connected", "server": "jira",
 "hint": "connect Jira in Troupe under Connections, then ask again"}
```

A structured refusal the model can read and relay, not a 401 it will retry four times.
This is OpenWork's `needs_connection` idea arriving as a tool result instead of a search
hit, which is the right place for it in a system where the tool list is already known.

#### 3e. Two things to be explicit about

* **A session has one identity.** If two people are attached and the server is
  person-mode, calls go out as the session's **owner**, fixed at activation and recorded
  in `session_created`. A collaborator acting through somebody else's credential is a
  thing people should be told once, in the panel and in the log, rather than discover.
* **This is not taint.** `session_tainted` is for a server a *client* registered — the
  app that carried that registration is gone (`DECISIONS.md` 320), and the event now
  lives in `Troupe.Session.ClientTools`, `Troupe.Log.Fold` and `Troupe.Session.Summary`;
  this one an admin published. What the log does gain is
  `identity` on the MCP call event â€” `"profile"` or `"person:<subject>"` â€” so a reader
  can tell which credential a call used without knowing what the bundle said that day.

### Done items

1. A profile-mode server behaves exactly as today; the operator renders the same env.
2. A person-mode server with no connection returns `not_connected` with a hint, and the
   session continues.
3. After `me.connections.grant` and a direct write, the same tool call succeeds, and the
   MCP call event records `identity: "person:<subject>"`.
4. A pod holding session A's assertion is refused by OpenBao when it asks for the slot of
   session B's owner.
5. The plane's logs and audit rows contain no credential value, proven by the same
   redaction test the audit module already has.
6. A bundle setting both a `secretRef` and `person` mode is refused at publish, with the
   reason.

---

## 4. Trigger revisions

### The problem

`trigger_runs` points at the mutable `triggers` row (`triggers/run.ex:28-37`). Editing a
prompt template rewrites the provenance of every run that used the old one. The rendered
prompt does survive in the session's own log, so the *content* is not lost â€” but which
template produced it, under which terms, as which principal, is.

This is small, and it is the item on the list that becomes impossible rather than merely
harder if it is left: history that was never recorded cannot be backfilled.

### Design

```
trigger_revisions
  trigger_id   references triggers on delete: :delete_all
  revision     integer, monotonic per trigger
  hash         "sha256:â€¦" over canonical JSON of the fields below
  profile, agent, principal_id, prompt_template, terms,
  concurrency, review, notify, source
  created_by, inserted_at         â€” no updated_at; a revision is immutable
  unique on (trigger_id, revision) and on (trigger_id, hash)
```

* **Content-addressed, like a bundle.** `Troupe.Protocol.Canonical` already gives us a
  stable encoding and `Bundle.hash/1` already establishes the convention. `trigger.put`
  that changes nothing creates no revision, and an admin who edits back to a previous
  wording lands back on that revision rather than making a third â€” the same argument the
  bundle makes, reached the same way.
* `trigger_runs.revision_id`, not null for new rows. A backfill creates revision 1 for
  every existing trigger from its current row and points every existing run at it, which
  is honest: revision 1 is what we can prove, and it is labelled as reconstructed.
* `Triggers.fire/4` reads the revision, renders from it, and passes its terms
  (`triggers.ex:214-247`). The scheduler resolves the current revision when a trigger
  comes due, so a firing that overlaps an edit uses one or the other and never a mixture.
* `state_of/2` is unchanged: a run's live state still comes from the session's status
  columns, because a run that had to be told its session finished would be a second copy
  of a fact the index holds.
* `Audit` already records `trigger.put` with a diff; the detail gains the new revision id
  and hash, so the audit row and the revision point at each other.

The panel shows a run with the revision it ran and a diff against current, which is the
question a person reviewing a bad run actually has.

### Done items

1. Editing a template creates revision 2; the previous run still reports revision 1 and
   its text.
2. Editing back to the original text creates no third revision and the next run reports
   revision 1.
3. Every pre-existing run points at a reconstructed revision 1 after migration.
4. A trigger firing while an edit commits produces a run naming exactly one revision.

---

## 5. Proving it on a cluster

### The problem

`REPORT.md` says it plainly: nothing built in stages 3 to 5 has run on Kubernetes. The
charts lint, render and pass `kubeconform`; the operator's resources are unit-tested;
every cluster-dependent test skips. `scripts/remote-up` builds the whole thing on kind
and is run by hand, occasionally, by one person.

What is missing is not the environment. It is a suite that makes a claim about it, and
something that runs that suite without being asked.

### Design

#### 5a. One command, one tag, outside the unit suite

`mix troupe.e2e` runs `test/e2e/**`, tagged `:e2e` and excluded from `mix test` by
default. It takes a kubeconfig context from the environment and refuses to run against a
context whose name is not the one `scripts/remote-up` created, unless told otherwise â€”
an end-to-end suite that deletes pods must not be one `KUBECONFIG` away from doing it
somewhere real.

#### 5b. Three words worth borrowing

OpenWork's eval framework has a vocabulary we lack, and it is the useful part:

* a **world** is a setup that creates concrete resources and owns exactly what it
  created â€” here, an `ExUnit` `setup` returning a handle with an `on_exit` that removes
  the namespace it made and never the cluster it attached to;
* a **witness** is a deterministic stand-in that records what it saw. This is already
  our word â€” `Troupe.Log.Fold` calls its projection a witness for exactly this reason
  (`log/fold.ex:18-22`) â€” and we already have the provider one:
  `Troupe.LLM.Providers.Fake` (`llm/providers/fake.ex`), which the bench already drives.
  In the cluster it runs with its script in a ConfigMap and its transcript read back, so
  "the model was called with the skill in its prompt" is an assertion rather than an
  inference;
* a **fault** is a declared misbehaviour. On a cluster: `kubectl delete pod`, a
  NetworkPolicy that denies the plane, a Secret removed from under a running pod.

And the rule that makes the whole thing worth the trouble, which they state and we
should adopt verbatim: **a passing response is not proof that an action was blocked.**
Every negative done item is proven by an independent witness â€” an egress test shows the
connection failing *from inside the pod*, not that a `CiliumNetworkPolicy` object exists.

#### 5c. What only a cluster can decide

Most faults are cheaper in-process. The BEAM lets us kill a supervisor child, disconnect
a node and partition a cluster in a unit test, and stages 1 to 5 already do. The e2e
suite should cover only what Kubernetes itself decides, which is a short list and should
stay short:

| Claim | Fault or witness |
| --- | --- |
| A pod enrols as the profile its namespace names, and cannot claim another | Enrol with a token from the wrong namespace; expect refusal |
| A pod fetches its bundle by hash from a real plane and materialises it once | Publish v2 while a session runs; the running one keeps v1, the next moves |
| Cilium egress admits the bundle's MCP host and refuses everything else | `curl` from inside the pod to an allowed and a denied host |
| An MCP credential arrives as `secretKeyRef` and is optional when absent | Delete the Secret; the pod starts and the server's tools are missing |
| A cron trigger fires on the minute as a service principal | A clock and a witness provider; assert one session, one prompt |
| A session survives its pod being deleted | `kubectl delete pod`; reattach; the log continues from the same head hash |
| A2A `message/send` reaches a pod through the facade and an artifact verifies | The facade in the cluster, a real WebSocket, a hash mismatch injected |
| Helm upgrade from the previous chart version leaves running sessions running | `helm upgrade` mid-session |

The last one is the item OpenWork tests and we do not, and it is the one that hurts most
in production.

#### 5d. CI

A `cluster` job on `ubuntu-latest`: `kind`, `helm` and `kubectl` are all available there,
and the images the `images` job already builds are `kind load`ed rather than pushed. It
runs on pushes to `main` and on tags, not on every branch, because it is slow and the
quality gate on every push is what keeps the loop tight. It uploads the operator's and
plane's logs on failure, because a cluster failure that produces only an exit code is a
failure nobody will diagnose.

Two more small things, both cheap and both learned from reading their repository:

* **A machine-readable outbound allowlist.** One file naming every host each component
  dials, with the component that owns it, checked in CI against the chart's egress
  policy and the `TroupePolicy` CRD's defaults. We already enforce egress; what we lack
  is one place that answers "what does this thing dial" without reading three files.
* **Ten runs is our flake detector and it only covers the unit suite.** The e2e suite
  runs once; a nightly job runs it three times and reports which test failed at least
  once, so a flake is named rather than retried.

### Done items

1. `mix troupe.e2e` against a `scripts/remote-up` cluster passes every claim in the table
   above, from a clean cluster, twice in a row.
2. Each negative claim is proven from inside the pod, not from the presence of an object.
3. CI runs the suite on `main` and uploads plane and operator logs on failure.
4. `REPORT.md`'s "nothing has run on a cluster" paragraph is deleted and replaced by the
   command output.

---

## Order of work

1. **Trigger revisions** first. It is the smallest, it is the only one that gets harder
   with every day of runs recorded against a mutable row, and it touches nothing else.
2. **Token accounting**, because a paying team asks for it first and because every part
   of it except the call site already exists.
3. **Entitlements**, because part 3 wants a narrowed offering to attach a credential mode
   to, and because it is the one an admin will notice.
4. **Personal credentials**, which needs part 3's resolution and OpenBao's second auth
   role.
5. **The cluster suite** last in the list and first in usefulness â€” it can start in
   parallel with any of them, and each of the four above should land its own e2e claim
   rather than wait for a suite that does not exist yet.

## What this plan deliberately does not do

* **No rollup pipeline.** Raw records and a cache until the row count says otherwise, and
  a number in `REPORT.md` saying when otherwise is.
* **No price table.** The gateway prices the call; the nightly reconciliation is what
  makes trusting it safe.
* **No new dependency.** ETS and `persistent_term` are what this repository already uses
  for caching (`a2a/plane/cache.ex`, `worker/bundles.ex:119`, `plane/oidc.ex:127`), and a
  cache library would be a supervision tree we did not write for behaviour we do not need.
* **No second grant hierarchy.** One child table on the grant we have, where absence
  means everything, so the migration is a no-op and the old behaviour is the default.
* **No push channel to harness clients.** Status stays columns and filters, as stage 5
  decided; a spend figure is read, not pushed.

## Open questions

* Does the deployed LiteLLM return `x-litellm-response-cost` on streamed responses, or
  only on buffered ones? If only buffered, the cost arrives on a follow-up call to the
  gateway's spend endpoint and `Reconcile` becomes the primary source rather than the
  check. Answer this before part 1 starts; it is the one assumption the whole part rests
  on.
* Should `usage_seq` also gate sealing? A session sealed before its usage is acknowledged
  is recoverable from the sealed segments, but it is a slower fold. Probably not worth
  coupling two things that fail independently.
* Entitlements on a *person* as well as a team. The grant is a team's; OpenWork can grant
  to an individual. Deferred deliberately â€” a team of one is the answer until somebody
  shows a case it does not fit.
* Whether `me.connections.*` belongs on the harness API or on a separate surface. The
  harness API is a fleet API and a credential is not a fleet fact, but a second surface is
  a second door and the boundaries rule exists to keep the count down.
