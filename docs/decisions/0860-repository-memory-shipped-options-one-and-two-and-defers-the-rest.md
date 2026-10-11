---
number: 860
title: "Of #248's five options for repository memory, options 1 and 2 shipped in 0.10.0 and 0.11.0; deriving memory from the session log, symbol anchors, a co-change graph, vectors and the plane's shared levels are deferred, each with what it waits for"
date: 2026-10-11
status: accepted
issue: 248
paths:
  - apps/troupe_core/lib/troupe/memory.ex
  - apps/troupe_core/lib/troupe/memory/facts.ex
  - apps/troupe_core/lib/troupe/tools/recall.ex
  - apps/troupe_core/lib/troupe/tools/remember.ex
gist: "#248 shipped options 1 (facts with provenance and an anchor) and 2 (records queried by recall); 3, 4, 5, vectors and shared levels are deferred, see here first"
---

#248 put five options for repository memory up for discussion. The maintainer chose to build options 1 and 2 together in chunk 26. #248 was closed in chunk 28's fold. This file records what shipped and what did not, so the next person reading the memory code doesn't take the closed issue for the whole plan.

**Shipped.**
- **Slice 0: a shell call's outcome as a field.** `exit_status` and `timed_out` are on `tool_call_completed` (Decision 837), so a command's pass or fail can be read without parsing output. This is what option 3 would fold over.
- **Option 1: facts with provenance and an invalidation anchor.**
  - Each fact records what it rests on: anchors (path and hash) and evidence (session, seq, HEAD, writer, exit status).
  - Its status (`current`, `moved`, `missing`, `unanchored`) is worked out when it is read, and nothing deletes a fact mechanically.
  - Anchors must be files git tracks, on write and on read.
  - Decisions 838, 839 and 854.
- **Option 2: records queried on demand.**
  - Facts live in `.troupe/memory/facts.jsonl`, one per line, written by one process per repository.
  - The prompt carries only the `command` and `convention` facts, with `moved` and `missing` ones marked "may no longer be true".
  - The rest comes through the `recall` tool, by query, kind, path or status.
  - `.troupe/memory.md` is a view generated from the facts (838, 839).

**Deferred, and what each waits for.**
- **Option 3: memory derived from the session log** (commands seen to pass, co-change, flaky tests, negative memory). It waits for:
  - a review path before a derived fact reaches anyone else;
  - deciding which derivations come first.
  The log already carries the outcome fields it needs (837).
- **Option 4: anchors on symbols, not paths.** It waits for code intelligence: symbol-level navigation, #36, folded into #487. Path anchors are what ships until then.
- **Option 5: a co-change and dependency graph.** It waits for the same index as option 4, and for the confidence threshold #248 proposed (rules at 0.9 or above, with support of 10 or more, promoted to facts).
- **Vectors.** A later layer over prose only, judged against a measured FTS5 baseline, as #248 proposed. Nothing in the store depends on them.
- **The plane's shared levels** (org, team, profile, user). These are #55. The local store's record shape is meant to carry over, but how it reconciles with a plane store is not decided.
- **Measuring before widening.** #248 asked for tokens and tool calls to a first edit, with and without the brief, on a fixed task set, against the ETH study's 20%. That measurement has not been run. It is owed before any deferred option widens what reaches the prompt.

**Why write it down.** The issue is closed and its options read as a roadmap. Without this, a reader would either assume 3 to 5 shipped, or reopen the discussion from scratch.
