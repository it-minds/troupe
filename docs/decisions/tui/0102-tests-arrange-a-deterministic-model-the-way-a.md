---
number: 102
title: Tests arrange a deterministic model the way a machine arranges anything
date: 2026-09-20
status: accepted
paths:
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
gist: Tests arrange a deterministic model the way a machine arranges anything
---

A client cannot choose the daemon's provider (`Gateway.Dispatch` refuses it, rightly), so `start_session!/1` writes `provider: fake`, `fake_script:` and `auto_approve:` into the workspace's own `.troupe/config.yaml` and the daemon reads them at `session.create`; per-agent routes in the JSON script are troupe-remote Decision 644. Every test in this suite isolates the machine first: `test_helper.exs` points `TROUPE_STATE_HOME`, `TROUPE_CONFIG_HOME`, `XDG_RUNTIME_DIR` and `LOCALAPPDATA` at a scratch directory, so the embedded daemon's `daemon.json` and session logs never touch the developer's. The old fake read a text-only step as an implicit finish; the daemon's model ends the turn on one and waits, so the helper merges a text step with the `finish` that follows it, and a test that wants a reply and a tool in one turn spells `{:text_and_tools, text, calls}`.
