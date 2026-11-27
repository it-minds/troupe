---
number: 1112
title: "A plane session holds a list of GitHub repositories, named at create or attached and taken off later by its owner, within its profile's spec.github and maxRepositories: the first cloned at the workspace's root, each other in <owner>/<name>, each with its own token, record, lock and caps"
date: 2026-11-26
status: accepted
issue: 1207
paths:
  - apps/troupe_plane/lib/troupe/plane/github.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/sessions/session.ex
  - apps/troupe_plane/lib/troupe/plane/github/policy.ex
  - apps/troupe_worker/lib/troupe/worker/session/repositories.ex
  - apps/troupe_worker/lib/troupe/worker/github.ex
  - apps/troupe_worker/lib/troupe/worker/git_credentials.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
gist: "sessions.repositories (first mirrored as repository/github); spec.github + maxRepositories (3, 1-10) gate create and attach; owner adds/removes; first at root, rest in owner/name; per-repo token, record, lock, caps; agent told"
---

Issue #1207. Extends Decisions 885 and 897, which gave a session one repository named at
create; their checks, tokens and the rule that no token reaches the shell hold for each one.

**The list.** `sessions.repositories`, each `{owner, name, ref, path, attached_by,
attached_at, github}`, written whole under the row's lock; `repository` and `github` are the
first entry's, written with it, for a client and a pod from before the list. `session.create`
takes `repositories` beside `repository`, never both. A list, or an attach, needs the
profile's `spec.github` and holds to `spec.github.maxRepositories` (three, one to ten, only
lowered by `extends`); `repository` alone still clones on a profile without it, as before.
A sibling or a fork takes the parent's list. Not chosen: a separate `spec.github.attach`
switch, since a profile that clones already trusts its team's list.

**Who.** The owner, or a holder of the owner role, as a bundle raise: a steerer may not.
Audited. The row is written before the pod is told, so a token is only ever for what the
row holds; a pod that could not clone takes it off again.

**Where.** The first at the workspace's root, as one always was, so instruction files,
agents and skills are found where a repository's are and an older session's archive stays
right; every other in `<owner>/<name>`, which the root clone excludes from what it stages,
so a push never carries another clone. Not chosen: every one in `<owner>/<name>`, which
moves the working copy of every fix-loop session and hides its instructions.

**Per repository.** A token for that repository alone (`git.credential repository`), a record
with its branch, pull request, rounds and push cap (`github.record repository`), and a lock
the tools and a removal share: taking one off is `busy` while a push, a pull request or a CI
read holds it. The tools default to the only repository and refuse naming the choices.

**Sleep and wake.** As one clone: the archive keeps the directories; an activation clones
one that is missing and deletes one the log held that the list no longer has.

**The agent.** The root writes `session_repository_changed` with the whole list and its turn
context's `configuration` section says what it holds and what moved.

Undone, a second repository is a clone with no token of its own, or a push from the root
that carries another repository as a gitlink, or a token for something the row never held.
