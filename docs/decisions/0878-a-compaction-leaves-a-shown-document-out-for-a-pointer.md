---
number: 878
title: "A compaction leaves the words of each document `show` put on the scratchpad out of what it keeps, and out of what its summariser reads, for a pointer naming the document, its title, version and size and the `read_file` call that reads it back, and its summary lists every document on the scratchpad; `read_file` reads `scratch:/<name>`, read-only; nothing else changes the prefix"
date: 2026-10-12
status: accepted
issue: 616
supersedes: [870]
paths:
  - apps/troupe_core/lib/troupe/tools/show.ex
  - apps/troupe_core/lib/troupe/tools/read_file.ex
  - apps/troupe_core/lib/troupe/tool.ex
  - apps/troupe_core/lib/troupe/scratch.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/bench/live.ex
  - apps/troupe_core/lib/troupe/bench/live_scenarios.ex
  - apps/troupe_core/test/troupe/agent/scratch_compaction_test.exs
  - apps/troupe_core/test/troupe/bench_live_test.exs
  - docs/developer/prompt-prefix.md
  - docs/user/README.md
symbols:
  - Troupe.Tools.Show.left_out/1
  - Troupe.Tools.Show.pointer/1
  - Troupe.Tools.Show.listing/1
  - Troupe.Scratch.readable/2
gist: "only a compaction puts a pointer for a shown document's words, in its tail and summariser's read, and lists the pad; read_file reads scratch:/<name> read-only"
---

Issue #616, the token half of #472. Decision 870 made the scratchpad display only: a
`show` call stays in the conversation as it was written, so the prefix never changes in
the middle of a session (Decisions 863 and 867), and the document is sent to the model
again on every later call. On the live bench a turn that put its plan on the scratchpad
cost about 30% more than the same turn without it. 870 left the saving to a compaction,
the one point where the prefix changes anyway.

On the chunk's tip a compaction kept a `show` call in its tail with the whole document in
its arguments, its summariser read the whole document as the call written out, and the
agent had no way to read a document back: `read_file` refused `scratch:/plan.md` as a path
outside the workspace.

**What changed.**

- **The pointer.** What a compaction keeps has, in place of each shown document's words,
  one line: `[plan.md ("Migration plan", version 2, 10234 bytes) left out since a
  compaction; it stays on the scratchpad. Call read_file(path: "scratch:/plan.md") to read
  its latest version.]`. It replaces the call's `content` argument; its `name`, `title`
  and `kind` stay, so the call still reads as what it was. The name, size and version are
  read from the call's own result (`Showed scratch:/plan.md (10234 bytes, version 2) ...`,
  `Show.shown/1`), the call is found by its result in the message after it (an id is unique
  only within its response where a gateway numbers its calls), and the title from the
  call's arguments. From those alone, so a pointer comes out the same however many
  compactions keep it.
- **In the tail too, every version.** The tail a compaction keeps is the last few messages;
  a `show` call there has its words replaced like any other, and each version its own
  pointer. Not kept for the latest version of each document: what the model last showed
  is on the scratchpad, word for word, one call away, and a tail that kept it would keep
  the largest thing in it, the cost the issue is about. A version the model has replaced
  since says which version it was, and the read gives the latest.
- **But not a call the model has not replied after.** A compaction in the middle of a turn
  comes after a call whose result the model has not read yet. That call keeps its words
  until a later compaction, as 771 keeps such a result whole. In a live run of the build
  before this rule, the model, seeing its own last call changed before it had read the
  answer, showed the same plan again, then again after the next compaction, three times,
  until the run's output budget stopped it.
- **In what the summariser reads.** The stretch a compaction replaces reaches the
  summariser with the same pointers (Decision 779 writes the calls out as text), and the
  summariser's prompt says to keep a pointer's name and its `read_file` call. Unlike a
  large tool result, which the summariser reads whole because the summary has to carry
  what the agent learned from it (Decision 771), a document is something the agent wrote,
  kept whole on the scratchpad: a summary of it would be a second, lossy copy sent on
  every call after.
- **The summary lists the scratchpad.** The message a compaction puts in front of what it
  keeps ends, after the summary, with every document on the scratchpad, the latest version
  of each, and the `read_file` call that reads one (`Show.listing/1`, from
  `Scratch.list/1`). Without it a document whose call went into a summary was known only
  by what that summary said of it, and each later compaction summarises the summary
  before it: in the first live runs a session's fourth compaction wrote a summary of one
  sentence, the documents' names went with the rest, and the next turn looked for the plan
  in the workspace. Read from the log once, at the compaction, and logged with the
  conversation, so it changes nothing between compactions either. Nothing for an empty
  scratchpad, or where the agent has no `read_file`.
- **Only at a compaction.** `apply_compaction` puts the pointers into the conversation it
  keeps, and the `compacted` event logs that conversation, so a replay and a restarted
  agent rebuild the same one and send the same prefix. Between compactions nothing
  replaces anything: a `show` call made since the last compaction goes whole until the
  next, as 870 decided. Not chosen: replacing it in what is sent only, as 771 stubs a
  large result. That would rewrite, on the first call after an upgrade, a conversation a
  session compacted under the build before, which on a model that binds its thinking is a
  refusal for every block made since.
- **On a model that binds its thinking** the tail still goes without its thinking (867),
  and the pointers are in place before the first call after the compaction, so every block
  made from then on is bound to the conversation with them.
- **Reading one back.** `read_file` takes `scratch:/<name>` and reads that document from
  the session's scratchpad, read-only, against a table with the scratchpad alone
  (`Scratch.readable/2`). A name the scratchpad does not have, a path out of it and the
  directory itself are refused in one sentence that says how a document is named. This
  changes 870's "the file tools never see it" for this one read: the agent writes the
  scratchpad only with `show`, which logs every write, and no other file tool, no command
  and no sandbox reaches it. `read_file`'s description does not mention it, so the tools
  stay the same on every call (867); the pointer says how, where it is needed. Another file
  tool given a `scratch:` path, as `grep` was in a live run, is refused with a sentence
  naming the `read_file` call rather than "outside the workspace" (`Tool.describe/1`).
- **Where the agent has no `read_file`** its documents stay whole: a pointer it cannot
  follow is a document lost (771 keeps a result whole where `read_output` is not offered
  for the same reason). Every built-in agent with `show` has `read_file`.
- **A refused `show` call** is left as it was: there is nothing on the scratchpad to point
  at, and the result says why it was refused.

**The live scenario.** `scratchpad_session` and `scratchpad_session_without`, beside 870's
pair and run by name: the migration plan, then four more turns in the same session (revise
the plan, write a checklist for the night of the switch, say how long the copy step takes,
add a step and give the whole plan again), on `build` with the scratchpad and on `build`
as it was, `show` denied. The scenario's `context_window` (14,000 tokens, `compact_at`
0.8) is the run's model's window whatever the person's catalog says (`Live` puts it under
`windows` for the run's model), so the first compaction comes before the fourth turn on
both sides, and the fourth and fifth turns are the same work after a compaction. A limit a
scenario sets is now its run's, the runner's deadline among them (five long turns do not
fit a one-turn task's 240 s); the cap is still the plan's, as it was said before anything
started.

**Live**, on the installed build, Claude Sonnet 5.5 ($2 in, $10 out, $0.20 a cache read,
$2.50 a cache write per million; the summaries on Claude Haiku 4.5), on Windows,
2026-10-12. Tokens are fresh (sent uncached or written to the cache) / read from the cache
/ output. Three runs without the scratchpad; one with it on this build, which is what the
slot's $3 left room for (the three runs with it on the two builds before were what changed
it, below).

| | with the scratchpad | without, three runs |
|---|---:|---:|
| runs whose checks held | 1 of 1 | 3 of 3 |
| compactions | 6 | 3, 3, 3 |
| the first | in the second turn | after the third turn, each |
| the whole run | $0.4632; 79,498 / 84,240 / 29,347 | $0.3140, $0.3531, $0.3456; 50,491 / 39,912 / 24,642 on average |
| from the run's first compaction | $0.3111; 66,853 / 57,813 / 17,831 | $0.1562, $0.1764, $0.1861 |
| the fourth and fifth turns | $0.1842; 34,140 / 29,034 / 11,377 | $0.1497, $0.1695, $0.1754 |

- **The pointers do what they are for.** After every compaction no call carried a
  document's words, the agent read the plan back with `read_file` when a turn needed it
  (twice), showed it again revised, and every check held: the fourth reply's 400 seconds,
  the last plan's row counts.
- **The issue's live measure is not met by this scenario.** From each run's first
  compaction the run with the scratchpad cost $0.31 against $0.16 to $0.19, and the fourth
  and fifth turns, the same work after a compaction on both sides, $0.18 against $0.15 to
  $0.18 (a run on the build before the last rule, $0.13). Under this window, a compaction
  at 11,200 tokens over a 6,800-token start, the session with the scratchpad compacted
  after nearly every call, six times against three: a turn of it makes two calls where the
  other makes one, the `show` call's prompt crosses the line in the middle of the turn,
  and each read-back of the plan (14.5 KB, about 4,500 tokens) crosses it again. Each
  compaction writes the whole prompt to the cache again and calls the summariser. The
  session without it keeps its plans in its tail and pays for them in its three
  compactions' cache writes (8,000 to 14,600 tokens each).
- **What would measure it.** A window where compactions are rare against the calls between
  them, so what a pointer saves on every call can outweigh a read-back; and a revision
  that does not read the whole document back and show it whole again, which #472's `patch`
  variant would give. Neither is in this decision.
- **The builds before.** With pointers only, a session's fourth compaction wrote a summary
  of one sentence, the documents' names went with the rest, and the next turn looked for
  the plan in the workspace with `grep` and `list_files` and answered without it: so the
  summary lists the scratchpad, and another file tool given a `scratch:` path names the
  read. With that, a compaction in the middle of a turn left its last `show` a pointer and
  the model showed the plan again three times: so a call the model has not replied after
  keeps its words. The scenario's output budget is 40,000 since these runs; the runs with
  the scratchpad reached 24,000 after their last `show`, before the closing reply.
- Seven runs and one stopped, $2.80 of the slot's $3. To run it again:
  `troupe bench --live --scenario scratchpad_session,scratchpad_session_without --repeat 3
  --model claude-sonnet-5-5`.

**Proof.** `Troupe.Agent.ScratchCompactionTest`, against the scripted model: after a
compaction the next request's `show` call carries the pointer (name, title, version, size
and the `read_file` call) and nothing of the document, the `compacted` event logs the same,
and the document is on the scratchpad as it was; the summariser's request has the pointer
and not the words, and the summary after it lists the document; two versions in a tail
each have their own pointer; a call the model had not replied after when a compaction in
the middle of its turn came keeps its words until the next; a refused call and an agent
with no `read_file` keep the words, and an empty scratchpad is not listed; each request
before the compaction began with the one before it, the document whole, and each after
it, a restart included, begins with the one before it; `read_file` reads
`scratch:/plan.md` back after the compaction, and refuses a missing name, a path out of the
scratchpad and the directory; `grep` and `write_file` given a `scratch:` path name the
read. Against the stand-in as Claude Sonnet 5.5 with `thinking_binding: error`: a
compaction whose tail holds the plan keeps the pointer and no thinking, and no request is
refused, the summariser's included. `BenchLiveTest`: the pair runs by name, the one
without the scratchpad on `build` as it was; a scenario's window holds against a person's
`models.windows` that says a million, and its wall clock against a plan's of one second.
On the chunk's tip six of the first file's first eight cases failed (the words went whole, to the
model and to the summariser, and `read_file` refused the path), and so did the window and
the wall clock. And the installed daemon on scratch homes, against a stand-in behind a
proxy that logged each request: the call after a compaction carried the pointer and the
listing, not the 12,846-byte plan the call before it carried, and a `read_file` of
`scratch:/plan.md` returned it.
