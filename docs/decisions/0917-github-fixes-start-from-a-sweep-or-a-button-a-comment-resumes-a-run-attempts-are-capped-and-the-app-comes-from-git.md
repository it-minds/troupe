---
number: 917
title: "A trigger on a repository sweeps its open issues on a schedule and a person starts one from the console, each held to the trigger's policy; a comment on a run's draft resumes it as a review does; a sweep leaves an issue its runs have tried as often as allowed; and in GitOps mode a GitHubApp resource holds the App's settings and the teams' repositories, never its key"
date: 2026-10-18
status: accepted
issue: 147
paths:
  - apps/troupe_plane/lib/troupe/plane/github/issues.ex
  - apps/troupe_plane/lib/troupe/plane/github/review.ex
  - apps/troupe_plane/lib/troupe/plane/github/policy.ex
  - apps/troupe_plane/lib/troupe/plane/github.ex
  - apps/troupe_plane/lib/troupe/plane/gitops/github_app.ex
  - apps/troupe_plane/lib/troupe/plane/triggers.ex
  - apps/troupe_core/lib/troupe/git.ex
  - apps/troupe_worker/lib/troupe/worker/github/tree.ex
symbols:
  - Troupe.Plane.GitHub.Issues.sweep/2
  - Troupe.Plane.GitHub.Issues.fix/3
  - Troupe.Plane.GitHub.Issues.why_not/3
  - Troupe.Plane.GitHub.Review.resume_comment/2
  - Troupe.Plane.GitHub.Policy.max_attempts/2
  - Troupe.Plane.GitHub.reader/5
  - Troupe.Plane.GitHub.follow/3
  - Troupe.Plane.Gitops.GitHubApp.read/2
  - Troupe.Plane.Triggers.live?/2
  - Troupe.Git.run/3
  - Troupe.Worker.GitHub.Tree.write/1
gist: "Sweep and fix this go through Triggers.fire with the trigger's policy; being fixed = run live or its PR open; attempts default 1; GitHubApp CRD, no key"
---

- **A sweep is a trigger on a repository with a schedule of its own.** `source.sweep`, a
  five-field cron in UTC, beside `label` and `command`, rather than a schedule trigger that
  names a repository: a repository trigger is already the App's (905), its sessions already
  carry the repository and its runs the issue, and a sweep is one more way the same trigger
  finds an issue. `query`, GitHub's issue search qualifiers, takes the label's place for a
  sweep that looks for something else; the plane adds `repo:` and `is:issue is:open` and
  refuses a query that names a repository, an organisation, a user, a kind or a state, so a
  sweep cannot look outside its repository, and an item search answers from another
  repository is dropped all the same. The in-plane scheduler runs it (`Scheduler.tick/1`),
  with the same once-a-minute mark a schedule has, so two replicas sweep a minute once.
  Rejected: a schedule source with a repository, which would be a second kind of
  repository trigger with its own checks; and Hatchet, which a plane without it does not
  have.
- **One run per issue, through `Triggers.fire/5`.** Keyed by the trigger, the minute and the
  issue, `source: schedule`, with the issue read by the plane and reduced to the run's event
  as a delivery's is (`GitHub.Issue.found/4`), so the session gets it fenced as data and its
  title, body and comments never reach the template (905). The trigger's `concurrency`, the
  profile's and the team's runs at once (911) and the budget hold as for any run, because
  it is any run. **A sweep stops at the first run a cap skips**: the rest of its issues wait
  for its next minute, rather than a skipped run being recorded for every issue past the
  cap at every minute.
- **"Already being fixed" is a run in flight or an open pull request a run opened.** A run
  on the issue that a cap would count as live (still to start, working, or waiting on a
  person, `Triggers.live?/2`), by any trigger; or a run on the issue whose session recorded
  a pull request that GitHub lists open now. The second is "an open draft from this App":
  the record is the App's own (891), and a draft that waits for a person's review is the
  issue being fixed, by them. Read with one list of the repository's open pull requests per
  sweep, not a search by author, which would need the App's bot login and the search API's
  lower rate.
- **Attempts per issue, counted since a person last asked.** An attempt is a run the sweep
  started on the issue whose session has ended without being "being fixed": its pushes
  closed by three red rounds or its cap, its budget, turns or wall clock run out, failed, or
  finished with its pull request no longer open. A run a cap skipped, or one that never got
  a session, is not one. Counted from the newest run a person asked for, with a label or a
  command GitHub delivered or the console's fix this (`source` `webhook` or `manual`): a
  person asking starts the count again, and their own runs are not held to it. The cap is
  `spec.github.maxAttempts` on the profile and `max_attempts` on the team, the lower
  holding, as 911's caps do, and **one where neither says**: the sweep is the part nobody
  watches, and an issue a run could not fix once is more often one a run cannot fix than
  one a second run will. Rejected: counting only runs stopped by a red round or a cap,
  which leaves an agent that "finishes" without a pull request to be started on the same
  issue at every sweep for ever.
- **"Fix this" is `admin.trigger.fix {team, name, issue}`.** One issue of a trigger on a
  repository, by its number or its link on the App's host, which must be the trigger's
  repository. The plane reads it first with a token of its own (`issues: read`, narrowed,
  audited as `github.token` for the person): an open issue, not a pull request. Then
  `Triggers.fire/5` with `source: manual`, by the person, keyed by the trigger, the issue,
  the person and the minute, so a second click is the run the first made; audited as
  `trigger.fix`. It works in GitOps mode too, as `admin.trigger.run` does. In the console
  it is the trigger's own page, where the policy it is held to is already shown, behind a
  plain confirm that says what the plane checks; a link pasted there is the "paste an
  issue URL" way in. Rejected: a firing that takes the issue from the caller's body, which
  would let a caller put any text in front of the session as the issue.
- **Both are held to what a push would be, before anything starts.** The team lists the
  repository (911), and it is private or internal unless the profile's `allowPublic` is
  true, asked of GitHub at that moment; a run that could never push is not started. The
  pod still asks again at every push.
- **A conversation comment resumes a run as a review does.** `issue_comment.created` on a
  pull request goes to `GitHub.Review.resume_comment/2`, never to the triggers' commands,
  and resumes the session that recorded that pull request under 905's rules: the
  repository's owner, a member or a collaborator and never a bot (the App's own CI summary
  and stop comments among them), something to say, a draft of an installation the plane
  lists, recorded by exactly one session that is a trigger's run, its pushes not closed.
  An issue comment does not say whether the pull request is a draft, so the plane reads the
  pull request with a token of its own (`pull_requests: read`). The comment is the next
  input, fenced as `<<<github-comment` with its markers taken out of the text, audited as
  `github.comment`, pushed as `session.input` with the delivery's id.
- **The App from a repository is a `GitHubApp` resource, a CRD of its own.** One, named
  `github`, in the plane's namespace, read by the GitOps pass as a third kind after the
  profiles and the triggers (`Troupe.Plane.Gitops.GitHubApp`): `appId`, `apiUrl`,
  `installations` and `teams`, each team's `repositories`, `maxPushes`, `maxRuns` and
  `maxAttempts`. Rejected: a ConfigMap the plane reads, which has no schema the API server
  checks, no `kubectl explain`, and would be the one thing the pass reads that is not a
  resource of its own; and chart values, which the plane would read at boot only and which
  put a plane's App in the deployment rather than the repository the rest of it is in.
  - **Never the key or the webhook secret.** Those are transit's (885, 905) and are still
    sent through the console or `admin.github.put`, on a GitOps plane as on any other. A
    resource that has a `privateKey` is refused as a field the kind does not have.
  - **The resource is the whole of it**, as a `Trigger` is (737): a field it leaves out is
    that field's default, and a team it does not name lists no repository. A team it names
    that the plane does not have is reported `unknown_teams`, and its entry is used once the
    team is enabled. One that fails the checks `admin.github.put` and `admin.team.update`
    make is reported `refused` and not used.
  - **Locked elsewhere.** In GitOps mode `admin.github.put` refuses `app_id`, `api_url` and
    `installations`, `admin.team.update` and `admin.team.enable` refuse `github`, and
    `admin.github.delete` is refused, all as `managed_by_gitops`, except a delete of an App
    the cluster has no resource for (reported `missing`). The console shows them locked.
  - **Gone** from the cluster after the App followed it, the App's settings and every
    team's repositories go with it; the key and the secret stay in transit. An App set
    through the API before the plane read the cluster is reported `missing` and kept.
  - `github_app.resource_generation` is the generation followed; `admin.github.get` says it
    and where the settings come from. The plane's role reads `githubapps` in GitOps mode.
- **A skipped run keeps why.** `trigger_runs.reason` (the migration), written when a cap
  skips a run: the trigger's concurrency, the profile's or the team's runs at once. In
  `admin.runs.list`, in a delivery's outcome (`skipped`), and on the console's run page.
- **A push stages into an index of its own.** `Tree.write/1` copies what the agent staged
  (the tree its own index holds, written without changing it) into an index of a random
  name in the workspace's git directory, `git add -A` there and writes that tree, and
  removes it. `Troupe.Git.run/3` takes `index:`, a file name in the repository's git
  directory and nowhere else, set as `GIT_INDEX_FILE`. So a push refused for `.env` leaves
  nothing staged, and a `.gitignore` alone keeps the file out of the next one, while a file
  the agent itself staged or committed still counts as it did. Rejected: copying the
  agent's index file from the worker's VM, which would follow a link the agent planted at
  `.git/index` to whatever the VM can read; and starting from an empty index, which drops
  every tracked file a `.gitignore` also matches.
