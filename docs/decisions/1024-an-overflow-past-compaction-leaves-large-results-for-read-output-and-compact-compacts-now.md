---
number: 1024
title: "A prompt the provider refuses as too long even compacted is sent once more with every large tool result left for `read_output`, the turn's own included, and `/compact` (`session.compact`) compacts between turns"
date: 2026-11-17
status: accepted
issue: 1006
supersedes: [659, 771]
paths:
  - apps/troupe_core/lib/troupe/tools/output.ex
  - apps/troupe_core/lib/troupe/tools/read_output.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/commands.ex
symbols:
  - Troupe.Agent.Server.compact/2
  - Troupe.compact/3
  - Troupe.Tools.Output.stub_behind/3
  - Troupe.Tools.Output.stubs_any?/1
  - Troupe.Tools.ReadOutput.unread_stub/3
gist: "Overflow: compact once; if the resend overflows, send once more with every result >16 KiB as a read_output stub (llm_request behind); then fail saying fetch less. /compact: session.compact, control"
---

**The recovery.** On an overflow the agent compacts once, as before. If the compacted
resend overflows again, or the conversation is too short to compact at all, it sends the
turn once more with the boundary of what is behind (771) moved to the end of the
conversation. Every tool result over the stub size, 16 KiB, is then sent as the one-line
stub `read_output` expands, the turn's own included. A result the model has not read yet
gets a stub of its own wording (`left out: the prompt was too long for the model's
context window with it whole`). This reuses `Output.stub_behind/3` and its floor rather
than adding a second mechanism. Only if that also overflows, or there is nothing left to
leave out (no result over the size, or no `read_output` offered), does the turn fail.

**Why a second step and not at the first overflow.** Leaving the turn's results out at
the first overflow, next to the compaction, would have cost one refused request less.
But 771 keeps a result the model has not answered whole until a later compaction, and
the common overflow is one a compaction alone makes room for: the conversation was long
and the new results fit once the head is summarised. Stubbing them then would make the
model call `read_output`, a page at a time, and each call sends the whole prompt again.
The second step costs no model call, only one more refused request, and it runs only
when the compaction was not enough. It also covers a conversation too short to compact,
which used to fail outright: a fresh session whose first turn fetches too much.

**What 771 still holds, and what changes.** A compaction's boundary is unchanged, up to
the model's last reply in what it kept. Only the second step moves it to the end, and it
stays there until the next compaction, so the results the model read as stubs are not
sent whole on the next call. The conversation, the snapshot and the log keep every result
whole, as before. The request the second step sends writes `behind` (the new boundary)
on its `llm_request`, and a replay folds it, so a restarted agent sends the same stubs.
The guards themselves are not replayed (659), and both go when the turn fails, so the
next turn gets the whole recovery again.

**The failure says what to do.** When what does not fit is the turn's own tool results
(the conversation ends with them): `... — this turn's own tool results do not fit the
model's context window, even after compacting; fetch less per call (fewer records, a
narrower query), or start a new session`. Otherwise: `... — the latest message does not
fit the model's context window, even after compacting; send less at once, or start a
new session`. "Lower compact_at" goes: it was never the remedy for a turn that outgrows
the window by itself. "Too few messages to compact; start a new session" stays for a
short conversation with nothing to leave out.

**`/compact`.** A built-in in the `session` section, available everywhere. A person can
use it to make room before a heavy turn. Clients run it as `session.compact {command_id,
session_id}`, scope `control` (it changes what the agent goes on with and costs a model
call, as input does). It is activating, like the goal, and counts as work for Local only.
The root agent compacts at once if it is `idle`: `compacted` with `reason: "manual"`, the
`command_id`, and the actor, then `turn_ended` as it rests. It is refused `conflict` with
a sentence in any other state ("the agent is in the middle of a turn: compact once it has
finished, or cancel it first"), and when the conversation is no longer than what a
compaction keeps ("there is too little to compact yet: ..."). A manual summary that fails
writes an `llm_error` without a note ("the compaction failed: ...; the conversation is
as it was"), because the person is waiting to hear. A threshold compaction's failure
stays silent, as before. A pod's session token may call it: the worker's auth lists it
with the session's other methods. It is not on the relay's table: a steered session's
remote viewers do not get it, any more than they get the goal.
