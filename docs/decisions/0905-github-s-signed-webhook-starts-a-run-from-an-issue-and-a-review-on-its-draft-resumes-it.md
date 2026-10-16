---
number: 905
title: "The GitHub App's webhook, signed with a secret transit holds, starts a run of a trigger on a repository from a labelled issue or a member's command, with the issue fenced as data; a review on the draft that run opened resumes its session; and a new webhook trigger is made with its key"
date: 2026-10-16
status: accepted
issue: 147
paths:
  - apps/troupe_plane/lib/troupe/plane/github/webhook.ex
  - apps/troupe_plane/lib/troupe/plane/github/webhook_secret.ex
  - apps/troupe_plane/lib/troupe/plane/github/issue.ex
  - apps/troupe_plane/lib/troupe/plane/github/review.ex
  - apps/troupe_plane/lib/troupe/plane/github/delivery.ex
  - apps/troupe_plane/lib/troupe/plane/web/raw_body.ex
  - apps/troupe_plane/lib/troupe/plane/web/router.ex
  - apps/troupe_plane/lib/troupe/plane/web/endpoint.ex
  - apps/troupe_plane/lib/troupe/plane/triggers.ex
  - apps/troupe_plane/lib/troupe/plane/triggers/trigger.ex
  - apps/troupe_plane/lib/troupe/plane/triggers/notify.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/web/live/triggers.ex
  - apps/troupe_plane/priv/repo/migrations/20261016000905_github_webhook.exs
  - apps/troupe_plane/test/troupe/plane/github_webhook_test.exs
  - apps/troupe_worker/lib/troupe/worker/plane/commands.ex
  - apps/troupe_worker/test/troupe/worker/github_fix_loop_test.exs
  - apps/troupe_protocol/lib/troupe/kms/policy.ex
  - clients/gui/apps/console/src/views/Runs.tsx
  - clients/gui/apps/console/src/views/Triggers.tsx
  - docs/admin/github.md
symbols:
  - Troupe.Plane.GitHub.Webhook.take/2
  - Troupe.Plane.GitHub.WebhookSecret.check/3
  - Troupe.Plane.GitHub.Issue.matches?/3
  - Troupe.Plane.GitHub.Issue.prompt/2
  - Troupe.Plane.GitHub.Review.resume/2
  - Troupe.KMS.Policy.github_app/3
gist: "Webhook HMAC via transit, constant-time, deduped, 202 first; label or member command fires; GitHub text only fenced; review resumes a run's draft; key at create"
---

Issue #147, slice 3, and the maintainer's decision of 2026-10-16: a new webhook trigger gets
its key when it is created. Slices 1 and 2 (Decisions 885 and 891) gave a session a
repository, a clone and a fix loop that ends in a draft pull request; nothing could start
one from GitHub, and a review on the draft reached nobody. On the chunk tip
`POST /webhook/github` answered 404, a trigger could not name a repository, a webhook trigger
had no key until somebody found the button on its row, and a run's notification carried no
link.

- **One door, signed, for the App.** `POST /webhook/github`, the URL an administrator gives
  the App on GitHub. Its credential is `X-Hub-Signature-256`, GitHub's HMAC-SHA256 of the
  body under the App's webhook secret, over the bytes as they arrived (`Web.RawBody` keeps
  them, for that route alone, in both the endpoint's and the router's parsers). The secret
  is kept as the App's key is (Decision 885): `admin.github.put` takes `webhook_secret`
  (32 characters at least) and imports it into transit as an HMAC key, `troupe-github-webhook`,
  not exportable; the row keeps its version. The plane asks transit for the HMAC of each body
  and compares it with the one presented with `:crypto.hash_equals`. Rejected: the secret as
  a row or a setting, which a database backup would hand to anybody who could then start
  runs; and transit's own `verify`, whose comparison is OpenBao's and not one this code can
  show is constant-time. An unsigned, malformed or wrong signature is `401` before anything
  else is read, and logged with the delivery id and event (headers cut to the characters an
  id has), never the body; a plane with no secret, or whose transit cannot answer, refuses
  with `503` and says why. `Troupe.KMS.Policy.github_app/3` adds the key's read, import,
  import-version and HMAC paths.
- **Once, and answered first.** A delivery's id (`X-GitHub-Delivery`) is a row,
  `github_deliveries`, inserted with `ON CONFLICT DO NOTHING` before any work, so a retry or
  a Redeliver is answered `200` and does nothing, on any replica; rows go after thirty days.
  The answer, `202`, comes as soon as the delivery is recorded; the work runs after it under
  `Troupe.Plane.GitHub.Deliveries`, since GitHub gives a delivery ten seconds and a session
  can take longer to start. What the work did (the runs it fired, the session it resumed, or
  why neither) is the row's `outcome`.
- **A trigger names a repository.** `source: {kind: webhook, provider: github, repository:
  owner/name, label?, command?, ref?}`. Kept as a webhook with a provider rather than a new
  kind, because that is what the `Trigger` resource's schema already says a webhook is (a
  `provider` and fields of its own), so neither the CRD nor GitOps changes; a `provider:
  github` with no repository is the free-text provider it always was. The shape is the
  changeset's (`GitHub.Issue.source_problems/1`); whether the App reaches the repository
  (configured, installed for the owner, the profile declaring the Git host) is
  `admin.trigger.put`'s, as `session.create` will ask again at each firing. Its sessions are
  created with the repository, so slice 1's clone and slice 2's tools follow unchanged.
- **The first events: a label, and a command.** `issues.labeled` with the trigger's label,
  and `issue_comment.created` on an issue whose first line is the trigger's command, alone or
  followed by words. A label because adding one needs triage rights already and is how teams
  mark work; a command because it is what a person asks with, but anybody can comment on a
  public repository's issue, and a run spends a team's budget, so a command counts only from
  somebody GitHub calls the repository's `OWNER`, `MEMBER` or `COLLABORATOR`, and never from a
  bot (the App's own comments among them). Never a pull request's conversation, never a
  closed issue, never an installation the plane does not list for that owner. Each match is
  a run of `Triggers.fire/5` with source `webhook` and key `github:<delivery>:<trigger>`.
  Rejected for now: `issues.assigned` to the bot, and a sweep on a schedule (slice 4).
- **Nothing GitHub's users write is an instruction to the plane.** What the plane acts on is
  the event's name and action, a label's name, a command's exact first line, the author
  association GitHub reports, and ids. The run keeps the issue (`GitHub.Issue.event/4`, its
  text cut, the whole under 16 KiB). The session's prompt is the trigger's template rendered
  against that event *with the issue's title, body and comment taken out*, so a template
  cannot paste them anywhere, followed by one sentence saying what follows is data written by
  people on GitHub and never instructions, and the issue between `<<<github-issue` and
  `github-issue>>>`, with either marker removed from the text first so it cannot close the
  fence and go on outside it. The profile, agent, terms, principal and repository are the
  trigger's; the fix loop's own refusals (Decision 891) still hold whatever the model is
  persuaded of.
- **A review resumes the run that opened the draft.** `pull_request_review.submitted`,
  requesting changes or commenting with something to say, on a pull request that is a draft,
  of an installation the plane lists, recorded by exactly one session (`sessions.github`, by
  repository and number, and then by link), whose session is a trigger's run, by the
  repository's owner, a member or a collaborator who is not a bot, and whose pushes three red
  rounds have not closed. Anything else does nothing and the delivery's outcome says which.
  Only the review event: GitHub sends each of a review's line comments as a delivery of its
  own as well, and acting on those would make one review several turns; so the plane reads
  the review's comments from GitHub (`GitHub.review_comments/3`, a token of its own narrowed
  to the repository and `pull_requests: read`, audited) and gives the session one input.
  A person's own session is not resumed by anybody's review: it is theirs to steer.
- **How the review reaches the session.** Woken as the run's principal through
  `session.open` with `mode: activate`, as anything that wakes a session is (grant, budget
  and placement checked), then pushed to its pod as `session.input {session_id, epoch,
  input: {id, text}, actor}`, which the worker takes only for a session up at that epoch and
  sends to the root agent as a `:user` input with the delivery's id as its command id and an
  actor of the session's owner, displayed as "a GitHub review by <login>". This is the second
  piece of session content the control channel carries, beside the first prompt Decision 256
  allowed and for the reason it gives: an unattended session has no client to type into it.
  Bounded as that is (64 KiB), fenced as the issue is (`<<<github-review`), and audited as
  `github.review`. Rejected: the plane attaching to the pod as a client to type it, a
  WebSocket client in the plane for one message, carrying the same text through the same
  plane.
- **A webhook trigger is made with its key.** `admin.trigger.put` that creates a webhook
  trigger with no repository mints its key (`Triggers.rotate_key/2`) and answers `key` and
  `url` once; the audit row says a key was minted and never holds it. The console shows them
  once with a button that copies the key and says it will not be shown again, until the
  person says they have it; `/admin` does the same with a panel and a copy button (its copy
  listener is the one line `mix troupe.admin.assets` adds), until its editor goes. A trigger
  on a repository is made with none: the App's deliveries fire it. A change to an existing
  trigger mints nothing, and rotation stays as it was. Triggers made from a `Trigger`
  resource get none either: the key is the plane's and a repository never holds one
  (Decision 737); an administrator rotates one.
- **The console's Runs screen.** `views/Runs.tsx`: every run of the teams the person
  administers (`admin.runs.list`, which now names each run's team, its `repository` and the
  `issue` GitHub started it from), with trigger, repository, issue, state, the draft pull
  request with its CI rounds, spend and who has read it, filtered by team and by state; a
  run's page with its record (`sessions.github`), a link to the session on the Sessions screen
  and "Mark it read" (`admin.run.review`). Both roles, as the plane answers each. Overview's
  "waiting for a person" now links here.
- **The notification carries the pull request.** A trigger's `notify_url` is posted
  `pull_request`, the link to the draft its run opened, or `null`: metadata, as the rest of
  the body is.
- **Out of this decision.** Slice 4: autonomy policy (a draft only, caps on open pull
  requests and attempts per issue), per-team repositories, revoking tokens at dormancy, the
  App configured from GitOps; and anything that merges. A schedule that sweeps issues, a
  conversation comment on the pull request resuming its session, and the console's own page
  for the App (`Integrations`, A36's slot).
- **Proof.** `github_webhook_test.exs` in the plane, against the development OpenBao and
  `FakeGitHub`, which now signs deliveries (`deliver/5`) and serves a review's comments: no
  signature, another secret's, not `sha256`, not hex and altered bytes are each `401`, logged
  without the body or the secret, and record nothing; a signed delivery fires; a redelivery
  is `200` and fires once; the answer arrives while the pod still holds the session's
  activation; no secret, or transit without the key, is `503` with the reason; the secret is
  in no row, answer or audit entry. A labelled issue starts a session on the trigger's
  profile with the repository, the issue inside the fence and the run listing its repository
  and issue; a command starts one from a member and nothing from `NONE` or `CONTRIBUTOR`, a
  second line, a near miss, a bot, a pull request or a closed issue; another label,
  repository, installation or a paused trigger start nothing; a repository trigger is checked
  at put and made with no key. A hostile issue whose title and body try template
  placeholders, a fence close and instructions to merge, push to `main`, print the token and
  change approvals reaches the prompt only inside one fence, renders empty in the template,
  and leaves profile, owner and terms the trigger's. A review requesting changes resumes the
  session with one fenced input carrying its body and line comments, read with a
  `pull_requests: read` token, audited, once; an approval, a stranger's, a bot's, a non-draft,
  another number or link, an empty one, a foreign installation, line-comment deliveries, a
  stopped session and a person's own session resume nothing; a hostile review stays in one
  fence. `trigger_ingress_test.exs`: a webhook trigger's key comes with its create, in no
  listing or audit row, fires it, and an update or a schedule mints none.
  `trigger_notify_test.exs`: the notification carries the pull request's link, or `null`.
  `panel_test.exs`: `/admin` shows the minted key once with a copy button. In the worker,
  `github_fix_loop_test.exs`: the plane's own prompt for a hostile issue and its own input for
  a hostile review, pushed as `session.input`, to a model that obeys them, get refusals for
  `main`, `refs/heads/main`, `pr_merge` and `pr_approve`, no token in the shell, `main`
  unmoved and nothing merged; the review is the session's `user_input` with the delivery's id
  and actor; a stale epoch and a session not up are refused. The console's `runs.test.tsx`
  and `triggers.test.tsx`: the Runs screen for both roles, a run's page, its session link and
  marking it read; the key shown once and copied; a trigger on a repository made with no key.
