# Brief — troupe-remote

This extends `spec.md` and assumes stages 1–5, stage 6 part 1 and the admin surface are
finished and green. Same rules apply: work autonomously, do not ask questions the documents
answer, record every judgment call in `DECISIONS.md`, and prove every done item with command
output in `REPORT.md`.

Read [`../HANDOFF.md`](../HANDOFF.md) first — the five spec revisions and the list of things
not to do are there and are binding.

Nine packages. R1 first; after that the order is a recommendation and the dependencies are
real.

| | package | size | depends on |
| --- | --- | --- | --- |
| **R0** | [Three corrections](#r0--three-corrections) | tiny | — |
| **R1** | [Finish the floor](#r1--finish-the-floor) | large | — |
| **R2** | [One trigger, one principal](#r2--one-trigger-one-principal) | medium | R1's trigger revisions |
| **R3** | [Capacity without a capacity question](#r3--capacity-without-a-capacity-question) | large | R1's e2e suite |
| **R4** | [Teams link to groups](#r4--teams-link-to-groups) | medium | — |
| **R5** | [Fork, shares, presence](#r5--fork-shares-presence) | medium | R2 |
| **R6** | [The provisioner interface](#r6--the-provisioner-interface) | large | R3 |
| **R7** | [Interop: ACP and the in-system MCP](#r7--interop) | medium | R2 |
| **R8** | [The console](#r8--the-console) | large | a screen lands *with* its package |
| **R9** | [Release](#r9--release) | medium | all |

---

## R0 — Three corrections

Half a day, and each one is a document that will mislead somebody.

1. **`docs/plans/stage-6.md` §3e cites `tui/connectors.ex:5-8`.** That app was deleted
   (`DECISIONS.md` 320). `session_tainted` now lives in `Troupe.Session.ClientTools`,
   `Troupe.Log.Fold` and `Troupe.Session.Summary`. The distinction the section draws — a
   server a *client* registered versus one an *admin* published — is unaffected and still
   correct. Fix the reference.
2. **`docs/plans/README.md` still describes the client apps as the protocol's test harness.**
   They are gone; `apps/troupe_gateway/test/conformance/conformance.py` carries that proof
   now. Say so.
3. **`placement.ex:35`'s doc comment** says an at-capacity error "means the profile needs
   more replicas, and the caller should say so." R3 changes that. Leave the comment until R3
   lands, then change it in the same commit — it is the sentence that justified the design.

---

## R1 — Finish the floor

Everything already planned and not built. Nothing new is designed here; three things are
corrected.

### What it is

* **`docs/plans/stage-6.md` parts 2, 3, 4 and 5**, as written: entitlements below the
  profile, credentials that belong to a person, trigger revisions, and the cluster suite.
* **The server half of private sessions**, from
  `../troupe-gui/docs/plans/local-and-private-sessions.md`.

### Order within the package

Trigger revisions first — smallest, touches nothing else, and gets harder with every day of
runs recorded against a mutable row. Then entitlements, because R2's policy ladder narrows
through them. Then personal credentials. Then private sessions. **The e2e suite runs in
parallel from the start**, with each of the four landing its own claim rather than waiting
for a suite that does not exist.

### The three corrections

1. **`Sealer`, `Storage` and `Cipher` move from `troupe_worker` into `troupe_protocol`** —
   a move, not a fork. `apps/troupe_worker/lib/troupe/worker/session/sealer.ex` is the
   current home and both the worker and the daemon already depend on `troupe_protocol`.
2. **Generalise trigger revisions beyond the scheduler.** `stage-6.md` §4 designs them for
   cron. R2 needs the same revision hash for six sources, so build the revision as a property
   of the *trigger document*, not of the cron row.
3. **Add two claims to `stage-6.md` §5's table**, because later packages need them proven:

   | claim | fault or witness |
   | --- | --- |
   | A session forked on a worker has a log whose first event names the parent's head hash | Fork, then `troupe ctl verify` both chains |
   | A session sealed by a non-Kubernetes worker restores on a pod | An SSH worker in the `world`; restore on a pod |

### Done

1. `mix troupe.e2e` passes every claim in `stage-6.md` §5 plus the two above, from a clean
   cluster, twice in a row.
2. Every negative claim is proven from inside the pod, not from the presence of an object.
3. A session sealed by the daemon restores on a worker, and the reverse, through the same
   `Sealer`.
4. A pod's KMS token cannot read a key under `people/`; a person's JWT token cannot read one
   under `teams/`; the plane's token can delete metadata under both.
5. The daemon reports `private_sessions` at `initialize`, which is what un-gates the client's
   control.
6. `REPORT.md`'s "nothing has run on a cluster" paragraph is replaced by command output.

---

## R2 — One trigger, one principal

`RELEASE.md` W2 in full. Read it; this is the summary and the done items.

### What it is

* **`trigger_fired`, one event, seven sources** — `schedule`, `webhook`, `integration`,
  `ci`, `api`, `manual`, `agent` — each carrying a source discriminator, the trigger
  document's content hash, the principal pair, an idempotency key and a *payload digest*,
  never a payload.
* **`POST /trigger/<id>`** with the trigger's own rotatable key, and `trigger.fire` on `/rpc`
  for a principal's credential. Both mint the same event. There is no second-class run.
* **Subject and actor as a pair** on every durable event, outbound call and audit row. Where
  they are equal, write both.
* **A sponsor on every service principal**, required, a person in a granted team. No sponsor,
  no enable. Sponsor removed by SCIM, principal stops firing and the console says *needs a
  sponsor*, not *broken*.
* **`PersonBudget`**, sibling to `TeamBudget` (`team_budget.ex:112-125`), same shape, same
  ledger, same idempotency. A reservation clears every ceiling that applies and the refusal
  names the binding one.
* **The policy ladder** — deployment → platform → team → profile → session. A lower rung may
  only narrow; deny wins from any rung; absence means everything. Plus
  `managed_permission_rules_only` and `managed_mcp_servers_only`.
* **A small in-system MCP projection** beside the administrative one: sibling
  `session.create`, `session.get`, `trigger.fire`, scoped `sessions.list`. Nothing
  destructive. Entitlement resolution at create is the guardrail.

### One negative requirement

Outbound webhook targets are **absolute only**, validated against the egress allowlist at
save and again at send, loopback refused. LangGraph shipped a 2026 advisory for the absence
of exactly this check. Prove it by the request failing from inside the pod.

### Done

`RELEASE.md` W2's nine done items, unchanged.

---

## R3 — Capacity without a capacity question

[`orchestration-review.md`](orchestration-review.md) in full. This is the package the
customer asked for by name and the one with the clearest payoff at their scale.

### What leaves the admin surface

`replicas`, `sessionsPerPod`, `resources.requests.cpu`, `resources.requests.memory`,
`resources.limits.cpu`, `resources.limits.memory`, `storage.size`. They stay in the CR,
written by the plane and derived from the size class. Seven fields out; three questions in:
**how demanding**, **how far may it grow** (in sessions at once, not workers), **keep one
warm**.

### Size classes

Two, and they are about resources, not safety — finding 5 established that session-to-session
file separation is already built and tested (mount table, bubblewrap, stage 2 done item 15).

| class | sessions per worker | for |
| --- | --- | --- |
| Standard | several | most work |
| Heavy | few | large repositories, builds, long or memory-hungry runs |

`sessionsPerPod: 1` stays in the CR and off the admin surface. **Do not build an isolated
class.**

### The plane scales the profile

`Troupe.Plane.Placement` already serialises capacity per profile in one `:global` process
with Postgres-backed counts. It gains the other half:

* **Up:** once per interval, `want = ceil((active + pending) / sessions_per_worker) + warm`,
  clamped to the ceiling, written to `spec.replicas`. Same writer and same permission as
  `spec.teams` today.
* **To zero:** no active sessions and no warm setting → zero replicas after a grace period.
  Drain already seals and strands nothing.
* **From zero:** the first create scales up and the session waits.

Every fifteen seconds is fast enough. No HPA, no metrics pipeline, no per-session pod churn.
**A pod is never created for a session.**

### Sessions wait instead of being refused

`session.create` on a full-but-growing profile returns a session id and no endpoint; the row
is `pending`; the endpoint arrives over the subscription the client already holds. Refusal
survives only where a human set a ceiling, and then it quotes them.

### The distinction that resolves the dormant-read edge

Write it into `PROTOCOL.md` explicitly: **activation is about the session, not about the
pod.** "Subscribing to a dormant session never activates it" means no actor tree and no model
call. A `Session.Reader` is neither, so a reader may start a worker without reserving
capacity. The looser reading would forbid something harmless.

### Done

1. A profile with no sessions has no workers; the first create brings one up and the session
   runs, with the wait visible and bounded.
2. Fifty concurrent creates against a profile with a ceiling of ten: ten run, forty wait or
   are refused with the ceiling named, and no worker exceeds its class.
3. Scaling to zero and back loses nothing: a dormant session activates with full history and
   workspace on a worker that did not exist a minute earlier.
4. Reading a dormant session on a cold profile serves full history with zero agent processes
   and zero model calls.
5. `kubectl auth can-i` as the plane's ServiceAccount still returns no for pods, secrets and
   namespaces. Writing `spec.replicas` did not widen anything.
6. A `TroupePolicy` maximum still refuses a size class that exceeds it, at admission.

---

## R4 — Teams link to groups

[`orchestration-review.md`](orchestration-review.md) finding 8. Spec revision 5.

```
teams              id, name, display_name, budget, retention, default_visibility, …
team_group_links   team_id, group_id (with its issuer)     unique on the pair
```

* Membership is the union over links. A person in two linked groups is in the team once.
* A team with no links has no members and is valid.
* **Everything a team owns moves to the team**: budget, ceiling, retention, default
  visibility, volume, grants, team administrators. Several are currently pinned to a group by
  the 1:1 assumption.
* SCIM and the JIT `groups` claim both still feed groups. Only resolution changes.
* **Migration: every existing team becomes a single link** with the same name and the same
  members. A deployment that never uses N:M sees no change.
* Carry the issuer on `group_id` from the start, so a second identity provider is later a
  migration rather than a redesign.

**Unlinking is destructive** and the count comes first, with the identifier typed:

> Unlinking `itm-platform` from Engineering removes 14 people. 9 keep access through another
> group. 5 lose access to 2 profiles and 23 sessions they can currently open.

**Sessions do not move.** A session's team is fixed at create; unlinking changes who may open
it, not what it belongs to. Say so in the dialog — people assume the opposite.

### Done

1. Two groups linked to one team give a member of either the team's grants; removing one link
   removes only the people who had no other route, and the count shown beforehand matches.
2. One group linked to two teams puts a person in both, with independent budgets and
   retention, and the session-create flow asks which.
3. The migration turns every existing team into one link with identical membership, proven by
   comparing resolved membership before and after.
4. Team membership still cannot be typed anywhere in Troupe.

---

## R5 — Fork, shares, presence

`RELEASE.md` W3, server half.

* **`session_forked`** as the child's first event, carrying the parent's id, seq and head
  hash, and a reason of `attempt`, `branch` or `import`. Workspace restored from the parent's
  nearest snapshot at or before seq into the child's own prefix. The parent is untouched and
  does not learn of it. The plane's row carries `parent_session_id` so lineage draws without
  reading a log.
  * A fork inherits the entitlement set recorded in the parent's `session_created`, **not**
    the bundle's current offering.
  * A fork is a new session for budget, retention, key and erasure.
  * `reason: "import"` is how a private session becomes a team session.
* **`session.share`** mints a capability at `observe` or `control`, bounded by the team ACL,
  expiring, durable as `share_created` / `share_revoked`. Refused at mint, never at use. A
  share never grants `admin`.
* **Presence as a third subscription topic** beside `fleet` and `session:<id>`. No `seq`,
  never persisted, explicitly droppable. Revision 1 is bounded to this and nothing else.

### Done

`RELEASE.md` W3's seven done items. The one that matters most: with the outbound queue
saturated, presence stops entirely and the event order is still identical on both clients.

---

## R6 — The provisioner interface

`RELEASE.md` W4. Do this after R3, because scale-to-zero and size classes must already be
expressed in terms of *workers* rather than pods for a second implementation to be cheap.

```elixir
@callback ensure(profile) :: {:ok, [worker_ref]} | {:error, term}
@callback drain(worker_ref, timeout) :: :ok | {:error, term}
@callback describe(worker_ref) :: {:ok, %{capacity: …, health: …, version: …}}
```

`Kubernetes` is the operator as it stands. `SSH` is a host that answers, enrolling with a
per-host secret issued in the console.

**Unchanged and non-negotiable:** enrolment still proves the worker is the profile it claims;
the control channel, seal format, object layout, key paths and session log are byte-identical;
placement reasons in workers.

**Named, not hidden:** an SSH worker has no admission policy, no NetworkPolicy, no FQDN
egress, no disruption budget. The profile is marked `unenforced egress` and the ladder refuses
to place a team on it without `allow_unenforced_workers`.

Also in this package: **a workspace image named by its bundle hash**, stored beside the
bundle, restored instead of installing. Cursor's warning ships with it — a snapshot preserves
disk and nothing else; `session_resumed` already says so.

---

## R7 — Interop

`RELEASE.md` W5.

* **ACP on the daemon's loopback socket**, selected at `initialize` by the protocol the client
  announces. Not a second port, not a second auth path. Three mappings: ACP session → session
  plus `subscribe` at `detail`; ACP permission request → the approval flow including *allow
  for session*; ACP filesystem and terminal → the mount table and `ClientTools`.
* **ACP in the other direction**: a bundle entry may name an ACP agent, run as a subprocess,
  served **through the mount table**. That is what makes it safe and why it belongs here and
  not in a client. It is an entitlement like an agent or a skill.
* **The protocol table in `PROTOCOL.md`** — which of MCP, ACP and A2A carries which boundary
  and in which direction. Written once, so nobody invents a fourth.

---

## R8 — The console

[`control-panel.md`](control-panel.md) in full. **A package's console screen lands with the
package, not after it.**

Eleven screens become fifteen, grouped by what an administrator is doing:

* **Watch** — Overview · Sessions · Review · Audit
* **Configure** — Policy · Bundles · Profiles · Triggers · Teams · Identity · Integrations
* **Operate** — Fleet · Provisioners · Budgets · Connections

The four rules: every effective value names its rung; nothing applies until its diff is read;
irreversible means typing the name; **coverage is asserted**.

That last one is the release-gating test and the reason this document exists:

> Every `Plane.Admin` function is reachable from a named console screen, or listed as
> API-only with a one-sentence reason.

`admin.profile.put` being in the TypeScript client and on no screen is the failure it
prevents.

**The composed Profile screen** (finding 1) is the largest single item: one object called
what the administrator calls it, writing WorkerProfile, bundle version and grants under one
preview and one audit row. Adding an MCP server shows, in one place, the egress host that
opens, the secret that must exist, the tools that appear and the teams that get them.

**Plus the admin-surface debts**: Identity and Integrations as their own screens, the erase
dialog's full text with its three consequences, Audit's integrity tab, bundles as a diff, and
a skill catalogue (finding 6).

**Plus the data** (finding 9): one sampled series — active sessions per profile, every minute,
ninety days — a **Today** panel, and per-profile thirty-day figures that feed the warm-worker
recommendation.

---

## R9 — Release

`mix troupe.release.check` composing `mix check`, `mix troupe.schema.diff` against the last
tag, `mix troupe.e2e` twice, `kubeconform` on the chart, the GUI's Playwright suite against
the same cluster, and the generated egress allowlist checked against the chart's policy and
the `TroupePolicy` defaults.

One version string across both repositories at a tag. The GUI refuses a plane one major
version ahead, in one sentence naming both.

Three documentation items that must be true rather than plausible: the install page somebody
can follow on an unprepared cluster, the **single-machine page** R6 makes possible, and the
generated egress allowlist.
