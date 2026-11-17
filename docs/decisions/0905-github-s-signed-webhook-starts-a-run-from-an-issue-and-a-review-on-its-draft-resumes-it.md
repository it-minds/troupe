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
  - apps/troupe_plane/lib/troupe/plane/triggers/trigger.ex
  - apps/troupe_protocol/lib/troupe/kms/policy.ex
symbols:
  - Troupe.Plane.GitHub.Webhook.take/2
  - Troupe.Plane.GitHub.WebhookSecret.check/3
  - Troupe.Plane.GitHub.Issue.matches?/3
  - Troupe.Plane.GitHub.Issue.prompt/2
  - Troupe.Plane.GitHub.Review.resume/2
  - Troupe.KMS.Policy.github_app/3
gist: "Webhook HMAC via transit, constant-time, deduped, 202 first; label or member command fires; GitHub text only fenced; review resumes a run's draft; key at create"
---

- **One door, signed, for the App.** `POST /webhook/github`, the URL an administrator
  gives the App on GitHub. Its credential is `X-Hub-Signature-256`, GitHub's HMAC-SHA256
  of the body under the App's webhook secret, over the bytes as they arrived. The secret
  is kept as the App's key is (Decision 885): `admin.github.put` takes `webhook_secret`
  (32 characters at least) and imports it into transit as an HMAC key,
  `troupe-github-webhook`, not exportable; the row keeps its version. The plane asks
  transit for the HMAC of each body and compares it with the one presented with
  `:crypto.hash_equals`. Rejected: the secret as a row or a setting, which a database
  backup would hand to anybody who could then start runs; and transit's own `verify`,
  whose comparison is OpenBao's and not one this code can show is constant-time. An
  unsigned, malformed or wrong signature is `401` before anything else is read, and logged
  with the delivery id and event (headers cut to the characters an id has), never the
  body; a plane with no secret, or whose transit cannot answer, refuses with `503` and
  says why.
- **Once, and answered first.** A delivery's id (`X-GitHub-Delivery`) is a row,
  `github_deliveries`, inserted with `ON CONFLICT DO NOTHING` before any work, so a retry
  or a Redeliver is answered `200` and does nothing, on any replica; rows go after thirty
  days. The answer, `202`, comes as soon as the delivery is recorded; the work runs after
  it under `Troupe.Plane.GitHub.Deliveries`, since GitHub gives a delivery ten seconds and
  a session can take longer to start.
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
  `url` once; the audit row says a key was minted and never holds it. A trigger on a
  repository is made with none: the App's deliveries fire it. A change to an existing
  trigger mints nothing, and rotation stays as it was. Triggers made from a `Trigger`
  resource get none either: the key is the plane's and a repository never holds one
  (Decision 737); an administrator rotates one.

- **The notification carries the pull request.** A trigger's `notify_url` is posted
  `pull_request`, the link to the draft its run opened, or `null`: metadata, as the rest of
  the body is.
