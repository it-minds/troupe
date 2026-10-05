---
number: 14
title: Watch-mode gitignore filtering uses `git ls-files --others --ignored --exclude-standard` (with `--cached` for the tracked set) rather than a hand-written matcher
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: Watch-mode gitignore filtering uses `git ls-files --others --ignored --exclude-standard` (with `--cached` for the tracked set) rather than a…
---

git is already required for worktrees; when the workspace is not a git repo nothing is ignored except `.git/` and `.troupe/worktrees/`.
