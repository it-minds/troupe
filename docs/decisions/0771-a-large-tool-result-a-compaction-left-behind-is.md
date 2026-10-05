---
number: 771
title: A large tool result a compaction left behind is sent from then on as one line naming the `read_output` call that returns it, not again in full on every call
date: 2026-10-04
status: accepted
issue: 389
paths:
  - ARCHITECTURE.md
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/tools/output.ex
  - apps/troupe_core/lib/troupe/tools/read_output.ex
  - apps/troupe_core/test/troupe/agent/compaction_test.exs
  - apps/troupe_core/test/troupe/tools/output_test.exs
gist: A large tool result a compaction left behind is sent from then on as one line naming the `read_output` call that returns it, not again in full on…
---

Issue #389, the behaviour of slice 3; the numbers (`tool_output_limit`, `compact_at`)
stay as they are until slice 1's measurements say what they should be. A compaction
summarises the older part of the conversation and keeps the last few messages as they
were, so a 60 kB `grep` the model read just before it went out again with every call
after it, until a later compaction summarised it away.
- **What is behind.** The messages a compaction kept, up to the model's last reply
  among them: `State.compacted_through`, set by the compaction and folded from its
  `compacted` event. A result after that reply is the one a compaction in the middle
  of a turn was about to send; the model has not read it, so it goes whole until the
  next compaction. Results since the compaction are never touched.
- **Which results.** Those over the blob inline limit, 16 KiB: the log already keeps
  them as blobs, so the stub's id names one without a new write (`Output.keep/2`
  makes sure). Below that a stub saves less than the `read_output` round trip it may
  cost, which sends the whole prompt again, and a floor of its own would be one more
  number to guess before slice 1 measures.
- **An error result by the same rule.** The block keeps its error flag, so the model
  still knows the call failed. Most failures are a short message, under the floor; a
  large one is a failing command's output, the same bulk as any other.
- **The stub.** `[output of grep (48213 bytes) left out since a compaction. Call
  read_output(id: "sha256:…", offset: 1, limit: 200) to see it again.]`, the call a
  truncation marker names (650). The tool is named by the call just before the
  result, not by id across the conversation: a gateway that numbers its calls gives
  every response a `call_0`.
- **Only in what is sent.** `build_request` stubs; the conversation in memory, the
  snapshot and the log keep the result whole, so a replay rebuilds the same
  conversation and the same boundary, and an audit sees everything. The summariser
  still reads what it summarises whole: it condenses those results rather than
  sending them again.
- **Only where `read_output` is offered.** A profile without it (`explore`, `answer`,
  `ask`, `librarian`) keeps its results whole: a stub it cannot expand is a result
  lost.
- **A summary that fails** leaves the conversation, and the boundary with it, as
  they were (774).
- **The prefix stays put.** What is behind changes only when a compaction rewrites the
  head of the conversation anyway, so from one call to the next the prompt starts the
  same, which a prompt cache (slice 2) needs.
- **Not here:** a smaller default `tool_output_limit`, the other half of slice 3, and
  whether the floor should come down, both for slice 1's numbers.
- **Proof:** `CompactionTest`: the request after a compaction carries a one-line stub
  for a `read_file` result over 16 KiB and nothing of its body, which failed on the
  chunk's tip (the result went whole); `read_output` with the stub's id returns the
  result byte for byte; a result since the compaction is sent whole after the model
  has answered it; one the model had not answered when a compaction in the middle of
  a turn ran is sent whole, and so is one when a later summary fails; and a killed
  agent folds its log to the same conversation and sends the same stub, while the log
  holds the result as a blob, in `tool_results` and in the `compacted` conversation
  (774). `OutputTest`: the stub, ids that repeat across responses, the floor, an
  error's flag.
