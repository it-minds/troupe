# Troupe 1.0 — the collected plan

Two repositories, five stages each, and a September 2026 read of seventeen competitors
later, this is what stands between where Troupe is and a release somebody can buy.

It is one plan and not a merge of two. The stage plans in each repository were written
when the question was "does this work". The question now is "is this a product", and
those are different questions with different leftovers: a harness can be correct and
still have no way for an administrator to see what it is doing, no way for a second
person to watch a session, and no story at all for the developer who has one laptop and
no cluster.

Nothing here weakens an invariant. `../../spec.md` and `../../clients/gui/spec.md`
stay the authority; three decisions are revised and each is named, with the reason, in
[Decisions this plan revises](#decisions-this-plan-revises).

---

## Where the three faces stand today

Troupe has three faces and they are at three different heights.

| face | what it is | where it is |
| --- | --- | --- |
| **The harness** | `troupe_core`, `troupe_worker`, `troupe_protocol`, `troupe_gateway`. Session actors, the hash-chained log, the mount table, the sandbox, bundles, skills, MCP, sealing. | Done and proven. Stages 1, 2, 4 and 5 are green and the log format has survived five releases of upcasters. |
| **The platform** | `troupe_plane`, `troupe_operator`, `troupe_a2a`. Identity, teams, grants, placement, budgets, the object tier, the Kubernetes operator, triggers, service principals, the A2A facade, the ledger. | Done and proven for a cluster. Stage 6 parts 2–5 are not built, and nothing has been proven *on* a cluster end to end. |
| **The client** | `troupe-gui`: `@troupe/client`, the desktop app. | Stage 1, 2 and 4 built and deployed against a live plane; stage 3 (private sessions) not built; the admin views have no tests and have never run against a real plane. |

The uneven bit is not the harness. It is everything a person or an administrator touches.

### What is owed, counted

| owed | where it is written | size |
| --- | --- | --- |
| Entitlements below the profile | `../plans/stage-6.md` §2 | medium |
| Credentials that belong to a person | `stage-6.md` §3 | medium |
| Trigger revisions | `stage-6.md` §4 | small |
| The cluster e2e suite | `stage-6.md` §5 | medium |
| Private sessions, end to end | `../../clients/gui/docs/plans/local-and-private-sessions.md` | large |
| Client-hosted MCP servers in the GUI | `clients/gui` stage 2, done item 5 | small |
| Identity and Integrations as their own screens | `admin-surface.md`, "what is still owed" | medium |
| The erase dialog's full text | `admin-surface.md` | small |
| Audit's integrity tab | `admin-surface.md` | small |
| Bundles as a diff | `admin-surface.md` | small |
| A settings surface for the operator's own config | `admin-surface.md` | small |
| A fake plane, so the admin views can be tested | `clients/gui` stage 4, known limitations | small |

That list is the floor. Everything below it is new.

---

## What 1.0 is

**A remote agent orchestration platform, a harness, and a control panel** that one
organisation can run for itself, and that one developer can run on one machine without
asking anybody for a cluster.

Five promises, and each is a thing that can be refused or proven:

1. **A session is a durable object, not a process.** It survives its pod, its machine,
   its client and its operator. It can be read without being run, forked without being
   copied, and erased so that no backup can recover it.
2. **One person opens one client and sees everything they may see** — the team's sessions
   on workers, their own on this machine, and their own private ones that followed them
   from the last machine — in one list, in one sign-in.
3. **A second person can be invited into a session, at a grade**, and everyone can see
   who is there.
4. **Anything may start a session** — a person, a clock, a webhook, a CI step, an API
   call, another agent — and every one of those produces the same auditable object with
   a named human answerable for it.
5. **An administrator can configure the whole product from one console**, see where every
   effective value came from, read the diff before applying it, and find the audit record
   afterwards. What the console can do, the API, the CLI and a model over MCP can do; what
   none of them can do is read session content.

## What 1.0 is not

Not multi-cluster. Not autoscaling. Not a hosted service with tenants — one deployment is
one organisation. Not a marketplace. Not mobile. Not a place where session content is ever
readable by an administrator, and the break-glass that would make it so stays out of scope
and stays refused.

---

## The seven workstreams

| | workstream | one line | size | depends on |
| --- | --- | --- | --- | --- |
| **W1** | [Finish the floor](#w1--finish-the-floor) | Everything already planned and not built, including the private-session storage path and the cluster suite that proves the last three stages. | large | — |
| **W2** | [One trigger, one principal](#w2--one-trigger-one-principal) | Every way of starting a session becomes one content-addressed object, and every actor becomes a subject-and-actor pair with a human answerable for it. | medium | W1's trigger revisions |
| **W3** | [Sessions people share](#w3--sessions-people-share) | Fork at a sequence number, a share link with a grade, and presence — the one thing worth a push channel. | medium | W2's principals |
| **W4** | [The substrate widens](#w4--the-substrate-widens) | A worker is behind an interface, so it can be an SSH host and not only a pod; and a workspace is built once per bundle hash, not once per session. | large | W1's e2e suite |
| **W5** | [Interop](#w5--interop) | The daemon speaks ACP; the platform exposes itself over MCP; A2A keeps the external agents. | medium | W2 |
| **W6** | [The console](#w6--the-console) | One surface that configures the whole product, with a ladder that says which scope decided each effective value. See [`docs/control-panel.md`](control-panel.md). | large | a screen per workstream, landing with it |
| **W7** | [Release](#w7--release) | What 1.0 means as a command that either passes or does not. | medium | all |

---

## Threads that run through all seven

* **The log is the record; everything else is a projection.** A fork is an event. A share
  is an event. A trigger firing is an event. A console change is an audit event with a
  diff keyed by path. Nothing in this plan adds a second source of truth, and every table
  it adds can be rebuilt from something durable.

* **Idempotency is content-addressing.** A bundle is its hash. A trigger revision is its
  hash. A usage record is the gateway's request id. A workspace image is its bundle's
  hash. The argument is the same every time: two systems that must agree join on something
  neither of them invented.

* **A principal is a pair.** Every durable event, every outbound call and every audit row
  carries the subject whose authority was used and the actor that used it. Where they are
  the same, they are written the same. Where they differ — a trigger, a delegated
  credential, a service principal — the difference is the fact somebody will need.

* **Absence means everything; deny wins.** The rule stage 6 landed on for entitlements
  becomes the rule for the whole policy ladder. A scope with no rows restricts nothing; a
  deny at any scope beats an allow at every other. The safe reading is the one that grants
  less, and the two ways of writing the same intent must not disagree.

* **Nothing is applied until its diff has been read.** True today for a profile. Becomes
  true for a bundle, a policy, a trigger, a provisioner and a budget, computed by the same
  function that writes the audit record — so the thing you approved and the thing in the
  trail are the same object.

* **Four renderings, and now a fifth check.** `Troupe.Plane.Admin` is the console, `/rpc`,
  `troupe admin` and `POST /mcp`. The parity test proves the last four agree. It does not
  prove the *console* has a screen, which is why `admin.profile.put` exists in the client
  and is reachable from nothing. W6 adds that assertion.

---

## W1 — Finish the floor

### Brings, takes, already in place

**Brings.** Everything the two repositories already decided and did not build. A team can
be given part of a bundle. A person's own credential authenticates their own MCP calls. A
trigger run names an immutable revision. A private session survives a lost laptop. And the
claims of stages 2 through 5 are proven on a cluster rather than in a unit test.

**Takes.** One child table on the grant; a second OpenBao auth role; a hash column on
trigger runs; the worker's `Sealer` moved down into `troupe_protocol`; three plane methods
for private sessions; and a `mix troupe.e2e` that runs against a real cluster.

**Already in place.** Almost all of it, which is why this is a workstream and not a
quarter. `Troupe.Log.Fold` already calls its projection a witness; `Troupe.LLM.Providers.Fake`
already drives the bench; `Troupe.Worker.Session.Sealer` already writes segments,
snapshots, workspace tars and blobs with a plaintext manifest; `Troupe.Worker.Session.Restore`
already ignores the recorded workspace path and rebuilds under a fresh directory; the
plane's `sessions` row already allows a null `team_id` and requires `owner_subject`;
`Troupe.Plane.Bundles.offering/1` is already the single place a session's offering is
computed.

### What is missing today, precisely

| gap | where |
| --- | --- |
| A grant is one row and carries no entitlements | `priv/repo/migrations/20260101000001_identity.exs:81-93` |
| `Bundles.offering/1` takes no resolved set, so every grant of a profile grants the whole bundle | `Troupe.Plane.Bundles` |
| No OpenBao role for a person; only `troupe/teams/<team>/…` exists | `stage-6.md` §3 |
| A trigger run points at a mutable row | `apps/troupe_plane/lib/troupe/plane/triggers/run.ex` |
| The `Sealer` is in `troupe_worker`, so the daemon cannot use it | `apps/troupe_worker/lib/troupe/worker/session/sealer.ex` |
| The plane has no `session.register`, `session.seal-report` or `session.presign` | `Troupe.Plane.Harness` |
| The GUI's **Keep it private** control is gated on a `private_sessions` capability no daemon reports | `clients/gui` stage 3 |
| Client-hosted MCP servers are implemented in `Troupe.Session.ClientTools` and offered by no client | `apps/troupe_core/lib/troupe/session/client_tools.ex` |
| Nothing has run on a cluster | `../history/REPORT.md` |

### Design

#### 1a. Stage 6 parts 2 to 5, as written

They are written, they are right, and this plan does not redesign them. Two corrections
only:

* **`stage-6.md` §3e points at a file that no longer exists.** It cites
  `tui/connectors.ex:5-8` for where `session_tainted` is raised for a client-registered
  server. The TUI and CLI apps were deleted (`DECISIONS.md` 320) and the taint now lives in
  `Troupe.Session.ClientTools`, `Troupe.Log.Fold` and `Troupe.Session.Summary`. The
  distinction the section draws — a server a *client* registered versus one an *admin*
  published — is unaffected and still the right one.
* **Part 2's "no entitlements on a person" is revised by W2.** See
  [Decisions this plan revises](#decisions-this-plan-revises).

#### 1b. Private sessions: the daemon gets the sealer, not a copy of it

`Sealer`, `Storage`, `Cipher` and the segment/snapshot/manifest format move from
`troupe_worker` into `troupe_protocol`, which both the worker and the daemon already
depend on. This is a move and not a fork: the test that proves it is that a session sealed
by a daemon restores on a worker and a session sealed by a worker restores in a daemon,
byte for byte through the same code.

The key path gains `troupe/people/<subject>/sessions/<id>` and OpenBao gains a JWT auth
role `troupe-person`, bound to the identity provider's issuer, with a policy templated on
the subject. No pod role can read under `people/`. The plane's delete-only policy widens to
cover it, which is what makes erasure possible without making reading possible.

#### 1c. The capability gate is the right shape and stays

The GUI shows **Keep it private** only when the daemon's `initialize` reports
`private_sessions`. That is correct and is the pattern every later capability in this plan
follows: a client offers a control when the server it is talking to says it has the thing,
and never because the build was compiled with it. W5's ACP support, W3's sharing grades and
W4's provisioners are each announced the same way.

#### 1d. The e2e suite, and the vocabulary that comes with it

`mix troupe.e2e` as `stage-6.md` §5 specifies it — tagged, excluded from `mix test`, and
refusing to run against a kubeconfig context it did not create. The three borrowed words
(**world**, **witness**, **fault**) and the rule that makes them worth it —
*a passing response is not proof that an action was blocked* — apply to every negative
claim in this whole plan, not only to stage 6's.

Two additions to §5's table, both from things this plan adds:

| claim | fault or witness |
| --- | --- |
| A session forked on a pod has a log whose first event names the parent's head hash | Fork, then `troupe ctl verify` both chains |
| A provisioner that is not Kubernetes places a session and seals it to the same object layout | An SSH worker in the `world`; restore it on a pod |

### Done

1. `mix troupe.e2e` passes every claim in `stage-6.md` §5 plus the two above, from a clean
   cluster, twice in a row.
2. Every negative claim is proven from inside the pod, not from the presence of an object.
3. A session sealed by the daemon restores on a worker, and the reverse, through the same
   `Sealer`.
4. A pod's KMS token cannot read a key under `people/`; a person's JWT token cannot read
   one under `teams/`; the plane's token can delete metadata under both.
5. The GUI offers **Keep it private** because a daemon reported the capability, and the
   session it creates opens on a second machine with its chain verified and no agent
   started.
6. A personal MCP server from `mcp.json` is registered after the consent challenge, served
   through `tool.invoke`, and shows as `session_tainted` to a second client.
7. `../history/REPORT.md`'s "nothing has run on a cluster" paragraph is deleted and
   replaced by command output.

---

## W2 — One trigger, one principal

*Folds in landscape items 2, 3, 6, 8 and 12.*

### Brings, takes, already in place

**Brings.** Six ways to start a session that are one object in the log, one row in the
console and one line in the audit trail. An answer to "who did this, and on whose
authority" that does not depend on knowing what the bundle said that day. A spend ceiling
that can be a person's and not only a team's. And a policy ladder where an administrator
can see which scope decided each effective value.

**Takes.** A source discriminator and a revision hash on one event; a second field beside
`identity`; a sponsor column on service principals; a second counter in a process that
already exists; and a resolution function with a test per rung.

**Already in place.**

* `Troupe.Plane.Triggers` already has a scheduler, a cron parser, a template and a run
  record, and the scheduler is already a `Singleton` (`apps/troupe_plane/lib/troupe/plane/triggers/`).
* Service principals exist and are already the caller for triggers and the A2A facade
  (`Troupe.Plane.Principals`).
* `TeamBudget` already holds `spent_micros` in process state and moves it on a
  non-duplicate ledger record (`team_budget.ex:112-125`).
* `Ledger.record/1` is already idempotent on the gateway's request id (`ledger.ex:33-46`).
* `Troupe.Plane.Settings` already has an override table, a registry with a declared type
  and consequence per setting, and a five-second cache.
* The A2A facade already turns an external agent's `message/send` into a session.

### What is missing today, precisely

| gap | where |
| --- | --- |
| A cron run, an A2A task and an operator's "run now" produce three different shapes | `triggers/run.ex`, `troupe_a2a`, `Admin` |
| There is no webhook ingress at all, and no CI entry point that is not the plane API | — |
| A run names a mutable trigger row | `triggers/run.ex` |
| `identity` on an MCP call event is one value, so a delegated call cannot be told from a profile call by a reader | `stage-6.md` §3e |
| A service principal has no sponsor, so an automated run has nobody answerable for it | `Troupe.Plane.Principals` |
| A budget belongs to a team and to nothing else | `migrations/…_identity.exs`, `team_budget.ex` |
| Settings have one scope: the plane | `Troupe.Plane.Settings` |
| Nothing lets an agent inside the system start a sibling session without going out through the A2A facade | `troupe_a2a` |

### Design

#### 2a. `trigger_fired`, and six sources that are one event

Every ingress normalises into one durable event on the created session's log:

```json
{"type": "trigger_fired",
 "source": "schedule" | "webhook" | "integration" | "ci" | "api" | "manual" | "agent",
 "revision": "sha256:…",
 "principal": {"subject": "person:ada@…", "actor": "principal:nightly-triage"},
 "idempotency_key": "…",
 "payload_digest": "sha256:…"}
```

`revision` is the content hash of the trigger document as it was when the run started, and
the document at that hash is stored beside the bundle it names — which is `stage-6.md` §4
generalised from the scheduler to all six sources. `payload_digest` is a hash and not a
payload, because a webhook body is content and content does not cross into the plane.

**The custom-integration framing is copied on purpose.** Warp's rule is that you own the
webhook and the filtering and you call the platform's API, and what you get is a first-class
run. Troupe's version: `POST /trigger/<id>` with the trigger's own key, and `trigger.fire`
on `/rpc` for anyone holding a principal's credential. Both mint the same event. There is no
second-class run, and no path that skips the grant, the budget or the retention policy.

The scheduler stays a `Singleton`. The webhook ingress is stateless and any replica answers.
Idempotency is the caller's key where they supply one and the revision-plus-window where
they do not, which is what `triggers/run.ex` already does for cron and is now the general
rule.

**One thing the webhook must not do**, learned from someone else's scar: LangGraph shipped a
2026 advisory because a relative webhook target could reach an in-process route without
authentication. Troupe's outbound webhook targets — the notification half — are absolute,
validated against the egress allowlist at save time and again at send time, and loopback is
refused. The test is a negative one and is proven by the request failing *from inside the
pod*.

#### 2b. Subject and actor, and a sponsor who is a person

`identity` on the MCP call event becomes a pair, and the same pair goes on every durable
event's `actor` field and every audit row:

```json
"principal": {"subject": "person:ada@example.com", "actor": "principal:nightly-triage"}
```

Where a person is acting for themselves the two are equal and are written both times, so a
reader never has to know whether the field was omitted because they matched or because
nobody wrote it.

**Every service principal names a sponsor**, and the sponsor is a person in a granted team.
A principal whose sponsor has left the identity provider is disabled at the next SCIM push,
its triggers stop firing, and the console reports it as needing a sponsor rather than as
broken. This is the half of Entra Agent ID worth taking: not the object model, which is
four types where Troupe needs one, but the attribute that makes an automated run have
somebody answerable for it.

Two consequences worth stating, because they are the ones people discover otherwise:

* A trigger's spend is the sponsor's team's spend, and now also counts against the
  sponsor's own cap (2c).
* A delegated MCP call — `stage-6.md` §3's person-mode server — writes
  `subject: person:…, actor: principal:…` and the console's Connections panel says so where
  it lists who has connected. A collaborator acting through somebody else's credential is
  something people should be told once, not discover.

#### 2c. A cap is a ceiling at any scope, and the tightest one wins

`TeamBudget` gains a sibling: `PersonBudget`, one process per subject, same shape, same
durable source (the ledger), same idempotency. A reservation must clear every ceiling that
applies:

```
deployment cap ≥ platform cap ≥ team ceiling ≥ person cap ≥ session slice
```

The tightest binding ceiling refuses, and the refusal names which one, because "budget
exhausted" without a scope is a support ticket. A scope with no cap set does not
participate — absence means everything, exactly as an entitlement's absence does.

This is the market's shape (Cowork's most-restrictive precedence with an org cap that beats
a seat cap; Warp's individual credit caps beside per-team billing) and it is cheap here
because the hot path already holds its counter in a process and already moves it on a
non-duplicate record.

#### 2d. The policy ladder, and the view that explains it

Settings today are two rungs: what the deployment decided, and the override table. This adds
three:

| rung | owner | written by | example |
| --- | --- | --- | --- |
| deployment | whoever installs the chart | Helm values, env | issuer, client id, base URL, workers domain |
| platform | a platform admin | `platform_settings` | admin group, provisioning mode, default team retention |
| team | a team admin, within the platform's floor | `team_settings` | idle timeout, default visibility, whether pins are allowed |
| profile | a platform admin | the `WorkerProfile` spec | egress hosts, MCP servers, org mount |
| session | resolved at create | `session_created` | the entitlement set, the mount table |

Two rules make a ladder safe:

* **A lower rung may only narrow.** A team cannot raise a ceiling the platform set, cannot
  allow an MCP server the platform denied, and cannot lengthen a retention the platform
  shortened. The resolver enforces it and the console shows the floor beside the field.
* **Deny wins from any rung**, which is `stage-6.md` §2's rule promoted from one table to
  the whole ladder.

Two switches come with it, both taken directly from Claude Code's managed settings because
they are the two an administrator actually asks for:

* `managed_permission_rules_only` — a session's own permission rules are ignored; only the
  platform's apply.
* `managed_mcp_servers_only` — a client may not register a personal MCP server at all, and
  `tools.register` refuses with a reason rather than a transport error.

And the thing that makes the ladder usable rather than merely correct: **an effective-value
view** that, for any setting, names the value, the rung that decided it, and every rung that
had an opinion. That is a console feature and it is specified in
[`docs/control-panel.md`](control-panel.md).

#### 2e. The platform as a tool surface

`POST /mcp` already projects `Troupe.Plane.Admin` for administrators. A second, much smaller
projection serves the *agent* inside the system: `session.create` on a sibling, `session.get`,
`trigger.fire`, `sessions.list` within what the caller may see. The guardrail is the one that
already exists — entitlement resolution runs at create — so a spawned session cannot exceed
its parent's offering, its team's grant, or any ceiling on the ladder.

This is the seventh source in 2a (`agent`), and it is why the A2A facade stays what it is:
A2A is for an agent that is not ours, coming in from outside with its own card and its own
artifacts. This is for the one already inside, which the facade handles awkwardly because it
has to mint a principal to talk to itself.

### Done

1. A schedule, a webhook, a CI call, an API call, a manual run, an A2A task and an in-system
   agent each produce a session whose first events are identical but for `source`, and one
   `sessions.list` filter finds all seven.
2. Editing a trigger after a run leaves the run's `revision` resolving to the old document,
   and the console shows the run against what it actually ran.
3. An outbound webhook target that resolves to loopback is refused at save and, if one gets
   through, fails from inside the pod.
4. A service principal with no sponsor cannot be enabled; a principal whose sponsor is
   removed by SCIM stops firing within one push and the console says why.
5. An MCP call through a person-mode server writes both halves of the principal, and the
   console's Connections panel names the credential's owner and the session's owner
   separately.
6. A person at their own cap is refused inside a team that is under its ceiling, and the
   refusal names the person's cap.
7. For a setting decided at three rungs, the effective-value view names the winner and the
   two losers, and a team's attempt to widen it is refused with the floor quoted.
8. With `managed_mcp_servers_only`, `tools.register` refuses with a reason the model can
   relay, and nothing is registered.
9. An agent creates a sibling session over MCP, and the sibling's offering is a subset of
   the parent's — proven by asking for an agent the parent could not run.

---

## W3 — Sessions people share

*Folds in landscape items 4 and 5.*

### Brings, takes, already in place

**Brings.** Two things no competitor has together. A session can be **forked** at a
sequence number, so an attempt is a branch of a conversation rather than a re-run of one.
And a session can be **shared with a grade** — watch, or watch and prompt — with everyone
able to see who is there.

**Takes.** One event type, one restore path that already exists, a share table on the plane,
and one narrow push channel for the only fact whose value is being under a second stale.

**Already in place.** More than it looks.

* Several harnesses on one session is stage 4 and is done: inputs enter one mailbox, the log
  order is the order everyone sees, approvals are first-wins with `approval_resolved` naming
  who won, and presence is already defined as ephemeral-only.
* ACLs are already durable events (`acl_granted`, `acl_revoked`), mirrored to the plane and
  applied immediately to connected clients.
* `Restore` already ignores the recorded workspace path and rebuilds the tree under
  `<state>/workspaces/<session_id>`, which is the expensive half of a fork.
* Roles already map to scopes: owner → admin, collaborator → control, viewer → observe.

### What is missing today, precisely

| gap | where |
| --- | --- |
| There is no fork. A second attempt is a second session with no relationship to the first | — |
| An ACL is a list of subjects, not a link somebody can be given | `Troupe.Plane.Sessions` |
| Presence is specified and has no transport to a client that is not already attached | stage 4 |
| The GUI's fleet row has no notion of who else is in a session | `clients/gui` `FleetRow` |
| A private session cannot become a team session | `../../clients/gui/spec.md`, out of scope |

### Design

#### 3a. A fork is an event, and the parent does not change

```json
{"type": "session_forked", "seq": 0,
 "parent": {"session_id": "…", "seq": 4120, "head_hash": "sha256:…"},
 "reason": "attempt" | "branch" | "import"}
```

The child's log opens with it and continues. Reading the child's history means folding the
parent's chain to `seq` and the child's chain after it, which is the same fold the reader
already does across sealed segments — a fork adds one indirection to a walk that already
handles many.

The workspace is restored from the parent's nearest snapshot at or before `seq`, into the
child's own prefix. The parent is untouched and does not learn it was forked; the plane's
session row carries `parent_session_id` so the console can draw lineage without reading a
log.

**Why this is cheap here and expensive everywhere else.** Orca forks sessions, Zed runs
parallel threads, and every control surface in the landscape re-runs from scratch and diffs
the results — because none of them has a log. The fold is already the product; a fork is a
second cursor into it.

Three rules keep it honest:

* **A fork inherits the parent's entitlement set as recorded in `session_created`**, not
  the bundle's current offering. A fork of an old session is not a way to get an agent your
  team was later denied.
* **A fork is a new session for budget, retention and erasure.** It has its own key, its own
  prefix and its own ceiling draw. Erasing a parent does not erase a child, and the console
  says so before the confirmation.
* **`reason: "import"` is how a private session becomes a team session**, which the GUI spec
  deferred and which now has a mechanism: fork the private session at its head into a team,
  under the team's key, with the fork event naming the person's session as parent. Nothing
  is merged and nothing moves; the private original stays the person's.

#### 3b. A share is a link with a grade

`session.share` mints a capability for a session at `observe` or `control`, bounded by the
session's team ACL — a link cannot admit somebody the team's grant would not. It is a
durable event (`share_created`, `share_revoked`), it expires, and it is listed in the
console and in the session itself.

The grades are the ones that already exist, and the naming is the one people use:

| grade | scope | what it is called |
| --- | --- | --- |
| watch | `observe` | Can watch |
| prompt | `control` | Can watch and prompt |

Approvals stay first-wins, which stage 4 already decided and which is the correct answer to
two people answering at once. A share never grants `admin`, so nobody arriving by link can
archive, erase or re-share.

#### 3c. Presence, and the one push channel this plan adds

Stage 6 decided: *"no push channel to harness clients. Status stays columns and filters; a
spend figure is read, not pushed."* That decision is right for spend and wrong for presence,
and this plan revises it narrowly — see
[Decisions this plan revises](#decisions-this-plan-revises).

The narrowness is the design:

* It carries **presence and nothing else**: who is attached, at what grade, which agent they
  are focused on, whether they are typing.
* It is **ephemeral by construction** — it has no `seq`, it is never persisted, and it is
  explicitly droppable, which is what stage 4 already says presence is.
* It rides the **summary subscription that already exists**, as a third topic beside `fleet`
  and `session:<id>`, so it adds no transport and no new authentication path.
* A client that never subscribes to it loses nothing but the avatars.

If it is dropped under load, the session is unaffected. That is the test: fill the outbound
queue, watch presence disappear, watch the transcript stay exact.

### Done

1. A session forked at seq 4120 renders the parent's history and the child's continuation as
   one transcript, and `troupe ctl verify` passes on both chains independently.
2. A fork of a session whose team later lost an agent still cannot run that agent.
3. Erasing a parent leaves the child readable, and the confirmation said it would.
4. A private session imported into a team appears as a team session whose first event names
   the private one, and the private original is unchanged and still the person's.
5. A watch link cannot send input; a prompt link can, and both appear in the session's own
   log and in the console.
6. A link for a person the team's grant would not admit is refused at mint, not at use.
7. Two clients see each other's presence within 500 ms; with the outbound queue saturated,
   presence stops and the event order is still identical on both.

---

## W4 — The substrate widens

*Folds in landscape items 9 and 11.*

### Brings, takes, already in place

**Brings.** The single-developer case, honestly. Today a worker is a pod and a pod needs a
cluster, so Troupe's first target shape — "feels like running your own instance" — is served
by the daemon alone, which has no placement, no bundles and no team. This makes a worker a
thing behind an interface, so the same session, the same bundle and the same seal work on a
machine somebody already has.

And it makes session start fast, by building the workspace once per bundle hash instead of
once per session.

**Takes.** A behaviour with three callbacks, a second implementation of it, a build job, and
a hash-named object beside the bundle.

**Already in place.** The boundary is nearly drawn already. The operator reconciles
infrastructure and the plane places sessions, and they talk through the `WorkerProfile` — a
document. Enrolment is a token and a namespace. The control channel is JSON-RPC and carries
no content. Nothing in placement knows what a pod is except through capacity and health
reported over that channel.

### What is missing today, precisely

| gap | where |
| --- | --- |
| `Troupe.Plane.Placement` reasons in pods and ordinals | `apps/troupe_plane/lib/troupe/plane/placement.ex` |
| Enrolment authenticates a projected ServiceAccount token and nothing else | `Troupe.Plane.Enrolment` |
| The operator is the only thing that can make a worker exist | `troupe_operator` |
| A session pays its bundle's install cost every time | `Troupe.Worker.Bundles` |
| Nothing names, builds or stores a workspace image | — |

### Design

#### 4a. A provisioner is a behaviour with three callbacks

```elixir
@callback ensure(profile :: Profile.t()) :: {:ok, [worker_ref]} | {:error, term}
@callback drain(worker_ref, timeout) :: :ok | {:error, term}
@callback describe(worker_ref) :: {:ok, %{capacity: …, health: …, version: …}}
```

`Kubernetes` is the first implementation and is the operator as it stands. `SSH` is the
second: a host in an inventory, reached with a key the plane holds a reference to, running
the same worker image under a container runtime or the release directly. Emdash's framing is
the right one and is worth copying — *your script creates the workspace, we connect to it* —
so the SSH provisioner's contract is a host that answers, not a host we built.

What does **not** change, and this is the whole point:

* Enrolment still proves the worker is the profile it claims. For Kubernetes that is a
  TokenReview against a namespace; for SSH it is a per-host enrolment secret issued at
  registration and rotatable from the console. Same method, same refusal.
* The control channel, the seal format, the object layout, the key paths and the session
  log are byte-identical. A session sealed by an SSH worker restores on a pod, which is a W1
  done item for exactly this reason.
* Placement reasons in **workers**, not pods. Capacity, health, drain state and disk
  watermark are reported the same way by both.

What does change, and must be said plainly in the console: **an SSH worker is outside
Kubernetes, so the guarantees Kubernetes was providing are not there.** No admission policy,
no NetworkPolicy, no Cilium FQDN egress, no PodDisruptionBudget. The console marks such a
profile `unenforced egress` and the policy ladder refuses to place a team on it unless a
platform admin has set `allow_unenforced_workers` for that team. The feature is for the
developer with one laptop and the team with one build box; it is not a way around the
policy, and the interface says so rather than implying otherwise.

#### 4b. A workspace image is named by its bundle's hash

A bundle is already content-addressed. Build its workspace once — clone, install, warm
whatever the profile's setup command warms — and store the result beside the bundle as
`bundles/<hash>/workspace.tar.zst`. A session restores it instead of running install.

Cursor's warning comes with it and is not a footnote: **a snapshot preserves disk and
nothing else.** Running processes, shell exports, in-memory caches and anything a setup
script started are out of scope, and `session_resumed` already exists to tell the model
exactly that. The build is a job on the profile's own provisioner, so it runs where the
session will run; a profile with no build recorded falls back to install, which is today's
behaviour and stays the floor.

Invalidation is free: a new bundle hash is a new image, and an old one is garbage-collected
with the bundle version it belongs to.

### Done

1. A profile provisioned over SSH places a session, runs a turn, seals it, and a pod of a
   Kubernetes profile restores that session from object storage with its chain intact.
2. An SSH host presenting another host's enrolment secret is refused, and the refusal is the
   same one a pod from the wrong namespace gets.
3. A team without `allow_unenforced_workers` cannot be granted a profile on an SSH
   provisioner, and the console explains which guarantee is missing.
4. Draining an SSH worker finishes its running turns, makes its sessions dormant and removes
   nothing from object storage.
5. Session start on a profile with a built workspace image is measurably faster than on the
   same profile without one, and both produce the same first `mounts_resolved`.
6. Publishing a new bundle version invalidates nothing in flight: a running session stays on
   its version, and the next session builds or fetches the new image.

---

## W5 — Interop

*Folds in landscape items 1 and 12.*

### Brings, takes, already in place

**Brings.** Troupe stops being an island in the one direction it currently is. Any ACP
editor drives a Troupe session; any of the 25-plus ACP agents runs as a Troupe subagent;
the platform is a tool surface for the agents inside it; and A2A keeps doing what it is good
at, which is agents that are not ours.

**Takes.** One adapter on a socket the GUI plan already adds, one adapter in the other
direction behind the subagent interface that already exists, and a capability announcement.

**Already in place.** The hard parts. `Troupe.Gateway.Web` is the same code a worker serves
and already runs on the daemon's loopback with a per-user token
(`apps/troupe_gateway/lib/troupe/gateway/web.ex`). Permission-gated tool execution is the
approval flow. Client-provided filesystem and terminal is `Troupe.Session.ClientTools` plus
the mount table. Streaming progress is `llm_delta` and `agent_state`. Sessions are sessions.

### What is missing today, precisely

| gap | where |
| --- | --- |
| The daemon's loopback socket speaks only Troupe's JSON-RPC | `apps/troupe_gateway/lib/troupe/gateway/web.ex` |
| A subagent is a Troupe agent definition from the bundle and nothing else | `Troupe.Session` |
| The A2A facade is the only way in for an agent, ours or not | `troupe_a2a` |

### Design

#### 5a. ACP on the socket that already exists

The daemon serves ACP on the same loopback WebSocket, selected at `initialize` by the
protocol the client announces. Not a second port, not a second authentication path, not a
second implementation of the session — an adapter that maps ACP's session, streaming update,
permission request and filesystem/terminal calls onto the ones underneath.

Three mappings carry it, and they are the reason this is an adapter and not a rewrite:

| ACP | Troupe |
| --- | --- |
| session, streaming updates | a session and its `subscribe` at `detail` |
| permission-gated tool call | the approval flow, including *allow for session* |
| client-provided filesystem and terminal | the mount table and `ClientTools`, under the same allowlists |

Two things ACP does not have and Troupe does not give up: the durable log stays the record,
and an ACP client that disconnects loses nothing, because the session is not its process.

**Why this is first on the landscape list.** Zed shipped ACP; JetBrains co-launched its
registry in January 2026; Google and GitHub are among adopters; 25-plus agents implement it.
The client-to-agent wire now has a non-proprietary default, and the choice is to make it
once or inherit it badly later. The cost here is one adapter on a socket the GUI plan was
adding anyway.

#### 5b. ACP in the other direction, so an external agent is a subagent

A bundle entry may name an ACP agent rather than a Troupe agent definition. The worker runs
it as a subprocess, speaks ACP to it as the client, and serves its filesystem and terminal
requests **through the mount table** — which is what makes this safe and is why it is worth
doing here rather than in a client. An ACP subagent gets the session's mounts at their
modes, not the pod's disk. Its tool calls raise approvals like any other. Its output lands
in the log as durable events like any other.

The bundle entry carries the agent's command and its hash; egress for whatever it dials is
the profile's egress, checked at admission like every other host. An ACP subagent in a
bundle is an entitlement like an agent or a skill, so `stage-6.md` §2's child table narrows
it for free.

#### 5c. What each protocol is for, written down once

The confusion this plan ends:

| protocol | direction | for |
| --- | --- | --- |
| **MCP** | Troupe as client | tools a session calls — a team's servers, a person's connected credential |
| **MCP** | Troupe as server | the platform as a tool surface: `POST /mcp` for administration (built), the small in-system projection (W2) |
| **ACP** | Troupe as server | an editor driving a session on this machine |
| **ACP** | Troupe as client | a third-party coding agent running as a subagent inside a session |
| **A2A** | both | agents that are not ours, with their own cards and artifacts, across an organisation boundary |
| **OIDC / SCIM** | inbound | who people are, and which groups they are in |

Nothing proprietary carries a boundary that a standard already covers, and nothing standard
is adopted where it would weaken the log.

### Done

1. Zed, configured with Troupe as an external agent, opens a session on the daemon, streams
   a turn, and answers a permission request; killing Zed mid-turn leaves the session running
   and the next client sees the whole turn.
2. An ACP agent named in a bundle runs as a subagent, its file reads resolve through the
   mount table, and a read outside the session's mounts fails the way any other does.
3. An ACP subagent the team is not entitled to is not in the session's offering and cannot
   be named.
4. `POST /mcp` answers `initialize` for an administrator and for an in-system agent with
   different tool lists, and the agent's list contains nothing destructive.
5. The protocol table above is in `PROTOCOL.md`, and a third-party author can write a client
   from it without reading Elixir — which is the standing rule and the standing test.

---

## W6 — The console

*Folds in landscape items 7 and 10, and every screen the six workstreams above need.*

This is the largest single piece of 1.0 and it has its own document:
**[`docs/control-panel.md`](control-panel.md)**.

The summary, so this plan reads straight through:

**The complaint.** The console configures the platform. It does not configure the product.
A bundle is a JSON document you paste; a profile is a spec you can edit but not on the
rung above it; a policy is an environment variable somewhere; a trigger is a cron line;
and `admin.profile.put` exists in the TypeScript client and is reachable from no screen at
all. Meanwhile four workstreams above add objects — trigger revisions, principals with
sponsors, person caps, policy rungs, provisioners, shares, forks, workspace images — and
every one of them needs somewhere to live.

**The shape.** Eleven screens become fifteen, organised by what an administrator is
actually doing rather than by which table the data is in:

| group | screens |
| --- | --- |
| **Watch** | Overview · Sessions · Review · Audit |
| **Configure** | Policy · Bundles · Profiles · Triggers · Teams · Identity · Integrations |
| **Operate** | Fleet · Provisioners · Budgets · Connections |

**The four rules that make it a console rather than a set of forms.**

1. **Every effective value names the rung that decided it.** The ladder from W2 is not a
   backend detail; it is the console's organising idea. Any setting, anywhere, answers
   "what is it, who decided it, and who else had an opinion".
2. **Nothing is applied until its diff has been read**, computed by the same function that
   writes the audit record — extended from profiles to bundles, policy, triggers,
   provisioners and budgets.
3. **Irreversible means typing the thing's own name**, which is already true and which is
   the same rule the MCP surface applies to a model.
4. **Coverage is asserted, not assumed.** `AdminParityTest` proves the four renderings
   agree. A new assertion proves every `Plane.Admin` function is reachable from a named
   console screen, or is explicitly listed as API-only with a reason. That single test is
   what stops the console drifting behind the API again.

**The rule W6 adds to the product, not to the console.** Scheduling implies a worker. A
local or private session runs in the daemon on somebody's machine and cannot be scheduled;
scheduling it promotes it to a team session on a worker, with a different filesystem and a
different credential set. Cowork states this asymmetry at the moment of scheduling and it is
the cheapest thing on this list to copy and the most expensive to leave implicit.

### Done

See [`docs/control-panel.md`](control-panel.md). The two that gate the release:

1. Every `Plane.Admin` function is reachable from a console screen or listed as API-only
   with a reason, asserted by a test.
2. A platform admin configures a complete working deployment — identity, a team, a policy, a
   bundle, a profile, a provisioner, a trigger and a budget — from the console alone, with
   no `kubectl`, no environment variable and no database write, and every step is in the
   audit trail with a diff.

---

## W7 — Release

### Brings, takes, already in place

**Brings.** One command that says whether this is shippable, one chart that installs it,
one document that tells somebody how to run it, and a version number that means something.

**Takes.** A release suite that composes the others, a versioning rule across two
repositories, and the documentation debt paid.

**Already in place.** `mix check` is the quality gate and has been since stage 1. The chart
is published by a release tag (`DECISIONS.md` 322). `kubeconform` gates it. The ten-run
flake detector exists for the unit suite. `mix troupe.schema.diff` enforces additive-only
protocol change. The docs tree is large and mostly written.

### Design

#### 7a. `mix troupe.release.check`

Composes what exists rather than replacing it: `mix check`, `mix troupe.schema.diff`
against the last tag, `mix troupe.e2e` twice, `kubeconform` on the chart, the GUI's
Playwright suite against the same cluster, and the machine-readable egress allowlist
checked against the chart's policy and the `TroupePolicy` defaults (`stage-6.md` §5d).

It fails on any one of them and prints which. It runs on a tag, and nightly on `main`
three times so a flake is named rather than retried.

#### 7b. Two repositories, one version

The chart's `appVersion` and the GUI's package version are the same string, and the GUI's
`initialize` refuses a plane whose major version it does not know. Protocol compatibility
stays additive-within-major, which `schema.diff` already enforces; this adds only the
statement of which versions were built to go together, in the chart and in the client.

#### 7c. The documentation the release owes

Not new documents — the tree is already large. Three that must be true rather than
plausible:

* **`docs/as-built.md`** (this directory) becomes the product tour, and every claim in it is
  a done item somewhere above.
* **The install path for one person.** W4 makes it possible; the docs must make it a page.
  "You have a laptop and no cluster" is a real starting point and currently has no entry.
* **The egress allowlist**, generated, not written — one file naming every host each
  component dials with the component that owns it, checked in CI.

### Done

1. `mix troupe.release.check` passes on a clean checkout of both repositories at the same
   tag.
2. `helm install` of the published chart, on a cluster nobody prepared, reaches a console
   somebody can sign into, following only the install page.
3. A person following the single-machine page reaches a first streamed token without a
   cluster.
4. The GUI refuses a plane one major version ahead and says so in one sentence naming both
   versions.
5. Every claim in `docs/as-built.md` maps to a done item, checked by a reviewer, not a
   script.

---

## Order of work

1. **W1**, all of it, because every other workstream names something it finishes. Within
   it: trigger revisions first (they get harder with every recorded run), then entitlements
   (W2's ladder narrows through them), then person credentials, then private sessions, and
   the e2e suite in parallel from the start with each of the others landing its own claim.
2. **W2**, because W3, W5 and W6 all name a principal and none of them should invent one.
3. **W6's first half** — Policy, Identity, Integrations, Budgets, Triggers — which is what
   W2 needs somewhere to live. The rule is that a workstream's console screen lands with the
   workstream, not after it.
4. **W3** and **W5** in parallel. They touch different surfaces and share only the
   capability-announcement pattern.
5. **W4**, which is the largest and the least coupled, and which can start at any point once
   the e2e suite exists to prove an SSH worker and a pod agree.
6. **W6's second half** — Provisioners, Connections, Review, the coverage assertion.
7. **W7**.

If only a month were available, it is W1 and W6. A platform that is correct and cannot be
administered is not a product, and a console over an unfinished floor configures things
that do not work.

---

## Decisions this plan revises

Three, each named because the rule is that a plan which revises a decision says which and
why.

**1. `stage-6.md`: "No push channel to harness clients. Status stays columns and filters; a
spend figure is read, not pushed."**

Revised narrowly, in W3c. The reasoning held for spend and holds still: a number that is
correct when you read it does not need pushing, and a push channel for it is a distributed
concern bought for nothing. Presence is the opposite case — its entire value is being under
a second stale, and a polled presence indicator is worse than none because it shows people
who left. The revision is bounded to presence, on the subscription that already exists, with
no `seq`, no persistence, and an explicit test that losing it costs nothing.

**2. `stage-6.md` open question: "Entitlements on a person as well as a team. Deferred
deliberately — a team of one is the answer until somebody shows a case it does not fit."**

Answered rather than revised, in W2c, and only for spend. Two products in the landscape now
ship per-person ceilings beside per-team ones (Cowork's group limits with most-restrictive
precedence; Warp's individual credit caps), and the case a team of one does not fit is the
ordinary one: ten people share a team, one of them writes a runaway trigger, and the team's
ceiling is the whole team's runway. The deferral stands for *entitlements* — which agents
and servers a person may use is still a team's answer — and ends for *budgets*, which is
where it bites first and costs least.

**3. `../../spec.md`, forbidden list: nothing in it. And the assumption beneath
it.**

Nothing in the forbidden list is weakened by W4 and this is worth being explicit about,
because an SSH worker looks like it should weaken several. It does not: Erlang distribution
stays confined, the plane stays out of the data path, the plane still holds no cluster
privilege, no content crosses the control channel, no key reaches the plane. What W4
contradicts is an *assumption* that was never a decision — that a worker is a pod — which
the spec makes everywhere and argues nowhere, because when it was written the only customer
was a cluster. The compensating control is that the guarantee an SSH worker cannot give is
named in the console and gated by a platform setting, rather than quietly absent.

---

## What this plan deliberately does not do

* **No break-glass.** `Troupe.Plane.Breakglass` exists; no part of this plan gives it a way
  to read session content, and the invariant that no admin role grants content access is
  untouched.
* **No second identity system.** Entra Agent ID's four object types are not copied; one
  sponsor attribute is. Membership still comes from the identity provider and is still never
  edited in Troupe.
* **No merge.** Two devices, two forks, two shares — fencing decides and nothing is
  reconciled, which is the GUI spec's rule and stays it.
* **No price table.** The gateway prices the call and the nightly reconciliation is what
  makes trusting it safe. Person caps draw on the same ledger.
* **No autoscaling, no multi-cluster, no tenancy.** One deployment is one organisation. W4
  widens what a worker may be, not how many organisations a plane serves.
* **No mobile client, and no relay.** Orca and Nimbalyst pair a phone to a desktop through a
  relay they host. Troupe's private sessions already follow a person to another device
  through object storage they own, which is the same outcome without a service in the
  middle.
* **No rollup pipeline.** Raw ledger rows and a cache until the row count says otherwise,
  which is stage 6's answer and stays it.

---

## Open questions

* **Does an ACP subagent's approval belong to the session or to the subagent?** A Troupe
  subagent's tool call raises an approval on the session, which is right. An ACP agent has
  its own permission model and may ask for something the session's allowlist already
  answered. Decide before W5b: probably the session's answer wins and the subagent is told,
  because two permission systems disagreeing in front of a user is the worst outcome.
* **Does a fork share the parent's blobs?** Deduplication across sessions is forbidden,
  because one session's key would protect another's data. A fork is a new session with a new
  key, so by the letter it must copy. By intent the parent and child are the same
  conversation. The letter probably wins and the cost is paid; measure it on a session with
  a large tool-result history before deciding.
* **Where does an SSH worker's disk watermark come from?** A pod has a PVC with a size the
  operator set. A host has whatever it has. Either the provisioner reports a configured
  budget and the honesty is the operator's problem, or placement stops using watermarks for
  unenforced workers and uses a session count. Probably the former, with the console showing
  it as declared rather than measured.
* **Should a share link survive the session going dormant?** It should, and the question is
  whether opening one activates. Probably not: a link opens at `read`, and the activation
  rule stays what it is — input activates, looking does not.
* **Is `managed_mcp_servers_only` a platform setting or a team one?** The ladder says a team
  may only narrow, so a team could set it when the platform has not. Whether a team *should*
  be able to forbid its own members' personal connections is a policy question, not a
  mechanism one, and the people who will answer it are the ones who have to live with it.
