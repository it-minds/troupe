---
number: 134
title: A headless run prints the harness's notes, and a turn a crashing agent ended is a failure, in the window and in a headless run
date: 2026-10-01
status: accepted
paths:
  - clients/tui/test/troupe/remote_translate_test.exs
  - clients/tui/test/troupe/window_attention_test.exs
gist: A headless run prints the harness's notes, and a turn a crashing agent ended is a failure, in the window and in a headless run
---

Defect D42; amends 129 and 132, and
takes up what root Decision 727 left to the clients.
- **The notes.** Since Decision 100 the harness's own word reaches a client as a
  `remote_note`: a finish's `done:` and its summary, `context compacted`, a reply cut
  at the output cap or empty and the note the model was given about it, the budget,
  the session going dormant. The printer had no clause for one, so a headless run
  said none of it. It prints each as the window shows it, one `agent> text` line.
  `agent_done`'s note comes before its state now: the run ends at the state, and
  `troupe run` stops listening there. `instructions_loaded`, a documented event the
  translation did not know, was drawn as a generic line at every turn whose files
  changed; it is `/context`'s to show, and the translation drops it.
- **`agent_failed`.** A root that crashes as often as its Node restarts it ends its
  turn with `turn_ended`, `reason: agent_failed` and `detail`, the first line of what
  it raised, and its session stops (727). The translation dropped the detail, the
  window counted the rest as done, and a headless run exited 0. The window is
  `failed_unread` now and says `the agent kept crashing, and its session stopped:
  <detail>` once in its transcript and as its failure; a headless run ends `1` with
  the same words as its last line. `1` is already "stopped short", which is what
  happened, and a code of its own would tell a script nothing it could act on
  differently. A line queued while the agent worked is not waited for: the session
  has stopped.
- **Dead readers (D36).** The printer's `truncated` and `compaction_started`, and the
  model's `truncated`, `compaction`, `compaction_started`, `profile_switched` and
  `watch_trigger`, which nothing has sent since the daemon move, are gone; the notes
  say what they said.
- **Proof:** `cli_test.exs` (a finish's summary printed before the run ends, a cut
  reply and the harness's note, an empty reply, a compaction, the budget's `done`,
  and a root crashed on the daemon this VM embeds, ending 1 with what it raised),
  `window_attention_test.exs` and `remote_translate_test.exs`, all failing on the
  chunk's tip, and the installed build, on the pull request.
