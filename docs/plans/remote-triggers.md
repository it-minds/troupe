# Remote triggers

Agent work nobody starts by hand: dependency updates every night, a triage session when a
ticket lands, a session opened when CI fails. A person reviews the results in HQ
afterwards, answers what the agent asked, and closes the loop.

The architecture already says a trigger is a caller, not a feature
(`ARCHITECTURE.md` §13). This plan is about making that sentence true, and about the
three things it glosses over: who the caller is, how the first turn happens with nobody
attached, and where a person finds the result.

---

## Brings, takes, already in place

**Brings.** Scheduled and event-driven sessions under the same grants, budgets and
retention as a person's, with their results waiting in the log; a review queue in HQ;
an audit trail from the event that fired to the session it produced.

**Takes.** Service principals in the plane; trigger definitions (source, schedule,
profile, prompt template, budget, review policy); the plane carrying a prompt through
activation; a few status columns so a queue can be listed without reading logs; and a
durable executor. Hatchet is the executor: it owns schedules, retries, webhook intake
and idempotency, and calls the plane's public API as a service principal. The plane
gains no scheduler, no webhook endpoint and no outbound calls.

**Already in place.**

* Creating and activating a session is a plane call and works with no client
  attached; a session with nothing to do goes dormant and costs nothing while its
  results wait (`apps/troupe_plane/lib/troupe/plane/harness.ex:123-137`,
  `apps/troupe_worker/lib/troupe/worker/session/manager.ex`).
* Approvals are durable, outlive dormancy, and answering one days later activates the
  session and continues the turn (`apps/troupe_core/lib/troupe/session/approvals.ex`,
  DECISIONS 113–114).
* Workers never expose a trigger endpoint; everything goes through `/rpc`
  (`spec.md:354`).
* HQ is already a `fleet` subscriber plus one listing with an approval inbox
  (`apps/troupe_tui/lib/troupe/ui/hq/`).
* Budgets are reserved per session from a team budget by a cluster-unique actor
  (`apps/troupe_plane/lib/troupe/plane/team_budget.ex`).

## What is missing today, precisely

| Gap | Where |
| --- | --- |
| `/rpc` authenticates only a person: a bearer token from `/auth/exchange` whose subject is a `users` row. There is no non-human principal anywhere. | `apps/troupe_plane/lib/troupe/plane/web/router.ex:141-152` |
| `session.create` on the plane **drops `prompt`**. The CLI sends it; the plane never reads it; the first input is sent by the attached client after the socket is up. `Troupe.resume/2` then forces `task: nil`. | `harness.ex:244-276`, `apps/troupe_ctl/lib/troupe/ctl/remote.ex:158-165`, `apps/troupe_core/lib/troupe.ex:179-181` |
| Budget slice and turn cap are fixed: `@default_slice_micros 5_000_000`, `max_turns 40`. Neither is a `session.create` parameter. | `harness.ex:32`, `apps/troupe_core/lib/troupe/budget.ex:11` |
| `auto_approve` is a local config flag with no route from the plane. | `apps/troupe_core/lib/troupe/session.ex:57` |
| `sessions.list` carries no status, done reason, pending-approval count or cost; those live only in each session's log. A queue cannot be listed. | `harness.ex:567-584` |
| `TeamBudget.release` is not called on dormancy, only on unwind and erase, although the module doc says it is. A fleet of triggers would pin reservations. | `apps/troupe_plane/lib/troupe/plane/control/connection.ex:273-285`, `team_budget.ex:10-12` |
| No ACL can be granted from the plane; `acl_granted` exists only as an in-session event. A trigger's session is invisible to humans unless it is `visibility: team`. | `apps/troupe_plane/lib/troupe/plane/sessions.ex:414-436` |
| No scheduler of any kind in the plane, and the "nightly" mix tasks have no runner. | `mix.lock`, `apps/troupe_plane/lib/mix/tasks/` |

---

## Design

### 1. Service principals

A service principal is a credential a team owns, not a person and not a member. That
keeps the rule that team membership is the identity provider's business: a principal
is created *by* a team admin *for* a team, the way `team_admins` already records a
role a team assigns to a subject inside Troupe.

```
service_principals
  id, subject ("svc:<team>/<name>"), team_id, name, description,
  profiles (array — the grants it may use, a subset of the team's),
  secret_hash (argon2id of a plane-generated secret, shown once),
  created_by, created_at, disabled_at, last_used_at
```

`POST /auth/exchange` grows a second body shape, `{"client_id": subject, "client_secret":
…}`, answered with the same plane token a person gets, with claims `kind: "service"`,
`team`, and `profiles`. `Identity.get_user/1` learns to resolve a `svc:` subject to a
principal, and `Harness` treats it as a user whose only team is its own and whose
profiles are the listed ones. `Admin.actor_for/1` returns `:none` for it: a principal
can create and steer sessions and nothing else. Sessions it creates have
`owner_subject` = the principal, so cost and retention are the team's, and the log's
actor on every input names the principal — a person reading the transcript sees
`svc:platform/nightly-deps` asked for this, not a human.

Where the identity provider can issue client-credentials tokens with a `groups` claim
(Authentik can), the same endpoint accepts that token instead of a secret, and the
principal is matched by subject. The plane-issued secret is the pragmatic path for the
small release; the IdP path keeps the credential out of Troupe entirely and is the one
to prefer once the IdP is set up for it. Both produce the same claims, so nothing
downstream cares which.

Admin surface: `admin.principal.create/list/disable/rotate` in `Admin`, `Admin.API` and
`Ctl.Admin` together (the parity test insists), a Principals section on the team page,
and an audit row for each.

### 2. The plane carries the prompt, and the session's terms

`session.create` gains parameters that a trigger needs and a person may also use:

```json
{"profile": "deps", "team": "platform",
 "title": "nightly dependency update 2026-09-13",
 "prompt": "Update every dependency with a patch release available…",
 "visibility": "team",
 "terms": {"budget_micros": 2000000, "max_turns": 25, "wall_clock_seconds": 3600,
           "approvals": "wait"},
 "origin": {"kind": "trigger", "trigger": "nightly-deps", "run": "hatchet:wf_9f…"}}
```

* `prompt` travels in `start_on_pod` and `session.activate`, and `Restore.start/3`
  passes it as `:task`. `Agent.Server.replay/2` already seeds a task only when the log
  is empty, so a later activation does not re-run it.
* `terms.budget_micros` replaces the fixed slice for this session (capped by the team's
  budget); `max_turns` and `wall_clock_seconds` become config overrides the worker
  applies at start. A trigger definition sets them; a person leaves them out.
* `terms.approvals` is `wait` (default: approvals sit in the log and the queue) or
  `deny` (an unattended session that asks is told no, and the agent hears it as a
  readable result). There is no `auto` for triggered sessions: an unattended session
  that approves its own shell commands is the thing the design refuses. A trigger that
  needs no approvals gets a profile whose definition sets those tools to `auto`, which
  is an admin's explicit act in a versioned bundle, not a flag on a schedule.
* `origin` is recorded on the row and in `session_created.data.origin`, so the
  transcript and the listing both say what started this.

`TeamBudget.release` is called on dormancy, as the doc says.

### 3. Trigger definitions and the executor

The plane stores the definition; Hatchet runs it. The plane's table is the source of
truth an admin edits and audits; Hatchet's workflow reads it when it fires.

```
triggers
  id, name, team_id, principal_id, profile, enabled,
  source (map: {"kind": "schedule", "cron": "0 3 * * 1-5", "tz": "Europe/Copenhagen"}
            | {"kind": "webhook", "provider": "github"|"jira"|"generic", "filter": {...}}),
  prompt_template (Mustache; variables from the event and the run),
  terms (as above), visibility, review ("required"|"none"),
  notify (array of subjects granted collaborator on each run),
  concurrency (max live runs; default 1), created_by, updated_at

trigger_runs
  id, trigger_id, idempotency_key (unique), session_id, fired_at, event (map, ≤ 16 KiB,
  redacted by the provider filter), state (created|running|waiting|done|failed),
  reviewed_by, reviewed_at
```

Hatchet's role, exactly:

* A workflow per trigger kind. Cron workflows fire on the schedule; webhook workflows
  are Hatchet's own ingress — GitHub, Jira and generic HMAC endpoints terminate at
  Hatchet, never at the plane, which is how "no public trigger surface" stays true.
* Each run calls `/rpc` as the trigger's principal: `trigger.fire {trigger, idempotency_key,
  event}`. The plane renders the prompt, applies the terms, creates and activates the
  session, grants `notify` subjects collaborator role (a new plane method
  `session.grant` that appends `acl_granted` through the pod and mirrors it, usable by
  owners too), records the run, and returns `{session_id, endpoint, token}`.
* The workflow then waits on completion by polling `session.get` with backoff until the
  row's `status` is `done`, `waiting` (an approval is pending) or `failed`, and marks
  the run. Retries are Hatchet's: a failed create is retried with the same idempotency
  key and the plane returns the same run.
* Hatchet's own database holds schedules and workflow state; the plane's `trigger_runs`
  is the record a person reads. Neither is content.

A deployment without Hatchet is still complete for schedules: a `:global`
`Trigger.Scheduler` singleton in the plane (the idiom `Placement` and `TeamBudget`
already use) fires cron triggers and calls the same `trigger.fire` internally. It
handles no webhooks and no retries beyond one, which is the honest reason to run
Hatchet, and it is what `values.small.yaml` ships with.

### 4. Status the plane can list

The worker already tells the plane when a session goes dormant. It additionally reports,
over the control channel and on every change, four facts that are lifecycle rather than
content: `status` (`idle|thinking|acting|waiting|done|interrupted`), `done_reason`,
`pending_approvals` (a count and the call ids' tool names), and `cost_micros` so far
(already in the ledger; mirrored for listing). They land as columns on `sessions` and in
the `sessions.list` shape, and `fleet` on the plane side carries them as
`session_status` lifecycle events. HQ stops replaying every session's log to find
approvals.

`sessions.list` gains filters `origin`, `status`, `needs_review`, `trigger`.

### 5. The review queue in HQ

HQ (the TUI now, the GUI soon) gets a **Review** view over `sessions.list(origin:
trigger, needs_review: true)`, grouped by trigger: title, when it fired, status, done
reason, cost, pending approvals, and the run's event summary. From a row: open the
transcript, answer approvals (existing), and **mark reviewed** (`session.review`, which
sets `reviewed_by/at` on the run and audits it). A run that ended `budget_exhausted` or
`llm_error` is surfaced first. Nothing here is new protocol on the worker; it is the
plane listing more and one plane method.

### 6. Safety for unattended work

* A triggered session runs with `resume_on_restart` off, like every session: a pod that
  died mid-turn leaves it `interrupted` for a person, never re-runs shell commands
  nobody watched.
* Concurrency is capped per trigger; a cron that fires while the previous run is still
  live records a run with state `skipped` rather than a second session.
* The prompt template can reference the event; the event stored on the run is filtered
  by the provider filter (issue key, title, URL; never the whole payload) so a webhook
  body does not become a place to hide instructions. The rendered prompt is in the log
  as `user_input` from the principal, as any input is.
* Egress: the plane makes no outbound calls. Notification to people is HQ; anything
  else (Slack, email) is Hatchet's step after the run, outside the trust boundary.
* Erasure, retention, pins and visibility are the team's rules, unchanged.

---

## Data model

New tables: `service_principals`, `triggers`, `trigger_runs`. New columns on
`sessions`: `origin (map)`, `status`, `done_reason`, `pending_approvals (int)`,
`cost_micros`, `terms (map)`. Indexes on `sessions(origin->>'trigger')` and
`(status, last_active_at)`.

None of the three new tables is rebuildable from object storage, which changes the
claim that losing the database costs an index rebuild and no sessions. It still costs
no sessions; it costs the trigger definitions, which also live in git for anyone who
manages them the CLI way (`troupe admin trigger put <file>`). Say so in the deploy doc.

Protocol: additive. `session.create` params, `session_created.data.origin`, the
`sessions.list` shape and filters, `session.grant`, `session.review`, `trigger.fire`,
`admin.principal.*`, `admin.trigger.*`.

## Order of work

1. Prompt through activation; `terms`; `origin`; release on dormancy. A person can
   already use `troupe --remote run "…"` without a client sending the first input.
2. Service principals and the second exchange shape.
3. Status columns and the reporting from workers; `sessions.list` filters.
4. `trigger.fire`, `triggers`, `trigger_runs`, the in-plane cron scheduler,
   `session.grant`, `session.review`.
5. HQ Review view.
6. Hatchet workflows (schedule, GitHub, Jira, generic) in their own repository,
   deployed beside the plane, configured with one principal per trigger.

## Done items, proven by command output

* `session.create` with a `prompt` and no client attached produces `user_input`,
  `llm_request`, `llm_response` and a dormant session within the idle timeout; a later
  activation does not repeat the prompt.
* A principal's token can `session.create` on its profile and is `forbidden` on any
  other; `admin.overview` returns `forbidden`; disabling the principal makes its next
  call `unauthenticated` within one token lifetime.
* A trigger with `terms.max_turns: 3` ends with `budget_exhausted limit: max_turns` and
  the run shows `done_reason`; the team's reservation is released when it goes dormant.
* A triggered session that asks for approval shows in HQ Review with
  `pending_approvals: 1` without HQ having replayed its log; answering it from HQ
  activates the session and the turn completes.
* Firing `trigger.fire` twice with one idempotency key creates one session and returns
  the same run.
* On kind: the in-plane scheduler fires a cron trigger at the minute; on the same
  cluster with Hatchet deployed, the GitHub webhook workflow opens a session for a
  synthetic `issues.opened` event, and the plane's access log shows no request from
  GitHub.

## Open questions

* **Principal credentials: plane-issued or IdP-issued first?** Recommendation: ship
  plane-issued for the small release, keep the IdP path in the exchange from day one,
  and move to it when Authentik has a client per trigger. Both are in this plan.
* **Should a person be able to create triggers, or only team admins?** Recommendation:
  team admins, because a trigger spends the team's budget without anyone watching.
* **Templating language.** Mustache is enough for `{{event.issue.key}}`; anything that
  can loop or call is more than a prompt template should be able to do.
