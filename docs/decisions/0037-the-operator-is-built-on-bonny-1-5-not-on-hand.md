---
number: 37
title: The operator is built on Bonny 1.5, not on hand-written watch-and-reconcile GenServers
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_operator/mix.exs
gist: The operator is built on Bonny 1.5, not on hand-written watch-and-reconcile GenServers
---

It and `k8s` 2.8 compile and run on Elixir 1.20 / OTP 28, and it
supplies the parts that are the same in every operator and easy to get subtly wrong:
a watch that resumes from the right resource version, a periodic resync, leader
election through a Kubernetes `Lease`.
