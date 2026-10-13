---
number: 895
title: "An agent revises a scratchpad document in place with `patch`, which replaces an exact span of it or adds to its end and is offered wherever `show` is, on every call; a document too long for one reply goes in parts, `show` its start and `patch` the rest on; a compaction leaves a long patch out for a pointer as it does a shown document; and the live session that measures it runs under a window four times its first prompt"
date: 2026-10-13
status: accepted
issue: 616
paths:
  - apps/troupe_core/lib/troupe/tools/patch.ex
  - apps/troupe_core/lib/troupe/tools/show.ex
  - apps/troupe_core/lib/troupe/scratch.ex
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe/tool.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/priv/agents/build.md
  - apps/troupe_core/priv/agents/plan.md
  - apps/troupe_core/priv/bench/budgets.json
  - apps/troupe_core/lib/troupe/bench/live.ex
  - apps/troupe_core/lib/troupe/bench/live_scenarios.ex
  - apps/troupe_core/test/troupe/tools/patch_test.exs
  - apps/troupe_core/test/troupe/agent/scratch_compaction_test.exs
  - apps/troupe_core/test/troupe/bench_live_test.exs
  - docs/user/README.md
  - docs/developer/bench.md
symbols:
  - Troupe.Tools.Patch
  - Troupe.Scratch.patch/4
  - Troupe.Scratch.revise/3
  - Troupe.Tools.Show.left_out/1
gist: "patch: one exact span or an append, every call beside show; long docs in parts; a compaction points a long patch; session bench window 24k"
---

Issue #616, the rest of it. Decision 878 made a compaction leave each shown document out
for a pointer and let `read_file` read it back, but the live measure was not met: on a
14,000-token window the session with the scratchpad compacted after nearly every call and
cost more than the session without it. #648's runs named what was left: a fair window, an
in-place edit, and a long `show` that the reply's output cap cut. In those runs agents
tried `edit_file` and `grep` on `scratch:/` paths (seven `edit_file` calls on the plan in
one turn, each refused), then read the whole plan back and showed it whole again; a revised
plan sent as `show` arguments was cut at 8,192 output tokens, where the same plan as a
chat reply took 5,635.

On the chunk's tip a revision could only be a `show` of the whole document again: the
eight cases of `Troupe.Tools.PatchTest` all failed there (no `patch` was offered, so the
revision was refused as an unknown tool, and the scratchpad stayed at version 1).

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
  revises, it never creates. Its result names the version and asks for a short reply once
  the document is done, as `show`'s does.
- **Offered wherever `show` is, on every call.** A built-in, gated by nothing, in the
  `plan` agent's list beside `show`, and `:auto`, since it writes only the session's own
  scratchpad. The tools are the front of every prompt, so a tool that came and went would
  change it (Decisions 867 and 870). Its definition is 487 bytes; `show`'s description
  grew by 27 to name it.
- **The words that point at it.** `build.md`'s sentence about `show` adds "Revise one with
  `patch`, not by showing it again", and `plan.md`'s says `patch` revises it. `show`'s
  result says to revise it later with `patch`. Another file tool given a `scratch:` path,
  `edit_file` as much as `grep`, now names both `read_file` and the `patch` call, not
  `edit_file`. A compaction's pointer and the summary's listing say a document is revised
  with `patch`, and the summariser is told a document revised with `patch` is a pointer
  too.
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
- **The bench reads a document as last written.** `scratchpad_session`'s checks read the
  plan as its `show` and every `patch` after it left it (`Scratch.revise/3`, the rule the
  scratchpad writes by), and a run's record has `since_compaction`: its calls, tokens and
  cost from its first compaction on, the summary's call included.

**The fair window.** `scratchpad_session` and `scratchpad_session_without` are eight turns
now: the plan, a revision, a checklist, a question, a step added, the checklist revised,
a question about the plan, and the rollback revised, each revision asking for the whole
plan or checklist again. The person reads it whole either way: in the reply without the
scratchpad, beside the chat with it. The window is 24,000 tokens at the default
`compact_at` of 0.75, four times the session's first prompt (about 6,500 tokens of system
prompt and tool definitions), where 878's was twice it. Two bounds set it. Without the
scratchpad a compaction keeps the last six messages, two of which are whole plans, so the
prompt after it is about 15,000 to 18,000 tokens: a threshold below that compacts after
every turn, as 878's did. With the scratchpad and `patch` the conversation grows by a
patch, not a plan, a revision, so it reaches 18,000 only late in the session: a threshold
much above that never compacts at all in a session one can afford to run three times
each. A real model's window, 200,000 tokens, would be the second case for a session
several times as long and as dear.

**Live.** _Filled in from the installed build's runs._

**Proof.** `Troupe.Tools.PatchTest`: offered on every call of `build` on two models and
of `plan`; a span replaced in place as version 2 with the title, kind and call kept; an
append on a line of its own; after a revision the request carries the plan's words once
and the patch's arguments are under a twentieth of the plan; each refusal (a name not
shown, a path, a span not there, a span there twice, past the cap) in its sentence, writing
nothing; a `show` cut at the output cap answered with the parts and `patch`, then shown in
two parts that make the whole document; `build`'s and `plan`'s prompts name `patch`;
`edit_file` and `grep` on `scratch:/plan.md` name `read_file` and `patch` and not
`edit_file`. `Troupe.Agent.ScratchCompactionTest`: a long patch in a compaction's tail has
the pointer and none of its words, a short one stays whole, and the document is as both
left it. `BenchLiveTest`: the pair's eight turns and window; the plan as a `show` and its
patches left it, a refused patch changing nothing; a run's `since_compaction` from its
summary's call on. The offline bench's `tool_calls` turn on `build`: tool definitions
14,688 bytes against 14,174, the system prompt 1,598 against 1,548, the first prompt
16,418 against 15,854, the largest 31,915 against 31,351, and 188,499 of the stand-in's
tokens over the thirty-one calls against 184,128 (2.4% more); the budgets move to 14,800,
1,650, 16,500, 32,050 and 189,500.
