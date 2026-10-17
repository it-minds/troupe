---
number: 911
title: "A fix-loop run names only a repository its team lists, pushes to a public one only where its profile allows, never carries a denied path or a mounted secret, stops at its caps as three red rounds stop it, and has its tokens revoked when its session goes dormant"
date: 2026-10-16
status: accepted
issue: 147
paths:
  - apps/troupe_protocol/lib/troupe/push_paths.ex
  - apps/troupe_plane/lib/troupe/plane/github/policy.ex
  - apps/troupe_plane/lib/troupe/plane/github.ex
  - apps/troupe_plane/lib/troupe/plane/identity/team.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/admin/api.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/triggers.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/extends.ex
  - apps/troupe_plane/priv/repo/migrations/20261016000911_team_github.exs
  - apps/troupe_plane/test/support/fake_github.ex
  - apps/troupe_plane/test/troupe/plane/github_policy_test.exs
  - apps/troupe_worker/lib/troupe/worker/github.ex
  - apps/troupe_worker/lib/troupe/worker/github/api.ex
  - apps/troupe_worker/lib/troupe/worker/github/secrets.ex
  - apps/troupe_worker/lib/troupe/worker/git_credentials.ex
  - apps/troupe_worker/test/troupe/worker/github_fix_loop_test.exs
  - charts/troupe/crds/workerprofile.yaml
  - clients/gui/apps/console/src/views/Profiles.tsx
  - clients/gui/apps/console/src/views/Team.tsx
  - docs/admin/github.md
symbols:
  - Troupe.PushPaths.denied/2
  - Troupe.Plane.GitHub.Policy.listed/3
  - Troupe.Plane.GitHub.Policy.for_session/1
  - Troupe.Plane.GitHub.Policy.over_runs_cap/3
  - Troupe.Plane.GitHub.repository/3
  - Troupe.Worker.GitHub.Secrets.copies/2
  - Troupe.Worker.GitHub.API.revoke/1
  - Troupe.Worker.GitCredentials.forget/2
gist: "Team lists a session's repos; public refused unless profile allows; default denylist can't shrink; push cap stops like 3 red rounds; tokens revoked at dormancy"
---

Issue #147, slice 4, as the maintainer decided it on 2026-10-16: private by default, a
path denylist on the profile checked on every push, per-team repository lists (#653), caps,
and installation tokens revoked at dormancy. Slices 1 to 3 (Decisions 885, 891 and 905)
gave a session a repository, a fix loop ending in a draft pull request, and runs started
from GitHub; nothing bounded where a run could push or what it carried. On the chunk tip a
session pushed `.env` to a public repository like any other file, every team named any
repository the App's installations covered, a run's pushes had no limit but three red
rounds, and a dormant session's tokens kept working until their hour ran out.

- **Two owners, the stricter holds.** The worker profile's `spec.github` (a platform
  admin's) takes `allowPublic`, `denyPaths`, `maxPushes` and `maxRuns` beside
  `permissions`; a team's `github` (a new column, `teams.github`, its own administrators'
  through `admin.team.update`) takes `repositories`, `max_pushes` and `max_runs`. Caps are
  the lower of the two where both are set. `GitHub.Policy` reads both. Rejected: a policy
  per repository, which would be a third place to look for one answer; and the team setting
  `allowPublic` or the paths, which are what a platform admin decides about where data may
  go.
- **Per-team repositories, checked three times.** At `session.create`
  (`GitHub.repository/3`, now with the team), at `admin.trigger.put` for a trigger on a
  repository, and at every token (`GitHub.credential/2`, the clone's included), so a
  repository taken off the list gets nothing from the next token on. `owner/name`, or
  `owner/*` for every repository of the owner; compared without case. **A team that lists
  nothing names nothing**, and a session with no team names nothing: an upgrade leaves every
  team with an empty list until a team admin fills it in, which is the safe direction for a
  list whose job is to say no. The App's installations still bound it: an owner the App is
  not installed for is refused whatever a team lists. Rejected: an empty list meaning every
  repository, which is the behaviour this replaces and would make "lists none" and "never
  looked" the same answer.
- **Private by default, asked at push time.** `git_push` and `pr_open` ask GitHub for the
  repository (`GET /repos/{owner}/{name}`, which every App token may) and refuse when it is
  public and the profile's `allowPublic` is not `true`. `private` and `internal` pass;
  `public`, or an answer that says neither, is refused. Asked at every push rather than
  remembered from the clone, since a repository can be made public in between; the cost is
  one read per push. The plane hands `allow_public` to the pod in the fix loop's credential
  (`policy`), with the rest of what the pod checks.
- **A path denylist, checked before anything is sent.** `Troupe.PushPaths` (in the
  protocol app, since the plane validates patterns and the pod matches them). Defaults that
  no profile can take away: `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `id_rsa*`,
  `id_dsa*`, `id_ecdsa*`, `id_ed25519*`. A profile's `denyPaths` adds to them; `effective/1`
  starts from the defaults even if the plane sent none. Patterns read as `.gitignore`'s: a
  name alone at any depth, file or directory; a path with `/` from the root, with the
  directories under it; `*`, `?`, `**`; either case, since a case-insensitive checkout makes
  `.ENV` the same file. What is matched is **every path the push adds or changes**, the
  tree diff the push would send: a file already on GitHub that the push does not touch is
  not this push's to refuse, and refusing it would stop every push to a repository that
  commits an `.env.example`. A refusal names every path with the pattern that caught it,
  says how to leave them out (`.gitignore`, then `git rm --cached` for one a refused push
  staged), and no blob, tree, commit or ref is written. A visibility refusal and a path
  refusal are said together, so a push refused for both is refused for both.
- **Mounted secrets.** The pod's secret directories (`:secret_dirs`, by default
  `/var/run/secrets`, where its projected tokens are, and the MCP identities) are not in
  the agent's sandbox, so a copy of one in the tree means something got past that.
  `GitHub.Secrets` refuses a path the push would send that is under one of them, a link into
  one, or a file whose bytes are a mounted file's: found by comparing git blob names (SHA-1
  and SHA-256) with the blob names of the mounted files, so it is exact, costs one hash per
  mounted file, and copies no secret anywhere. Files under 16 bytes are skipped, being no
  secret and any other file's name. Limit: a projected token rotates, and a copy of an
  earlier one no longer matches.
- **No content scan.** Left out on purpose: patterns for "obvious secrets" in what a push
  carries would be guesses, refuse test fixtures that are keys on purpose, and look like a
  guarantee they are not. The names above are exact; the content of a push is what GitHub's
  own secret scanning and push protection are for, which an organisation turns on for its
  repositories.
- **A cap of pushes stops a run as three red rounds stop it.** When the record has as many
  pushes as the cap and the agent asks for another, the pod records `stop` (`{reason:
  "pushes"}`, which the plane takes only at the cap), the record's `stopped` says `its cap of
  N pushes` with `cap: "pushes"`, the bot comments on the draft, the write token is dropped
  and revoked, and the agent is told to comment what it tried and stop. The plane holds it
  without the pod: a push recorded past the cap is refused, and a write token minted at the
  cap has `contents: read`. The stop is at the push asked for past the cap rather than at the
  last one allowed, so the run has a pull request to say it on, and the last push's CI is
  still counted.
- **A cap of runs at once.** `maxRuns` on the profile and `max_runs` on the team count the
  live runs of triggers on a repository (what a trigger's own `concurrency` counts as live)
  on that profile and on that team, across their triggers; a firing over either is recorded
  `skipped` with the reason in the log, as one over a trigger's own concurrency is. Only
  runs on a repository count: these are the fix loop's caps, and a trigger that does not
  touch GitHub is not what they bound. The run's budget is checked as before, first, by the
  session it would start.
- **Tokens die with their activation.** `GitCredentials.forget/2` revokes what it drops:
  each unexpired token goes to GitHub's `DELETE /installation/token`, made with the token
  itself, at the API URL the plane put in it (now in the clone's credential too). It runs
  when the session's manager stops (dormancy, a stop, a crashed tree), when an activation
  starts, and when a stop closes pushes; after the caller is answered, in a task, logging the
  session and the expiry and never the token. A clone-only profile that does not declare the
  API host cannot revoke its clone token from the pod, and that token runs out on its own.
  Rejected: the plane revoking them, which would need it to keep every token it minted.
- **Inheritance.** Under `extends` (Decision 908) a parent's `allowPublic: false` holds,
  `denyPaths` are added, and `maxPushes` and `maxRuns` only narrow.
- **The console.** A profile's page reads the policy and its editor writes the four keys,
  carrying `permissions` through as loaded (Decision 900); a team's page has a **GitHub**
  tab where its own administrators list repositories and set the caps behind a preview.
- **The CRD.** `spec.github` names the four keys, so the cluster's admission checks them
  as the plane does.
- **Out of this decision.** The App configured from GitOps (#653, #634): a plane-level
  resource or chart values, the console's Integrations page read-only in `gitops` mode, is
  not small and is a follow-up. A schedule that sweeps issues, the console's "fix this", and
  a conversation comment resuming a run (#147's remaining asks).
- **Proof.** `github_policy_test.exs` in the plane, against the development OpenBao and the
  fake GitHub: every malformed profile key refused by name; the credential's `policy` with
  the defaults, the profile's paths and the lower cap; inheritance; a team admin's list,
  read key by key, refused by name, audited and shown, another team's admin refused; a token
  refused for a repository taken off the list, for a team that lists none and for a session
  with no team, and the App bounding a team's `acme/*`; a push past the cap refused, `stop`
  refused before the cap and taken at it, once, and the token at the cap read-only.
  `github_test.exs`: creation refused for a repository the team does not list and for a
  team that lists none. `github_webhook_test.exs`: a trigger put on an unlisted repository
  refused; a second run across the team's triggers skipped over the team's cap of one, and
  over the profile's, and started when the cap allows. In the worker,
  `github_fix_loop_test.exs`, end to end with the sandbox on: a push and a pull request
  refused once the repository is made public, nothing written, and both allowed when the
  profile allows public ones; a push with the default and the profile's denied paths
  refused naming each, `src/.envrc` and `docs/notes.json` not caught, nothing written, and
  the same tree pushed once `.gitignore` leaves them out; a copy of and a link to a mounted
  secret refused without the secret in the answer; the team's cap of two below the
  profile's five, the third push stopping the run with the bot's comment, the old token
  revoked and the next read-only; tokens revoked at dormancy and when the session stops, and
  a revoked token reading nothing; and a hostile issue asking for `.env` pushed to a public
  fork refused for both reasons with nothing written and no other repository asked about.
  The console's `profiles.test.tsx` and `teams.test.tsx`: the editor's mapping onto
  `spec.github`, the policy read and edited through the preview, a team's list and caps read,
  and changed by its own admin with the plane's refusal shown. The reproduction on the chunk
  tip: seven of the worker tests and nine of the plane's failing at the assertions above
  (`github takes permissions, not denyPaths`, a push to a public repository taken, no
  revocation).
