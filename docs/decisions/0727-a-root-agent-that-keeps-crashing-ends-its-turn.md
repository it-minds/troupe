---
number: 727
title: A root agent that keeps crashing ends its turn saying why, and its session stops instead of starting it again
date: 2026-09-29
status: accepted
paths:
  - ARCHITECTURE.md
  - PROTOCOL.md
  - apps/troupe_a2a/lib/troupe/a2a/events.ex
  - apps/troupe_a2a/test/troupe/a2a/stream_test.exs
  - apps/troupe_core/lib/troupe/agent/node.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/session.ex
  - apps/troupe_core/lib/troupe/session/log.ex
  - apps/troupe_core/lib/troupe/sessions/index.ex
  - apps/troupe_core/test/troupe/agent/crash_loop_test.exs
  - apps/troupe_gateway/test/troupe/gateway/daemon_test.exs
  - apps/troupe_plane/lib/troupe/plane/web/live/status.ex
  - apps/troupe_plane/test/troupe/plane/triggers_test.exs
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_worker/lib/troupe/worker/session/manager.ex
  - apps/troupe_worker/test/troupe/worker/stopped_turn_test.exs
  - clients/gui/apps/desktop/src/notify.ts
  - clients/gui/apps/desktop/src/views/Session.tsx
  - clients/gui/apps/desktop/src/views/bits.tsx
  - clients/gui/apps/desktop/test/failed-turn.test.tsx
  - clients/gui/packages/client/src/daemon.ts
  - clients/gui/packages/client/src/fleet.ts
  - clients/gui/packages/client/src/transcript.ts
  - clients/gui/packages/client/test/fleet.test.ts
  - clients/gui/packages/client/test/support/daemon.ts
  - clients/gui/packages/client/test/transcript.test.ts
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/lib/troupe/ui/headless/printer.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/test/troupe/cli_test.exs
  - clients/tui/test/troupe/remote_translate_test.exs
  - clients/tui/test/troupe/window_attention_test.exs
  - docs/developer/architecture.md
gist: A root agent that keeps crashing ends its turn saying why, and its session stops instead of starting it again
---

D37. A root whose start failed every time, or that
crashed every time on the turn it came back to (a reaper that could not spawn, under
the `git` call `Instructions.load` makes), was restarted by its `Agent.Node` three
times in five seconds, and then the session's `rest_for_one` started the Node again,
three times more: fifteen `agent_restarted` in a fraction of a second, then the
session gone, nothing in its log saying why, and every client still showing the turn
at work.
- **The session does not multiply the Node's restarts.** The root Node is a
  `significant`, `transient` child, and the session shuts itself down when it exits
  (`auto_shutdown: :any_significant`). When the Node gives up the session stops and
  comes back dormant from its log, as `Troupe.Sessions` always said it would. A
  Node that is killed is still started again.
- **The root says why before it goes.** `Session.Log` counts how often each agent
  has started again, for as long as the tree is up, as it already knew whether one
  had started at all; the agent reads from it whether this start is the last its Node
  allows. A start that fails then, or a crash in a state callback then, writes
  `turn_ended` with `reason: agent_failed` and `detail`, the first line of what was
  raised, and crashes as before. The count looks a second further back than the
  Node, which counts restarts in whole seconds: a word one start early, when the Node
  allows another after all, is better than none.
- **That turn is not taken up again.** A restart, and `resume_on_restart`, read it as
  a cancel, as they read a turn the failure guard stopped (687).
- A subagent is unchanged: its parent turns its Node's `:DOWN` into an error result.
  There is no backoff: a delay in a restart blocks the supervisor making it, and the
  Node's three quick tries are what it was built around.

The A2A facade fails the task with the detail. The TUI and the desktop app show
`agent_failed` as an ordinary rest until they learn the reason. Proof:
`crash_loop_test.exs` (a start that fails every time; one that crashes on the turn it
takes up, which wrote 15 `agent_restarted` before this and 3 now; a session brought
back with `resume_on_restart` that does not take the turn up) and the A2A app's
`events_test.exs`.
