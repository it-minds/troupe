---
number: 895
title: "An agent revises a scratchpad document in place with `patch`, which replaces an exact span of it or adds to its end and is offered wherever `show` is, on every call; a document too long for one reply goes in parts, `show` its start and `patch` the rest on; a compaction leaves a long patch out for a pointer as it does a shown document; the live session that measures it runs under a window four times its first prompt; and, since that session cost more with the scratchpad, an agent uses it only when the person asks for a document or the answer would run past about 80 lines, and answers in the reply otherwise"
date: 2026-10-13
status: accepted
issue: 616
supersedes: [870]
paths:
  - apps/troupe_core/lib/troupe/tools/patch.ex
  - apps/troupe_core/lib/troupe/tools/show.ex
  - apps/troupe_core/lib/troupe/scratch.ex
symbols:
  - Troupe.Tools.Patch
  - Troupe.Scratch.patch/4
  - Troupe.Scratch.revise/3
  - Troupe.Tools.Show.left_out/1
gist: "show only for a document asked for or past ~80 lines, else reply; patch revises in place; both on every call; long docs in parts; long patches pointed"
---

**What changed.**

- **`patch`.** `name`, `new_string` and an optional `old_string`. With `old_string`, which
  must appear in the document exactly once, that span is replaced; with none, `new_string`
  is added to the end, on a line of its own when neither side has the newline. The rule is
  `edit_file`'s, the one models already know, and like it a span that is not there, or is
  there twice, is refused in a sentence that says what to do (read the document back with
  `read_file`; give more of the text around it). Each revision is the document's next
  version, a `scratch_updated` like a `show`'s, under the same lock, with the document's
  title and kind kept and the `patch` call as its `call_id`, so a client's listing and
  panel show the whole document revised and the terminal UI puts its card where the call
  was. The size cap is `show`'s. A name the session has not shown is refused: `patch`
  revises, it never creates.
- **Offered wherever `show` is, on every call.** A built-in, gated by nothing, in the
  `plan` agent's list beside `show`, and `:auto`, since it writes only the session's own
  scratchpad. The tools are the front of every prompt, so a tool that came and went would
  change it (Decisions 867 and 870).
- **A long document goes in parts.** Not a larger output budget for such a call: which
  call will carry a long document is not known before the model writes it, and raising the
  default `max_tokens` for every call is a change to every session's worst case, not this
  issue's. A `show` or `patch` call the output cap cut mid-argument (Decision 659 answers
  it rather than running it) is now answered with how: show the start, then add the rest
  with `patch` and no `old_string`, one part a call. Each part is a reply of its own, so no
  part meets the cap, and the scratchpad holds the whole document. `patch`'s description
  says an append is how a long document goes in parts.
- **A compaction and a patch.** A `patch` call whose `old_string` and `new_string` are
  longer than its pointer is left out as a `show` call's words are: `new_string` becomes
  the pointer (name, version, size and the calls that read and revise it; a patch names no
  title) and `old_string` `[left out since a compaction]`. A shorter patch stays as it was,
  since its pointer would be the longer of the two. From the call's own arguments and
  result alone, so the pointer comes out the same however many compactions keep it, and
  with 878's other rules unchanged: only at a compaction, not a call the model has not
  replied after, not a refused one.

**The issue's measure is not met.** The session with the scratchpad cost 51% and 33% more
over the run, and 81% and 27% more from its first compaction.

**When an agent uses the scratchpad.** Decided by the maintainer on 2026-10-13, from these
runs, and the issue closes with it: the scratchpad is not the default place for an
answer. An agent puts output there only when the person asks for a document (a plan,
report, table or diagram they want to keep or revise) or when the answer would run past
about 80 lines; every other answer goes in the reply, as before the scratchpad. A
document already there is revised with `patch`. This replaces 870's "a plan, report,
comparison, diagram or table they will read goes to `show`", which sent every plan there
whatever its length or whether anyone asked: in the runs above a session that did so cost
51% and 33% more over the run, and 81% and 27% more from its first compaction, because a
document costs a call of its own, a reply after it and a read back after each
compaction, and patches did not make a broad revision cheaper than writing it again.

- **The words.** `build.md`: answer in the reply unless they ask for a document or the
  answer would run past about 80 lines, then `show`, a short reply naming it, and `patch`
  to revise it. `plan.md` says the same of a plan. `show`'s description says it in one
  sentence ("only when they ask for one ... or the answer would run past about 80 lines;
  otherwise answer in the reply"). At 80 lines, the threshold the maintainer named, the
  live session's plans (146 to 163 lines) are past it and its checklists (51 to 54
  lines) are not, unless the person asks for one to keep. `patch`'s description is
  unchanged.
- **The tools stay on every call.** `show` and `patch` are still offered on every call of
  every agent that has them; only the words say when, since a tool that came and went
  would change the front of every prompt.
