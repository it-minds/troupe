---
number: 885
title: "A plane has one GitHub App whose key is in OpenBao transit; a session names one repository when it is created, and its pod clones it on the first activation with an installation token the plane mints for that repository alone, read-only, which only the pod's own git ever holds"
date: 2026-10-12
status: accepted
issue: 147
paths:
  - apps/troupe_plane/lib/troupe/plane/github.ex
  - apps/troupe_plane/lib/troupe/plane/github/app.ex
  - apps/troupe_plane/lib/troupe/plane/tokens.ex
  - apps/troupe_worker/lib/troupe/worker/git_credentials.ex
symbols:
  - Troupe.Plane.GitHub.credential/2
  - Troupe.Plane.GitHub.repository/2
  - Troupe.Plane.GitHub.Key.import/2
  - Troupe.Worker.GitCredentials.credential/2
  - Troupe.Worker.Session.Clone.ensure/4
  - Troupe.KMS.Policy.github_app/2
gist: "One App per plane, key in transit; a session's repo is checked at create; its pod clones once with a 1h read-only token its shell never holds"
---

- **One App per plane, set through the admin API.** `admin.github.get` and
  `admin.github.put` (platform admin to write, team admin to read; audited as
  `github.put`): the App ID, the API URL (GitHub's own unless set; GitHub Enterprise Cloud
  and Server from the start, since it is one field), and the installations the plane may
  use, `{owner, installation_id}`, one per owner. A row of its own (`github_app`), not
  `Troupe.Plane.Settings`: a setting there is a value the deployment provides and a row
  overrides, and none of these has a deployment value; the key is not in the database at
  all.
- **The key is in transit and nowhere else.** `private_key` is the PEM GitHub downloads.
  The plane wraps it for transit's bring-your-own-key import (the key under a fresh
  AES-256 key with RFC 5649 key wrap, that key under transit's wrapping key with RSA-OAEP
  and SHA-256), imports it as `troupe-github-app`, not exportable, and keeps its type, its
  fingerprint as GitHub shows it, and its transit version. Transit signs the App's JWT
  (RS256, `iss` the App ID, issued a minute back, nine minutes long). A second key becomes
  the next version, which is the rotation, and transit signs with the newest; GitHub holds
  both until the old one is deleted there. Rejected: the key as a secret setting in the
  database, as the OIDC client secret is, readable by whoever reads a backup; and an App
  key the plane loads into its own memory to sign with. Both are a copy of the App outside
  the one place built not to give it up.
- **A session names a repository when it is created.** The plane's `session.create` takes
  `repository`, `"owner/name"` or `{owner, name, ref}`, and refuses it, `invalid_params`
  with `field: "repository"` and a sentence, when the plane has no App, the App has no
  installation for that owner, or the worker profile does not declare the Git host in
  `egress.gitHosts` (a pod reaches nothing else, and a typo is better refused at the door
  than met as a clone that times out). It is a column on the session's row
  (`sessions.repository`), in the session's JSON, and on every activation the plane
  pushes.
- **The pod asks for the token, the plane mints it per request.** `git.credential
  {session_id}` on the control channel, answered only for a session the pod holds (the
  rule `kms.assertion` keeps), with the repository read off the row, refused for a session
  whose owner is deactivated, as an assertion is. Each answer is a new installation token,
  asked of GitHub with the App's JWT and narrowed in the request to `repositories:
  [name]` and `permissions: {contents: read}`; GitHub ends it after an hour. The answer
  also carries the URL to clone from, built from the App's API URL, so neither the
  activation nor the session chooses where a token is sent. Every token is an audit entry,
  `github.token`, by the pod for the session's owner, naming the session, the repository
  and the expiry. Synchronous on the pod's connection, as `kms.assertion` is.
- **What clones, and where the token goes.** The worker, at the activation whose restore
  found no archive and left the workspace empty (`Troupe.Worker.Session.Clone`): shallow,
  one branch, no tags, at the session's `ref` or the default branch. Later activations
  restore the archive, so a session is cloned once and its tree is its own afterwards.
  The git is the pod's, through `Troupe.Reaper`, so on a worker it runs in the sandbox over
  the workspace alone. The token is in that one process's environment, and a credential
  helper scoped to the one Git host is on its command line, which answers git's request
  for a password with it and does nothing else; the system's and the user's git
  configuration are not read, hooks and the filesystem monitor are off, only the URL's
  protocol is allowed, a redirect is not followed. None of it is written into the clone:
  the workspace's `.git/config` names the remote and no credential, so neither the
  workspace, its archive nor its log holds the token. A clone that fails fails the
  activation with git's or GitHub's reason, the token taken out of it, and an activation
  that fails takes away what it put on the pod.
- **The agent's shell never has it.** Rejected: a credential helper or `url.insteadOf`
  in the sandbox's own git configuration, which the slice's first sketch offered. It
  would hand the token to any command the agent runs, approved once, and to anything that
  reads the sandbox's files; #653 decided the agent's shell never holds a git credential,
  and writes go through worker-owned tools that attach it themselves. So "redacted from
  tool output as other secrets are" holds the way it holds for a person's MCP credential:
  no tool output can carry what no tool can reach. The pod's link to the plane hides the
  line it is reading and its last message from a crash report, and its enrolment token.
- **Egress.** A pod reaches the Git host its profile declares; the plane dials the App's
  API, which is in `Troupe.Egress` and `docs/egress-allowlist.md`.
