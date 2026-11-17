---
number: 891
title: "A pod session pushes its troupe/* branch through GitHub's API as the plane's App, opens a draft pull request and reads its CI with worker-owned tools whose token its profile narrows; three red CI rounds close its pushes, and nothing merges"
date: 2026-10-13
status: accepted
issue: 147
paths:
  - apps/troupe_worker/lib/troupe/worker/github.ex
  - apps/troupe_worker/lib/troupe/worker/github/api.ex
  - apps/troupe_worker/lib/troupe/worker/tools/git_push.ex
  - apps/troupe_worker/lib/troupe/worker/tools/pr_checks.ex
symbols:
  - Troupe.Worker.GitHub.push/5
  - Troupe.Worker.GitHub.open_pull_request/4
  - Troupe.Worker.GitHub.comment/3
  - Troupe.Worker.GitHub.checks/2
  - Troupe.Plane.GitHub.record/3
  - Troupe.Plane.GitHub.grants/1
  - Troupe.Plane.GitHub.credential/2
  - Troupe.Tool.available?/2
gist: "Worker tools push troupe/* via GitHub's API as the App, draft PR, no force or merge; token is the profile's grants; 3 red CI rounds close pushes"
---

Issue #147, slice 2, within #653's rules and the maintainer's decision of 2026-10-13: a
run pushes to `troupe/*` branches as the App's bot and opens a draft pull request; it
reads CI and pushes fixes; after three red CI rounds on its own pull request it stops,
comments what it tried and what still fails, and leaves the draft for a person; the run's
budget applies first; it never merges.

- **Four worker-owned tools, for a session created with a repository and no other.**
  `git_push`, `pr_open`, `pr_comment` and `pr_checks` are the worker's
  (`Troupe.Worker.Tools`), registered on a pod in `config/runtime.exs`. A host's tool may
  now say which sessions have it (`Troupe.Tool.available?/1`, optional); these answer from
  the repository the activation carried, so a session with none is neither offered them
  nor let call them, and the answer never changes during a session. Each asks like `shell`
  unless a profile says otherwise; a profile made for unattended fixing marks them `auto`,
  which is how #147 said an unattended run gets its tools (the `approvals` term stays
  `wait` or `deny`).
- **They run in the worker's VM with the fix loop's token, which the agent never holds.**
  `git.credential` takes `access: "write"`, and the plane mints that token with exactly
  what the session's worker profile grants in `spec.github.permissions`: some of
  `contents` (read, write), `pull_requests` (read, write), `checks` (read) and `statuses`
  (read), narrowed to the one repository, an hour long, audited as `github.token` with its
  permissions. A profile that grants none of those clones and does no more, and a write
  token is refused with that sentence. The clone's token stays `contents: read`, held apart
  (`GitCredentials` keys by access). The calls go from this VM to the API URL in the
  credential, with the token in the `authorization` header and nowhere else; so a profile
  whose sessions push declares the API's host as well as the Git host in `egress.gitHosts`
  (`api.github.com` beside `github.com`; an Enterprise Server has one host), and the plane
  refuses a write token where it does not.
- **A push is a commit made through GitHub's API, not a `git push`.** The tool stages the
  working tree (`git add -A`, through `Troupe.Git`, token-free), writes its tree, and sends
  the files that differ from the commit it builds on as blobs, then a tree, then a commit
  with no author, committer or signature, then moves the branch. GitHub makes such a
  commit the App's bot's and signs it, which answers #653's open question: an
  organisation that requires signed commits gets verified ones without a signing key of
  ours. No git process ever holds a token that can write, and none reads the workspace's
  `.git/config` with one; the tree GitHub builds must be the working tree's, by name, or
  nothing is committed. Rejected: a `git push` from the sandbox with the token in its
  environment, which reads the agent-writable `.git/config` (`url.*.insteadOf`,
  `http.proxy`, `http.sslVerify`, `include.path`) with a writing token in hand, and makes
  commits authored by whatever name the pod writes, unsigned; and the plane making the API
  calls for the pod, which would carry a pull request's text and comments over the control
  channel, which carries no session content (Decision 256).
- **One commit per push, on the session's last one.** A push is the working tree as one
  commit whose parent is the session's last pushed commit or, for its first push, the
  commit its clone checked out, which the pod reports right after the clone (`base`). Both
  are on GitHub, so a push carries no commit but its own, whatever the agent committed
  locally under whatever name. Its message is the agent's, with any `Troupe-Session:` line
  of its own taken out and the session's added as a trailer. Bounded: 500 files, 10 MiB a
  file, 50 MiB in all, or nothing is sent.
- **#653's rules, kept by the worker and again by the plane.** Only a branch under
  `troupe/`, and the session's one: the first push names it (`troupe/session-<id>` unless
  the agent names another), any other is refused before GitHub is asked, and the plane
  refuses to record one. Never a force: the branch is made with a create that fails if it
  is there, and moved with `force: false`, so a branch a person pushed to is left as it is.
  Never a merge or an approval: no tool, and no function in `Troupe.Worker.GitHub.API`,
  merges, approves, marks ready, closes or deletes. A draft or nothing: `pr_open` asks for
  a draft and refuses an answer that is not one; a repository that takes no drafts gets no
  pull request. One pull request per session, from its branch into the branch it was
  cloned from or the default branch. An organisation's ruleset for `troupe/*` keyed on the
  App is the real fence (`docs/admin/github.md` has one); these are belt and braces.
- **The CI loop is the tools and the agent's instruction, not a workflow.** The loop's
  middle step, working out why CI is red and fixing it, is open-ended agent work, which a
  workflow (Decision 888) could only hand to an agent; and its limits must hold whatever a
  model does, so they cannot live in a prompt either. The rules are in the tools and the
  plane, and the instruction is the tools' own descriptions and answers ("Read its CI with
  pr_checks", "That is red round 1 of 3", "Comment ... then stop"), with an example agent
  in `docs/admin/github.md` for a profile's bundle.
  - A **round** is the CI of a commit the session pushed to its pull request, once it has
    finished. `pr_checks` waits for it (as long as a tool may), and reads check runs or
    commit statuses as the profile grants; a red or green result on the pull request is
    reported to the plane, once a commit.
  - **A push waits for CI on the last one.** While it is running, or for two minutes in
    which nothing has reported, a push is refused with the reason, so no round goes
    uncounted; a finished red one the agent never read is counted then.
  - **The third red round stops the session.** The plane marks the record `stopped`, and
    every write token after that is minted with `contents: read`: the pod could not push
    if it tried. The worker drops its token, comments on the pull request, as the bot and
    in words that are the code's, which rounds were red and which checks failed, and tells
    the agent to comment what it tried and stop. The draft stays for a person.
  - **The budget comes first.** The run's terms (budget, turns, wall clock) stop it before
    or between rounds as they stop anything; nothing here extends them.
- **Untrusted input is data.** The tools' permissions come from the profile and the
  session's row, never from anything the agent read: an issue body or a comment that asks
  for a push to `main`, a merge or the token gets refusals, no tool and no token. What
  failing checks reported is shown fenced, marked as the repository's CI output and never
  instructions; it is written by code anyone could change in a pull request.
