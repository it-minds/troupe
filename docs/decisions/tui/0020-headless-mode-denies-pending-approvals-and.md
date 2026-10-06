---
number: 20
title: Headless mode denies pending approvals and answers `ask_user` with "proceed with your best judgement"
date: 2026-09-11
status: accepted
paths:
  - clients/tui/lib/troupe/ui/headless/printer.ex
gist: Headless mode denies pending approvals and answers `ask_user` with "proceed with your best judgement"
---

There is no user in CI; the denial is printed so the run is explainable, and `--auto-approve` is the documented way to allow writes and shell.
