---
number: 174
title: "A replayed or late-attached session draws a reply's reasoning frame from the reasoning blocks its logged llm_response carries, with no time to say; what streamed live still wins"
date: 2026-11-15
status: accepted
issue: 659
supersedes: [161]
paths:
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/lib/troupe/client/message.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/test/troupe/frames_test.exs
  - clients/tui/test/troupe/remote_translate_test.exs
symbols:
  - Troupe.Client.Message.reasoning/1
  - Troupe.Client.Message.reasoning_block/1
gist: "Replay draws reasoning from the logged reply's reasoning blocks (no duration); streamed reasoning still wins; redacted or empty blocks dropped"
---

Issue #659, the terminal's half of reasoning on replay; the desktop app's is root Decision
999. TUI Decision 161 kept reasoning live only (after Decision 36): a log replayed had no
deltas, so a session opened afterwards, or attached to mid-turn, drew no reasoning frame.
This supersedes that sentence of 161.

The log has it. Root Decision 658 keeps a reply's reasoning as a block of its own in
`llm_response.message`, and `Translate` dropped every block but text. It now keeps a
reasoning block as `%{type: :reasoning, text: …}`, in either spelling (`reasoning`,
`thinking`), and leaves out a redacted one, which has no words, and an empty one.
`Message.text/1` and `tool_uses/1` never see it, so the answer and the headless printer do
not fill with thinking. When an `assistant_message` folds and nothing streamed for that
agent, the reasoning frame is drawn from those blocks; the frame's header is `thinking`
alone, since the log says when the reply landed and not when the thinking began. When it
did stream, the streamed text is kept, with its duration, as before.

**Proof.** `test/troupe/frames_test.exs`: a replayed turn whose reply carries reasoning
draws `▾ thinking` and its text at `everything` and its header alone at `tools`; the live
turn still says `thinking · 12s`. `test/troupe/remote_translate_test.exs`: an
`llm_response` keeps its reasoning block and drops a redacted and an empty one. Both
failed on the branch's base.
