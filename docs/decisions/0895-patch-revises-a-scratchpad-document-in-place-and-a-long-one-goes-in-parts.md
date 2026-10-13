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
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe/tool.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/priv/agents/build.md
  - apps/troupe_core/priv/agents/plan.md
  - apps/troupe_core/priv/bench/budgets.json
  - apps/troupe_core/lib/troupe/bench/live.ex
  - apps/troupe_core/lib/troupe/bench/live_scenarios.ex
  - apps/troupe_core/lib/troupe/bench/scenarios.ex
  - apps/troupe_core/test/troupe/tools/patch_test.exs
  - apps/troupe_core/test/troupe/tools/show_test.exs
  - apps/troupe_core/test/troupe/bench_test.exs
  - apps/troupe_core/test/troupe/agent/scratch_compaction_test.exs
  - apps/troupe_core/test/troupe/bench_live_test.exs
  - docs/user/README.md
  - docs/developer/bench.md
symbols:
  - Troupe.Tools.Patch
  - Troupe.Scratch.patch/4
  - Troupe.Scratch.revise/3
  - Troupe.Tools.Show.left_out/1
gist: "show only for a document asked for or past ~80 lines, else reply; patch revises in place; both on every call; long docs in parts; long patches pointed"
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

The tool, the parts and the words are in. The live measure is still not met; the numbers
and why are under **Live**, and what the maintainer decided from them under **When an
agent uses the scratchpad**.

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
prompt and tool definitions), where 878's was twice it. It was chosen from #648's logs:
without the scratchpad a compaction keeps the last six messages, two of which are whole
plans, so the prompt after it is about 15,000 to 18,000 tokens, and a threshold below that
compacts after every turn, as 878's did; a threshold much above 18,000 compacts no more
than once in eight turns on either side, and a session long enough to compact under a real
model's window, 200,000 tokens, costs several times what a $3 cap pays for three times
each. The expectation that the session with `patch` would grow slowly and compact late was
wrong (below).

**Live**, on the installed build, Claude Sonnet 5.5 ($2 in, $10 out, $0.20 a cache read,
$2.50 a cache write per million; the summaries on Claude Haiku 4.5), on Windows,
2026-10-13. Two runs each, $2.41 of the slot's $3: a run may cost up to $0.74, and a third
pair did not fit. Tokens are fresh / read from the cache / output.

| | with the scratchpad | without |
|---|---:|---:|
| runs whose checks held | 2 of 2 | 2 of 2 |
| the agent's model calls | 21, 26 | 10, 9 |
| compactions, after turns | 7 (2, 3, 5, 6, 6, 8, 8); 5 (2, 5, 6, 7, 8) | 2 (4, 6); 5 (3, 4, 6, 7, 8) |
| the whole run | $0.6574; $0.7557, its cap reached in the last turn | $0.4343; $0.5670 |
| its tokens | 123,630 / 225,821 / 38,825; 111,187 / 300,279 / 47,827 | 53,624 / 93,911 / 31,134; 96,833 / 68,208 / 39,305 |
| from the first compaction | $0.4789 (22 calls); $0.4938 (25) | $0.2641 (6); $0.3891 (10) |
| the seventh and eighth turns | $0.1338; $0.2719 | $0.1106; $0.1661 |

**The issue's measure is not met.** The session with the scratchpad cost 51% and 33% more
over the run, and 81% and 27% more from its first compaction.

- **It makes two to three times the calls, and so compacts more.** A revision is a `show`
  or `patch` call and a reply, and after a compaction the agent reads a document back
  (seven and six reads) before it patches it or answers about it. Every call's prompt
  counts against the threshold, so the session compacts in the middle of turns, and each
  compaction writes the prompt to the cache again and calls the summariser: the agent's
  cache writes were 97,420 and 84,804 tokens against 43,906 and 74,421, the summaries
  $0.07 and $0.05 against $0.03 and $0.07.
- **`patch` did not save output in this session.** The agent wrote 29,680 output tokens
  against 28,073 and 29,670; the second run's 43,635 holds two cut replies. Sonnet 5.5
  revised many places at once: thirteen patches in one turn took 6,169 output tokens,
  where the whole revised plan as a reply took 5,465 and 6,590. A narrow revision was
  cheap (six patches, 1,954 tokens, for the row-count step).
- **"Give the whole plan again" was a whole `show` again** in four revisions of eight,
  `build.md`'s sentence notwithstanding. Two were cut at 8,192 output tokens, $0.19 of the
  second run: after one the model went on in parts as the cut call's answer says (a show
  of 7,478 bytes, then a patch to 13,000), after the other it asked again whole and fit.
- **Agents still tried other tools on `scratch:` paths** in the second run: `grep` twice,
  each refused with the sentence naming `read_file` and `patch`, after which the model
  read the document back; and its last response asked for `edit_file` on one four times
  beside a `patch`, which the run's cap stopped before they ran.
- **The window is still small for this session.** Without the scratchpad the second run
  compacted after nearly every turn from the third on: its tail holds two whole plans.

What would meet it is not in this decision: a window where a compaction is rare against
the calls after it, which is where a pointer saves money and which needs a session several
times as long as this; and a revision that costs less output than the document, which
these runs did not get from `patch` when the person asks for the whole document again.
Run it again with `troupe bench --live --scenario
scratchpad_session,scratchpad_session_without --repeat 3 --model claude-sonnet-5-5`; a
run's `since_compaction` is the measure.

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
- **What it costs offline.** The `tool_calls` turn on `build`: the system prompt 1,693
  bytes against 1,598 with this file's first wording, the tool definitions 14,750 against
  14,688, the first prompt 16,575, the largest 32,072, and 189,708 of the stand-in's
  tokens; the budgets move to 1,750, 14,800, 16,650, 32,150 and 190,500. The turn also
  checks that the prompt and `show`'s description reached the model saying so, and that
  its short answer left the scratchpad empty: a scripted model cannot judge whether an
  answer is a document, so the words are what is checked.
- No live run measured the wording: the slot's cap was spent on the runs above.

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
1,650, 16,500, 32,050 and 189,500. And the installed daemon on scratch homes, against a
stand-in behind a proxy that logged each request: `patch` was offered on every agent call,
the call after a one-line patch was 549 bytes larger than the one before it where the plan
is 12,846, the plan's words went once in every request after it was shown, `edit_file` on
`scratch:/plan.md` was refused naming `patch(name: "plan.md", ...)`, and an appended part
left the scratchpad's plan at version 3, revised and whole.
