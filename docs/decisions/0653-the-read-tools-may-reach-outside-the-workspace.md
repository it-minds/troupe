---
number: 653
title: The read tools may reach outside the workspace where the config says, and only the read tools
date: 2026-09-20
status: accepted
paths:
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/workspace.ex
  - apps/troupe_core/test/troupe/read_roots_test.exs
gist: The read tools may reach outside the workspace where the config says, and only the read tools
---

`read_roots` are directories a `read_file`, `list_files`, `grep`
or `glob` may resolve into although they are outside the workspace — a dependency
checkout, the main repository a worktree's `deps` symlink points at. Without them a
quarter of all read-only shell calls were the model routing around a refusal with
`cd deps/x && sed -n`. `Troupe.Workspace.resolve_readable/3` is `resolve/3` first,
and on `outside_workspace` the path's real location — symlinks followed, both sides
— checked against each root. Writes go through `resolve/3` and never widen, which
is the whole of the safety argument: a read root cannot make a file writable, only
visible. It is a config key (`read_roots`, a list of directories, expanded), so a
pod whose bundle never sets it has none, and the mounts a pod has are untouched by
it.
