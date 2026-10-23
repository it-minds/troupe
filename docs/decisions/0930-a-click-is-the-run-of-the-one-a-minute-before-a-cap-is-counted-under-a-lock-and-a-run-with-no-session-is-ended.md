---
number: 930
title: "A run by hand and the console's \"fix this\" are the run of the same person's click less than a minute before, as a webhook's blind retry is, not the run of the clock's minute; a firing is admitted against its caps under the trigger's row lock (and, on a repository, one lock for every repository cap), a failed run's retry included; and a run that has had no session for ten minutes is ended `failed`, with the reason, and audited"
date: 2026-10-23
status: accepted
supersedes: [914, 917]
paths:
  - apps/troupe_plane/lib/troupe/plane/triggers.ex
  - apps/troupe_plane/lib/troupe/plane/triggers/scheduler.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/github/issues.ex
  - apps/troupe_plane/test/troupe/plane/trigger_ingress_test.exs
  - apps/troupe_plane/test/troupe/plane/trigger_sources_test.exs
  - apps/troupe_plane/test/troupe/plane/github_issues_test.exs
  - docs/admin/bundles-and-triggers.md
  - docs/admin/github.md
symbols:
  - fire_by_hand
  - end_unmade
gist: "A click is the run of the same person's click <60 s before; caps are counted under the trigger's row lock (plus one repository lock); a run sessionless 10 min is ended, audited"
---

# A click is the run of the click a minute before, a cap is counted under a lock, and a run with no session is ended

Decision 927 drew a webhook's blind retry on a minute from the firing it repeats, under
the trigger's row lock, and left three things it found for their own change. This is
that change. It replaces the minute of a run by hand in Decision 914 and of "fix this" in
Decision 917; the rest of those two stands.

## Context

- **The clock's minute.** `admin.trigger.run` keyed a run on
  `manual:<trigger>:<subject>:<minute>` and the console's "fix this" on
  `fix:<trigger>:<issue>:<subject>:<minute>`. A click at :59 and a second one a moment
  later, or a retry of a call whose answer was lost, were two runs, the second skipped
  under the cap the first held. The test of the run by hand waited for the start of a
  minute to pass.
- **Counted apart.** `start/3` counted live runs and wrote `skipped` outside any lock.
  Two firings with keys of their own that raced on one trigger with a concurrency of 1
  each wrote its run, then each counted the other's (still `created`, no session) as live,
  and both were skipped: nothing ran. The chunk tip's test of three such firings started
  none. A run on a repository counts against its profile's and its team's caps across
  triggers too, which no one trigger's row covers.
- **A failed create's retry** went to `create/3` without counting, so a run that failed
  while another took its place made a second session past a concurrency of 1.
- **A run left with no session**, by a request that crashed or a replica that went down
  between the run's row and its session, stayed `created` with no session. It counted as
  live in every cap for good, and every repeat of it waited five seconds and was answered
  `409`. Nothing ended it.

## Decision

- **A window of the person's.** `Triggers.fire_by_hand/5` fires `manual` under a window
  the caller names, the way `fire_in_window/5` does for a webhook: under the trigger's row
  lock it looks for a run of the trigger keyed under the window that fired less than a
  minute before now, or after it, and repeats that run; only if there is none does it
  write one, keyed with the window and the instant. A run by hand's window is
  `manual:<trigger>:<subject>:`, "fix this"'s `fix:<trigger>:<issue>:<subject>:`: the
  prefixes the minute keys had, so a click from just before an upgrade is found. What
  follows the window must read as an instant, so a subject that is another's and more
  (`ab`, `ab:c`) is a window of its own; the window is escaped for `LIKE`.
- **Admitted under a lock.** Whether a run starts or is skipped is decided in one
  transaction that takes the trigger's row (`FOR UPDATE`) and, for a trigger on a GitHub
  repository, one transaction-level advisory lock that every repository cap is counted
  under; the skip is written inside it. Firings that race are decided one after another:
  the first counts the others' undecided runs as live and is skipped, the next counts a
  skipped run as nothing, and one of them starts. A run admitted stays `created` and live
  until its session is made or its create fails.
- **A failed create's retry is a firing** for the caps: it is admitted as a new one is,
  set back to `created` under the lock if it starts, and `skipped` with the cap's reason
  if it does not.
- **A run with no session for ten minutes is ended.** `Triggers.end_unmade/1`, run on
  every tick of the scheduler (the plane's one periodic worker for triggers), sets a run
  that is `created`, has no session, and has not changed for ten minutes to `failed`,
  with the reason on the row, logs it, and audits it as `trigger.run.end` by `scheduler`
  on `<team>/<trigger>` with the run's id. The update is conditional on the row still
  having no session, so a create that finished late keeps its session. The next call with
  the run's key makes its session, as after any create that failed. Ten minutes because a
  create is a few writes and a placement that gives up after fifteen seconds.

## Choices not taken

- **Keep the minute and also look in the minute before.** Two clicks either side of :00
  each look before the other has written; as in Decision 927, a window needs the lock.
- **Hold the row lock across the create**, so a cap is counted and the session made in
  one step. A create is a harness call that places the session on a pod; inside the
  transaction the session row would be invisible to the pod until commit, and a slow pod
  would hold every firing of the trigger.
- **One advisory lock per repository or per team.** The profile's cap counts runs on
  every team's repositories, and the team's every repository; a lock narrower than the
  plane's repository runs would leave one of the two counted apart. Firings on
  repositories are few; one lock held for two counts costs nothing measurable.
- **End a sessionless run by `fired_at`.** A failed run retried now is `created` again
  with its old `fired_at`; `updated_at` is when it was last decided.

## Proof

`apps/troupe_plane/test/troupe/plane/trigger_sources_test.exs` ("the console's run is
the run of the person's click less than a minute before") and
`apps/troupe_plane/test/troupe/plane/github_issues_test.exs` ("a second click on the issue
less than a minute after the first is its run, across a minute's turn") move the first
run to the last tenth of a second of the minute before, under the old minute key, and
click again: on the chunk tip each made a second run. `trigger_ingress_test.exs`, "the
cap": three firings with keys of their own racing on a concurrency of 1, four times (on
the tip, all three skipped), and a failed run's retry beside the run that took its place
(on the tip, a second session). "a run left with no session is ended by the plane, said
why and audited": a run with no session for eleven minutes is ended and audited, one a
moment old is left, and the ended run's retry makes its session (on the tip,
`end_unmade/0` did not exist and the stuck run skipped every firing after it).
