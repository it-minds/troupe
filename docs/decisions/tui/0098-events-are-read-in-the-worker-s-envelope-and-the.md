---
number: 98
title: Events are read in the worker's envelope and the worker's vocabulary
date: 2026-09-19
status: accepted
paths:
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/lib/troupe/remote/worker.ex
  - clients/tui/lib/troupe/ui/headless/printer.ex
  - clients/tui/test/troupe/remote_translate_test.exs
gist: Events are read in the worker's envelope and the worker's vocabulary
---

With login, listing, attach and input finally working against the live plane, the stream stayed empty: every `event` notification the worker sent was dropped on the floor. Two reasons, both the fake's. The worker wraps a notification — `{"topic", "session_id", "event": {…}}`, with an ephemeral carried the same way and marked `"ephemeral": true` inside — where the fake put the event at the top level and sent ephemerals as their own `ephemeral` method; and the worker's types are the protocol's (`user_input`, `llm_response`, `tool_call_started`, `agent_done`, `llm_delta` with a `kind`, an `agent` that is a *list* from the root) where the fake's were dotted (`message.completed`, `tool.started`) with an `agent` string. `Troupe.Remote.Worker` unwraps the envelope and routes on the flag; `Troupe.Remote.Translate` reads both spellings onto the same local events, joins a path list as `root/explore#1`, takes `command_id` from `data` where the worker puts it, and builds an `assistant_message` from `llm_response.message.content` — text and tool-use blocks — rather than from a `text` field that is not there. The fake now sends the worker's envelope for everything, so the transport half is proven by every remote test; the vocabulary half has its own pure test, `remote_translate_test.exs`, in the exact shapes PROTOCOL.md §4 gives. The fixtures keep their dotted names on purpose: they are the contract's example, and reading both is cheaper than rewriting eleven tests to say the same thing.
