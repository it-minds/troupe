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

Issue #1006. A pod session on a model with a 262,144-token window failed a turn that had
fetched hundreds of records per MCP call with "already compacted once this turn; lower
compact_at or start a new session". The overflow compacted once and sent the turn again
(659), but a compaction keeps the last six messages whole, with each call and its result
together (774), and the turn's own calls and large results were in those six. They did
not fit on their own, so the resend overflowed too and the turn failed. Lowering
`compact_at` would not have helped: the threshold is checked before a call, and the
results came in after it.

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

**Not here.** A `read_output` page is 200 lines, so a result that is one very long line
(a JSON array on one line) comes back whole and may overflow again. Paging by bytes is
for another change.

**Proof.** `OverflowRecoveryTest`, using a fake model that refuses any request whose
messages are over a byte window (`window_bytes`), which takes no step from the script:
- A turn reading two 28 KB files past a 40 KB window is refused whole, compacted, refused
  again, then taken with both results as unread stubs. Its `llm_request` carries
  `behind`, and the next turn still stubs them. On the chunk's tip this failed with
  "already compacted once this turn".
- The same turn too short to compact is taken with stubs and no summary, and a restart
  sends the same request prefix.
- Refusals past the stubs fail with the tool-results sentence and no `compact_at`.
- Five results under 16 KiB that do not fit together fail with the same sentence.
- `Troupe.compact/3` writes a manual `compacted` with its `command_id`, and is refused
  `:too_little` and `:busy`.

`DaemonTest` covers `session.compact` over the socket, both refusals included.
`AuthTest` lets a session token call it. The desktop and the terminal client each have
tests of `/compact`.
