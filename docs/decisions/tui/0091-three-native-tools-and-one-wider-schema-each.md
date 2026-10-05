---
number: 91
title: Three native tools and one wider schema, each aimed at a measured share of read-only shell, plus the prompt line that tells the model they exist
date: 2026-09-17
status: accepted
paths:
  - clients/tui
gist: Three native tools and one wider schema, each aimed at a measured share of read-only shell, plus the prompt line that tells the model they exist
---

From the same audit: git reads were 20% of read-only shell (`diff` 42, `log` 35, `status` 32, `show` 32) with no native tool at all — `git_read` covers exactly the subcommands that cannot mutate, with `op` as an enum and `ref`/`path` refused if they start with `-`, so an argument list stays an argument list. 43% of read-only shell calls chained three or more commands, most of them `cat a b c` with `echo "====="` between, which is a schema problem and not a missing tool: `read_file` now takes `paths` and prints the same headers itself, reporting a file it could not read in place rather than failing the call. `glob` answers "where is the file called X" — what `find` was doing inside those chains — sorted by mtime rather than by path, which is what `list_files` already does. And the guidance: Codex CLI, which started shell-only and converged on this same set, ships an explicit "prefer `read_file` over `cat`" instruction, and we had none — the system prompt now names which tool to reach for and says what `shell` is still *for* (building, testing, running, anything that mutates), at a cached prompt position where it costs nothing per turn. What stays in `shell` is deliberate and is ~41% of its traffic: builds, test runs, `curl`/`psql`/`docker`, heredoc writes, `rm`/`mv`/`cp` and every git mutation.
