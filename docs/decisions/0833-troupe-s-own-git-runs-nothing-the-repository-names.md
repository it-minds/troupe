---
number: 833
title: Every git Troupe runs for itself in a workspace runs nothing the repository's own .git names and reads only the checkout's own repository, and the file tools never write under .git
date: 2026-10-10
status: accepted
issue: 529
paths:
  - apps/troupe_core/lib/troupe/git.ex
  - apps/troupe_core/lib/troupe/tools/git_read.ex
  - apps/troupe_core/lib/troupe/session/memory.ex
  - apps/troupe_core/lib/troupe/worktree.ex
  - apps/troupe_core/lib/troupe/workspace.ex
  - apps/troupe_core/lib/troupe/mounts.ex
  - apps/troupe_core/lib/troupe/onboard.ex
  - apps/troupe_gateway/lib/troupe/gateway/worktrees.ex
  - apps/troupe_core/test/troupe/git_test.exs
  - apps/troupe_gateway/test/troupe/gateway/worktrees_test.exs
symbols:
  - Troupe.Git.run/3
  - Troupe.Workspace.git_dir?/2
  - Troupe.Workspace.resolve/3
  - Troupe.Mounts.resolve/3
gist: "Troupe's own git goes through Troupe.Git: what .git names never runs, no GIT_* inherited, only the checkout's own .git; file tools never write .git"
---

Troupe runs `git` for its own purposes in a session's workspace, outside the sandbox: the
`git_read` tool, which runs without asking by default; the project brief's repository,
HEAD and file count, the first of them before every model call; the files a worktree's
checkout commits (Decision 826); and the gateway's worktrees (Decision 647). git honours
settings in the repository's own `.git`, and some of them run a command. A session's agent
can write that directory (through the file tools until now, through the shell still), so
it could have Troupe's own git run a command outside the sandbox: as the daemon, or on a
pod as the worker, beside the other sessions' workspaces. A `.git` naming another
checkout's repository as its common directory also let `git_read` read that checkout's
history (#529).

**One runner.** `Troupe.Git.run/3` is how Troupe runs git in a workspace: `git_read`,
`Troupe.Session.Memory`, `Troupe.Worktree` and `Troupe.Gateway.Worktrees` all call it. It
answers what `Troupe.Reaper.run/3` answers, so the callers keep their shape, and a reaper
that will not start is still an error, never a raise (Decision 733).

**What is neutralised, and why each.**

- `core.fsmonitor=false`. The fsmonitor hook runs in any command that reads the index:
  `status`, `diff`, `ls-files` (the brief's file count). This was the reproduction.
- `core.hooksPath` set to a path inside the reaper helper, which is a file, so no
  directory can be there and no hook runs. `status` can write the index and so run
  `post-index-change`; a ref update runs `reference-transaction`; the gateway's worktree
  runs `post-checkout`, its commit and merge `pre-commit`, `commit-msg`, `post-commit`,
  `pre-merge-commit` and `post-merge`. `/dev/null` is the usual value, but on Windows it
  means `\dev\null` on the current drive, where a directory of that name can be made.
- The repository's own filters, `filter.<name>.clean`, `smudge` and `process` from the
  `local` and `worktree` scopes of `git config --list --show-scope`, get an empty command,
  which git reads as none, and `required=false`. `status` and `diff` hash a changed file
  through its clean filter, and a checkout writes through its smudge filter. Filters in
  the person's own config and the machine's (git-lfs, typically) are theirs, and run. A
  command that reads only refs and objects (`rev-parse`, `ls-tree`, `log`, `show`,
  `branch`) applies no filter, so for those the config is not listed first.
- The repository's own merge drivers, `merge.<name>.driver`, become `false`. A file one of
  them would have merged is a conflict, and the gateway's merge is aborted as on any
  conflict (Decision 647), for the person to merge. An empty driver would run an empty
  command and silently keep one side.
- `--no-textconv` and `--no-ext-diff` on `diff`, `show` and `log`. A
  `diff.<name>.textconv`, `diff.<name>.command` or `diff.external` runs a command for each
  file a diff shows. The flags turn the person's own off too (a configured external diff,
  Git for Windows' `astextplain`): what a tool reads is the bytes.
- `--ignore-submodules=dirty` on `status` and `diff`. Looking inside a submodule runs git
  there, under the submodule's own config, which the runner has not read. A submodule now
  shows when its commit moves, not when its files change.
- `submodule.recurse=false`, `gc.auto=0` and `maintenance.auto=false`. No command recurses
  into a submodule, and the gateway's commit and merge leave no gc running after them.
- `commit.gpgSign=false`, `merge.verifySignatures=false` and `log.showSignature=false`.
  Signing and checking a signature run `gpg.program` or `gpg.ssh.program`, which the
  repository's config can name. The gateway's own commits are not signed.
- `safe.bareRepository=explicit`. A workspace laid out as a bare repository is not taken
  for one.
- `--no-pager`, and `GIT_EDITOR=:`, git's own word for no editor. `core.pager` and
  `core.editor` never start.
- No transport: `GIT_ALLOW_PROTOCOL=none` and `GIT_NO_LAZY_FETCH=1`, with
  `GIT_TERMINAL_PROMPT=0`. Nothing here fetches, but a partial clone fetches a missing
  object when a command needs it, through the remote the repository names, and so could
  start `core.sshCommand`, a credential helper, a remote's `uploadpack` or an `ext::`
  command.
- `GIT_OPTIONAL_LOCKS=0`. `status` does not write the index back, so a read stays a read.
- No `GIT_*` variable of the daemon's own. A `GIT_DIR`, `GIT_CONFIG_PARAMETERS` or
  `GIT_EXTERNAL_DIFF` in the environment the daemon was started from is taken away
  (`Troupe.Reaper` now takes away a variable given as `nil`).
- The settings travel as `GIT_CONFIG_PARAMETERS`, the way `git -c` passes its own to the
  commands it starts, so they hold in git's children too, with each name and value quoted
  as git quotes them. A filter named `a=b'c` is one that `-c filter.a=b'c.clean=` would cut
  short, and an empty value is one a port cannot set as a variable of its own
  (`GIT_CONFIG_VALUE_<n>`).

**Not set: `GIT_CONFIG_NOSYSTEM`.** It was considered and left out. The machine's file is
not the session's to write, so ignoring it guards nothing, and on Windows it is where Git for
Windows keeps `core.autocrlf=true` and the git-lfs filter: without them a CRLF checkout's
changed file reads as every line changed, and a large file as its pointer. The person's
global file is read for the same reason (`safe.directory` lives there too).

**Where git may read.** git finds the repository as it always has (`rev-parse
--is-inside-work-tree --show-toplevel --git-dir --git-common-dir`), and the command runs
only when

- the workspace is in git's working tree, so a `core.worktree` pointing elsewhere is not
  followed;
- the common directory is the `.git` of the checkout: git's top level, or the main
  checkout that a worktree's `.git` names and that names the worktree back
  (`Troupe.Config.Trust.root/1`, the check trust, `Troupe.Worktree.main/1` and
  Decision 831 make);
- the git directory is that `.git` itself or, for such a worktree, one of the checkout's
  `.git/worktrees/`.

Real paths throughout, so a `.git` that is a link out is not followed. A workspace in a
subdirectory of a checkout reads the checkout, as before, and a real worktree reads its
checkout's history. The command then runs with `GIT_DIR`, `GIT_COMMON_DIR` and
`GIT_WORK_TREE` set to what was checked, so a `.git` rewritten in between does not move
it. Anything else is not read: `git_read` answers "git was not run: ..." and names the
directory, the brief takes the workspace for no repository (its brief is then its own,
as Decision 831 has it, and stamped with no HEAD), and the gateway makes no worktree
there. A session opened in a submodule's own directory, whose git directory is in the
superproject's `.git/modules/`, is refused the same way.

**The file tools.** `Troupe.Workspace.resolve/3` and `Troupe.Mounts.resolve/3` refuse a
write to a path in a `.git` directory, or to a `.git` file, judged where the path really
is (`Troupe.Workspace.git_dir?/2`): so `write_file`, `edit_file`, `import`, an ACP agent's
`fs/write_text_file` and a client's `fs.upload` all refuse it, with a sentence saying why.
`.git` is matched in the spellings git itself refuses in a tree: any case, trailing dots
or spaces and a stream name (NTFS), the short name `git~1`, and the code points HFS+
ignores. `Troupe.Onboard.check_path/2` refuses such a path for `onboard_write` and `troupe
onboard`. The shell can still write there, which is why the runner does not rely on this.

**Not covered.**

- Objects reached through `objects/info/alternates`, or through a link inside `.git`
  (`objects`, a pack): git reads them where they point. On a pod, the way to close that
  and the rest of this class is to run Troupe's own git inside the session's sandbox,
  the issue's other option, not taken here.
- `git worktree remove` without `--force` checks the worktree itself, with
  `status --ignore-submodules=none`, so a submodule in a worktree being removed is looked
  inside under its own config.
- The cost: one or two more git processes for each call (where the repository is, and
  its config for a command that touches the working tree).

**Proof.** `Troupe.GitTest`: a repository whose `core.fsmonitor` names a marker-writing
script runs it through none of `git_read`'s `status` and `diff`, the brief's HEAD and file
count, and `Troupe.Worktree.committed/2`; a clean filter (one named `a=b'c` among them), a
process filter, the `post-index-change` and `reference-transaction` hooks, a textconv and
an external diff run through none of `git_read`'s ops; three forged `.git`s naming another
checkout's repository are not read by `git_read` and stamp no HEAD on the brief, while a
real worktree and a subdirectory of a checkout are read; `write_file` and `edit_file`
refuse `.git/config`, `.GIT/config`, a nested `.git` and a link to `.git`.
`Troupe.Gateway.WorktreesTest`: a worktree is made, its work committed and merged in a
repository with eight hooks, an fsmonitor, a filter and a merge driver set, and none of
them runs; the merge driver's file is a conflict. All of these failed on the chunk's tip.
