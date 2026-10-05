---
number: 782
title: The desktop app and a headless run say what a turn cost, in the terminal UI's line, and `@troupe/client` writes the line
date: 2026-10-05
status: accepted
issue: 389
paths:
  - apps/troupe_core/lib/troupe/agent/headroom.ex
  - clients/gui/apps/desktop/test/turn-cost.test.tsx
  - clients/gui/packages/client/test/turn-cost.test.ts
gist: The desktop app and a headless run say what a turn cost, in the terminal UI's line, and `@troupe/client` writes the line
---

Issue #389, the rest of slice 4; Decision 769,
TUI Decisions 139 and 144. The harness writes `turn` on the event that ends a turn and
the terminal UI draws one line under the turn from it, but the client library's fold
read neither `turn` nor a compaction's `usage`, so the desktop app said nothing of
what a turn cost, and `troupe run --headless` printed nothing of it either (D65).
- **One line, written once.** The fold makes a `turn` entry of the `turn` on
  `turn_ended`, `cancelled` and `agent_done`, after the event's own (`turn cancelled`,
  `done: …`), with its `text` from `turnLine/1` in the terminal UI's words: `turn: 3
  calls · ↑ 300 sent · 3.0k cached · ↓ 3 received · $0.04`, `no price` when no call
  was priced, `, 2 calls unpriced` when some were not. The desktop app draws the
  text as a note close under the turn, a subagent's with its path in front, and
  formats nothing itself, so any client of the library says the same. Nothing for a
  turn that made no call, a log from before turns were counted, or a root's turn
  that `agent_failed` ended, which carries no `turn`.
- **The same to the cent.** The terminal UI rounded floats, and a float at an exact
  half goes either way by how it is held: `$1.045` printed `$1.04` there and `$0.045`
  printed `$0.05`, which a copy in JavaScript could not be sure of matching. Past a
  million tokens Elixir printed the float as `1.0e3`, so the 9-million-token turn the
  issue is about read `9.0e3k sent`. Both clients now work the figures out in whole
  numbers, rounded half up, and a million is `M`, as `Troupe.Agent.Headroom` already
  wrote it: `6.0M sent`. The terminal UI's tile and side panel count the same way.
- **The summariser's call is the session's spend.** The fold adds a `compacted`'s
  `usage` and `gateway.cost_micros` to the session's `usage` (new) and `costMicros`,
  as the terminal UI's window adds them (139), so the desktop app's "Cost so far"
  has it. The desktop app shows no session token total and gets none here.
- **Headless.** One line per ended turn, prefixed with its agent like every other,
  after the reply and before `exit N:`, and once whether it was printed live or read
  back from the journal. It is on standard output with the rest of the transcript:
  the printer has no other stream and no `--json`, and a script that wants the
  figures as data reads them from the session's log.
- **Proof:** client `turn-cost.test.ts` (six of its first seven tests fail on the
  chunk's tip: no line from `turn_ended`, `cancelled` or `agent_done`, and the
  summariser's call missing from the session's cost), the figures at their halves and
  past a million; desktop `turn-cost.test.tsx`, the line under the turn and the cost so
  far with the summariser's call; TUI `cli_test.exs`, a run's line after its reply and
  each ended turn's in the window's words (both fail on the tip); and the installed
  `troupe run --headless` and the desktop app against a scratch daemon, on the pull
  request.
