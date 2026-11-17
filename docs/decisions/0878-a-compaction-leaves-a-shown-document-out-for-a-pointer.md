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
  - apps/troupe_core/lib/troupe/bench/live.ex
  - apps/troupe_core/lib/troupe/bench/live_scenarios.ex
symbols:
  - Troupe.Tools.Show.left_out/1
  - Troupe.Tools.Show.pointer/1
  - Troupe.Tools.Show.listing/1
  - Troupe.Scratch.readable/2
gist: "only a compaction puts a pointer for a shown document's words, in its tail and summariser's read, and lists the pad; read_file reads scratch:/<name> read-only"
---

**What changed.**

- **The pointer.** What a compaction keeps has, in place of each shown document's words,
  one line: `[plan.md ("Migration plan", version 2, 10234 bytes) left out since a
  compaction; it stays on the scratchpad. Call read_file(path: "scratch:/plan.md") to read
  its latest version.]`. It replaces the call's `content` argument; its `name`, `title`
  and `kind` stay, so the call still reads as what it was.
- **In the tail too, every version.** The tail a compaction keeps is the last few messages;
  a `show` call there has its words replaced like any other, and each version its own
  pointer. Not kept for the latest version of each document: what the model last showed
  is on the scratchpad, word for word, one call away, and a tail that kept it would keep
  the largest thing in it, the cost the issue is about. A version the model has replaced
  since says which version it was, and the read gives the latest.
- **But not a call the model has not replied after.** A compaction in the middle of a turn
  comes after a call whose result the model has not read yet. That call keeps its words
  until a later compaction, as 771 keeps such a result whole.
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
