---
number: 90
title: Reads may leave the workspace; writes never may
date: 2026-09-17
status: accepted
paths:
  - clients/tui
gist: Reads may leave the workspace; writes never may
---

An audit of 84 real sessions (3 211 tool calls) found `shell` at 27% of all calls and **58% of those shell calls purely read-only** — and a quarter of *those* were the model routing around a refusal rather than ignoring the native tools: `cd deps/ex_ratatui && sed -n 100,260p lib/ex_ratatui/app.ex`, `cat /tmp/checkout/lib/x.ex`, `find node_modules/... | xargs grep -l`. `Workspace.resolve/3` confines every path to the root, so the read tools *could not* reach a dependency and the model did the only thing left. No new tool fixes that, so the confinement itself is split: `resolve_readable/4` admits `config.read_roots` as well as the workspace and is used by `read_file`, `grep`, `list_files` and `glob`; `resolve/3` is untouched and still backs `write_file` and `edit_file`, which is asserted by tests rather than left as a convention. It compares the canonicalized path against each root, so a worktree that symlinks `deps` to the main checkout resolves through this instead of being rejected, and a symlink pointing somewhere unlisted still is. The refusal now names the roots it tried, because a refusal the model cannot act on is a refusal it answers with `shell`.
