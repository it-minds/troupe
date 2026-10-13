---
number: 897
title: "A sibling and a fork start on their parent's repository, checked again as a create checks one, and are refused rather than started without it"
date: 2026-10-13
status: accepted
issue: 147
paths:
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/test/troupe/plane/github_lineage_test.exs
gist: "session.spawn and session.fork pass the parent's repository to the create path, which checks it against the App and the new profile; refused if it no longer passes"
---

Decision 885 gave a session one repository, named when it is created, and said that
nothing else named one yet: "a fork and a sibling inherit none". That left a sibling an
agent spawned, or a fork a person made to try something else, working in an empty
directory on a pod while its parent worked on the code. D126 recorded it.

**What is decided.** `session.spawn` and `session.fork` hand the parent's `repository`
(owner, name and ref, as the row keeps it) to `session.create`, the path both already take.
So the new session's repository is checked exactly as a new one is: the plane's App must
still have an installation for the owner, and the profile the session starts on must
declare the Git host in `egress.gitHosts`. It is kept on the new row, and handed to the
pod on every activation, as any session's is.

**Refused, not dropped.** When the parent's repository no longer passes (the App's
installation for that owner was removed, or a fork lands on a profile that does not
declare the host), the spawn or fork is refused with the same `invalid_params` and
`field: repository` a create gets. The other choice, starting the new session with no
repository, would be a sibling or a fork that runs without the code it was made to work
on and says nothing about it.

**Unchanged.** A parent with no repository passes none. A private session's import has
none, since a private session runs on a person's machine and is never cloned onto a pod.

**Proof.** `github_lineage_test.exs`, against the development OpenBao and the fake
GitHub: a sibling spawned from a session created with a repository, and a fork of a
sealed session that has one, each keep it on their row and receive it in their
activation.
