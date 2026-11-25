---
number: 1111
title: "The harness proposes in a pod session's chat with `proposal_made`, a non-blocking event only the owner answers; the first kind turns on a trigger that reruns a report built from live data, made on the owner's yes as the team's row under the owner's own sponsored principal, with the run's terms allowing the tools the session used"
date: 2026-11-25
status: accepted
issue: 1208
paths:
  - apps/troupe_core/lib/troupe/session/proposals.ex
  - apps/troupe_core/lib/troupe/session/proposals/trigger_rule.ex
  - apps/troupe_core/lib/troupe/proposals.ex
  - apps/troupe_plane/lib/troupe/plane/proposals.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_worker/lib/troupe/worker/proposals.ex
  - apps/troupe_worker/lib/troupe/worker/session/restore.ex
  - clients/gui/packages/client/src/proposals.ts
gist: "proposal_made/answered, not a question: owner only, first answer wins, never mid-turn, pod only, never in a trigger/agent session; never per person per key; yes = own sponsored principal + team trigger + edit grant + terms.allow"
---

Issue #1208. Narrows Decision 256: a trigger's `prompt_template` is stored on the plane when
an administrator writes it, and now when a session's owner says yes to one drafted from it.

**A proposal is not a question.** `proposal_made {id, kind, key, title, why, draft, options,
mode}` is written by the projection `Troupe.Session.Proposals`, after `Checkpoints` in the
tree, at the root's rest and never during a turn; once per session per kind; only where the
host installed a proposer (`Troupe.Proposals`), which a pod does and a person's machine does
not, since nothing there schedules. It is in no `pending_*`, never makes the session
`waiting`; `facts.open_proposals` holds it for a late attacher. The owner answers:
`session.proposal.answer` takes `later` and `never`, `session.proposal.accept` on the plane
takes yes; the first answer wins and `proposal_answered` records it once. `never` is kept on
the plane per person per `key` (`proposal_declines`) and read before the next is made.

**The first kind, `trigger`, needs no model**: a `publish_artifact` completed in this turn,
and earlier a read of live data (`web_fetch`, an MCP tool, a shell command from a short
list). Never in a session a trigger or an agent started, nor where the team's
`members_may_schedule` is off (on by default), the person holds five such triggers in the
team, a trigger already reruns the artifact, or a `never` stands. The schedule comes from the
person's words, else Monday 06:00 UTC.

**Yes** makes or reuses the person's own principal in the session's team
(`svc:<team>/own-<handle>`), sponsored by them, so runs draw on their budget and stop when they
leave; the trigger is the team's row with `review: required`, `notify: [owner]`, the
session's visibility and `terms.budget_micros` 1 000 000 unless edited; the principal is
granted `edit` on a person-owned artifact; audited `trigger.put` with `via: proposal`. On a
gitops plane nothing is made: the answer carries the `Trigger` YAML.

**The run's terms allow what the session used** (`terms.allow`, per-tool rules the pod adds
as the trigger's layer), `publish_artifact` first, so a run under `approvals: deny` does not
die at its last step. A tool the profile asks for or denies cannot be allowed: the draft says
so and the proposal is `mode: unavailable`.

## Not chosen

- `question_asked`: it blocks the turn, counts as waiting and is answered as free text.
- A model judging "recurring work": a priced call per publishing turn before the rule fails.
- A member's own `admin.trigger.put`: every trigger would then be one, not one a yes drafted.
- `approvals: auto` in terms: a run approving its own shell is what triggers refuse.

## If undone

Mid-turn proposals interrupt the work they are about; without the owner check a collaborator
spends the owner's budget; without `terms.allow` every run is denied at its publish.
