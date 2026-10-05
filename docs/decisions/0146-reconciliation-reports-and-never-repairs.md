---
number: 146
title: Reconciliation reports and never repairs
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_operator
gist: Reconciliation reports and never repairs
---

A job that silently rewrote the ledger
to match the gateway would destroy the evidence that they disagreed, and which of
them is right is a question about the incident rather than about the numbers. Drift
is reported in three directions — missing, extra, mismatched — because "the gateway
billed something we never recorded" and "we recorded something the gateway never
billed" are different incidents with different causes.
