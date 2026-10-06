---
number: 781
title: "A tool's result is cut at 32 KiB by default, not 60,000 bytes: what is cut is one `read_output` call away, and what is sent goes out again with every call after it"
date: 2026-10-05
status: accepted
issue: 407
paths:
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/test/troupe/config_test.exs
gist: "A tool's result is cut at 32 KiB by default, not 60,000 bytes: what is cut is one `read_output` call away, and what is sent goes out again with…"
---

Issue #407, the other half of #389's slice 3, whose number Decision 771 left for a
measurement. The first live bench against a real model (`qwen3-235b`, three runs of
each task) had one `fix_test` run cost $0.103 where the other two cost $0.041 and
$0.018: a `shell` call returned more than 60 kB, it was cut at the limit, and the four
calls after it, which carried it again, were 100,574 of the run's 133,073 input
tokens. That gateway caches nothing, so each call paid for it in full, and 771's stub
applies only behind a compaction, which no run came near.
- **Why 32 KiB (32,768 bytes).** The maintainer's choice between the old 60,000 and
  the issue's candidate, 16 KiB, the blob inline limit where 771's stub floor sits.
  32 KiB still sends whole what an agent ordinarily asks for: a `grep` of 200
  matching lines of up to about 160 bytes, and a file of `precise_edit`'s size (1,560
  lines, 31,042 bytes as `read_file` numbers them) in one read. At 16 KiB that file
  is cut, and so is such a `grep` past about 80 bytes a line, and each cut the model
  needs the rest of is a round trip; a number below 32 KiB needs measurements of its
  own.
- **What a cut costs.** The model is sent the first 32 KiB and the marker, and
  `read_output` pages the rest back, 200 lines a call: one round trip, the whole
  prompt again with the page, when the model needs the rest, and nothing when it
  does not. Against that, every later call carries up to 27,232 bytes less, until a
  compaction summarises the result away; in #407's dear run, four calls. Offline,
  `cut_output`, whose script does read the rest back, sends 39,649 tokens (four bytes
  each, 772) over its three calls where it sent 46,422: the call with the page
  carries the whole result either way, and the call before it 27 kB less.
- **One default.** `grep`, `git_read`, `read_file`, `shell` and `web_fetch` each kept
  a copy of 60,000 for a context with no config; they read `%Config{}`'s now, so the
  next move is one line. The key table says `read_output` pages the rest back, where
  it said the rest is kept as a blob.
- **The bench.** Offline, `cut_output`'s cut result is 32,869 bytes (59,892 before),
  and its budget 36,000 (61,000), a tenth over (772); every other measure is as it
  was. The live scenarios still test what they say, so none changed: `large_log`'s
  480 kB log is more than a read returns at either limit, `precise_edit`'s file still
  arrives whole in one read, and the other tasks' files are under 1 kB each. The live
  bench's `fix_test` worst cost and median input, before and after, are on the pull
  request.
- **Not here:** D66's markers naming `read_output` to the profiles that do not offer
  it (`explore`, `answer`, `ask`, `librarian`), which a lower limit makes those agents
  meet more often; the stub floor of 771. A `tool_output_limit` a person has set
  holds as before.
- **Proof:** `ConfigTest`: the default is 32,768 in the struct and in the key table,
  and a tool with no config cuts a 60 kB read at it, both failing on the chunk's tip
  (60,000, and 59,966 bytes); `BenchLiveTest`'s read cut at the new limit in a run's
  `tool_calls`; `ExplainTest` against the regenerated reference; the offline bench
  within its budgets; and the installed `troupe bench` and `troupe config --explain
  tool_output_limit`, on the pull request.
