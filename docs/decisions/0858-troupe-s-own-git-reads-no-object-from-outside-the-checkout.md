---
number: 858
title: Troupe's own git does not run in a repository whose objects lead out of its checkout, through an alternates entry or a link in .git/objects
date: 2026-10-11
status: accepted
issue: 538
supersedes: [833]
paths:
  - apps/troupe_core/lib/troupe/git.ex
  - apps/troupe_core/test/troupe/git_test.exs
symbols:
  - Troupe.Git.run/3
gist: "Troupe.Git refuses a repository whose alternates (followed in turn) or links in .git/objects really lead outside the checkout"
---

Decision 833 pinned the git Troupe runs for itself (`git_read`, the brief, the worktree
check, the gateway's worktrees) to the checkout's own `.git`, and left one way out of it
standing: git reads an object wherever the object directory leads. An entry in
`.git/objects/info/alternates`, or a link in `.git/objects` (the directory itself, a
fan-out directory, a pack), let `git_read`, which runs without asking, show another
repository's commits and files as the workspace's own, and an ambiguous short hash's error
list them (#538). On a pod the session's sandbox binds only the workspace (#535); on a
local daemon nothing did. This replaces the first bullet of 833's "Not covered"; the rest
of 833 stands.

**The rule.** After the repository is located and held to the checkout (833),
`Troupe.Git.run/3` follows its object directory the way git does and runs nothing if any
of these really (real paths, links followed) leads outside the checkout, the main checkout
for a worktree, whose objects legitimately live there:

- the object directory itself;
- a link among its entries, in `pack/`, in `info/` and in `info/commit-graphs/`;
- an `info/alternates` entry, read as git reads it (one a line, relative to the object
  directory, `#` a comment, a `"` line unquoted as git unquotes it), and in turn each
  alternate's own object directory, by the same three rules.

`git_read` answers "git was not run: this repository's objects lead to <path>, which is
outside the checkout ...", the brief takes the workspace for no repository, as for 833's
other refusals, and the gateway makes no worktree there.

**Refuse, not read with alternates off.** The issue allowed either. git has no setting
that turns alternates off: `GIT_ALTERNATE_OBJECT_DIRECTORIES` only adds (and is one of the
`GIT_*` variables 833 already takes away from the daemon's environment), and
`GIT_OBJECT_DIRECTORY` still reads that directory's `info/alternates`. Reading with links
off would mean copying the object directory. Refusing with a sentence says what is wrong,
and the person can repair the repository (`git repack -a -d` and deleting the alternates
file makes it self-contained).

**What it costs.** A clone made with `git clone --shared` or `--reference` to a repository
outside the checkout is refused too: it is exactly the case. An alternate inside the
checkout (a vendored repository's objects) is the checkout's own and is read. The check is
a listing of the object directory, `pack/` and `info/` and one `readlink` an entry, so a
few hundred calls at most, on every `Troupe.Git.run/3`.

**Not covered.**

- A loose object's own file is not looked at: there may be thousands, and a link to one
  shows only an object whose name the link's maker already knew. A hard link is the file
  itself and cannot be told from one; making one needs the target to be reachable already.
- Links elsewhere in `.git` (`refs/`, `packed-refs`, `shallow`) can show another
  repository's ref names and hashes, but not its objects.
- A link changed between the check and the command: the same window 833 accepts for the
  `.git` it pins.

**Proof.** `Troupe.GitTest`, "objects reached through alternates or a link out of the
checkout are not read": for an absolute, a relative and a quoted alternates entry, an
alternate inside the checkout whose own alternates lead out, the object directory as a
link, a fan-out directory as a link and a pack and its index as links, plain `git
cat-file` in the workspace shows the other checkout's commit, and `git_read`'s `show` and
`log` of that commit are refused with the sentence and do not show it. On the chunk's tip
`git_read` read the other checkout's commit through each of them probed, all but the quoted
entry, which was added after (through the fan-out link, `log` did; `show` failed for want of
the commit's tree). On Windows the installed build refuses an alternates entry, the object
directory as a junction and a fan-out directory as a junction, which the build before it read. An alternate inside
the checkout is still read.
