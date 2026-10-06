---
number: 652
title: Three read-only tools, in the core's shape
date: 2026-09-20
status: accepted
paths:
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/test/troupe/tools/read_tools_test.exs
gist: Three read-only tools, in the core's shape
---

`glob` (files by name, newest first
— what `find` was being used for), `git_read` (status, diff, log, show, branch,
with `ref` and `path` refused when they start with `-`) and `web_fetch` (GET, HTML
reduced to text, `:ask` because it is egress and a pod's policy may deny it). Each
resolves paths through `Troupe.Workspace`, runs processes through the reaper, and
caps output through `Troupe.Tools.Output` with the full text kept for `read_output`
(Decision 650) — so they gain the mounts, the sandbox and the kept output the core
has without a line written for the purpose. The built-in profiles list what suits
them: the read-only ones get `glob` and `git_read`, the planner and the
orchestrator `web_fetch` and `ask_user`, `build` and `general` everything.
