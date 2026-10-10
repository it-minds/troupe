---
number: 838
title: A repository's memory is facts kept one per line with what they rest on, their status worked out when read; the prompt carries the commands and conventions and names `recall` for the rest, and `.troupe/memory.md` is a view generated from them
date: 2026-10-10
status: accepted
issue: 248
supersedes: [649, 696]
paths:
  - apps/troupe_core/lib/troupe/memory.ex
  - apps/troupe_core/lib/troupe/memory/facts.ex
  - apps/troupe_core/lib/troupe/memory/facts/store.ex
  - apps/troupe_core/lib/troupe/session/memory.ex
  - apps/troupe_core/lib/troupe/tools/recall.ex
  - apps/troupe_core/lib/troupe/instructions.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/application.ex
  - apps/troupe_core/priv/agents/explore.md
  - apps/troupe_core/priv/agents/plan.md
  - apps/troupe_core/priv/agents/reviewer.md
  - apps/troupe_core/priv/agents/workflow.md
  - apps/troupe_core/test/troupe/memory/facts_test.exs
  - apps/troupe_core/test/troupe/tools/recall_test.exs
  - apps/troupe_core/test/troupe/memory_test.exs
  - apps/troupe_core/test/troupe/tools/remember_test.exs
symbols:
  - Troupe.Memory.Facts
  - Troupe.Memory.Facts.Store
  - Troupe.Memory.prompt/2
  - Troupe.Memory.stale?/3
  - Troupe.Session.Memory.locate/1
  - Troupe.Session.Memory.status/2
  - Troupe.Tools.Recall
gist: "Facts in .troupe/memory/facts.jsonl, hashes Troupe's, status on read; prompt = commands+conventions+recall line; memory.md generated, edits read back"
---

Issue #248, Options 1 and 2, as the maintainer chose them for 0.10.0. The brief was prose
a model wrote, prepended to every prompt with "treat it as correct", and stale only by age
or when the tracked-file count moved by a tenth: on the chunk's tip a brief whose command
rested on `mix.exs`'s `check` alias stayed `fresh` after the alias changed, and the next
prompt gave the old command with nothing said (the reproduction, kept in the slot's
scratch). Now:

- **A fact is a record** (`Troupe.Memory.Facts`): `id`, `kind` (`command`, `convention`,
  `overview`, `layout`, `note`, `negative`), `claim`, `scope` (a glob or null), `anchors`
  (`path` from the top of the checkout or worktree, `hash` the lowercase hex sha256 of the
  file's bytes), `evidence` (`session`, `seq`, `head`, `exit_status` when given, `by`:
  `librarian`, `agent:<name>`, `person` or `migrated`), `created_at`, `verified_at`.
  Troupe computes the hashes, `head`, the id and the times; a model names only paths. The
  same kind and claim written again is that fact checked again (its id and `created_at`
  stay). An anchor is a regular file in the workspace of at most 10 MiB: outside it (by
  `..`, an absolute path or a link), in `.git`, the memory's own files and a directory are
  refused with a sentence. An anchor read back from the file is held to the same edge
  before anything is read, since a repository's `facts.jsonl` is not Troupe's word: an
  anchor of `/dev/zero` or `../elsewhere` is `missing`, never read. Path anchors only;
  symbols wait for #36.
- **Status is computed when read, never stored**: `current` (every anchor hashes as
  written), `moved` (one changed), `missing` (one is gone; it wins over `moved`),
  `unanchored` (none). `moved` and `missing` render as "may no longer be true", and so does
  an unanchored fact not checked for `memory_max_age_days`, which ages out by
  `verified_at` as the brief did by `built_at`. Nothing deletes a fact for its status: a
  moved anchor is evidence that something changed, not that the fact is wrong, and the
  librarian re-checks it. Cheaply: each anchor file's hash is cached beside its size and
  mtime and taken again only when either moved, or when the file was written in the second
  it was hashed (mtimes are whole seconds, so that one is never trusted); a prompt stats a
  fact's anchors and never walks the repository.
- **The store** is `.troupe/memory/facts.jsonl` in the checkout whose `.troupe/memory.md`
  held the brief (Decision 831's rule, now `Troupe.Session.Memory.locate/1`, which also
  gives the top anchors are read from, so a worktree on a branch whose `mix.exs` differs
  says so). One process per store (`Troupe.Memory.Facts.Store`, under the core's
  `Troupe.Memory.Facts.Stores`, started on first use, restarted if it dies) is its only
  writer and holds the facts in ETS for the readers, who read without asking it. Every
  write replaces the file whole by rename, so a crash leaves the old file or the new one;
  a line that does not read as a fact (one torn by another writer) is skipped with a
  warning and the rest stands. A file another daemon, a pull or a person wrote since is
  read again before anything is answered or written (size and mtime, as anchors are). No
  new native dependency: it builds on Windows and in the Burrito payload. The plane's
  shared levels come with #55.
- **The prompt carries a small core** (`Troupe.Memory.prompt/2`): the `command` and
  `convention` facts, oldest first, current ones as written and the doubtful ones marked
  with why (`mix.exs` changed, `lib/a.ex` is gone, last checked on a day), whole facts
  within `memory_max_chars`; the characters of those left out are what the prompt's
  provenance reports as `trimmed`. Then one line naming `recall` and how many other facts
  it answers, by kind. The preamble no longer says "treat it as correct": it says the
  facts were checked when written, which may no longer be true, and to read the error and
  the file a failing command comes from rather than run it again. Overview, layout, notes
  and what did not work come through `recall` (the ETH study #248 cites: agents follow
  commands and conventions, overviews do not help, and agents use the tools a context file
  names).
- **`recall {query?, kind?, path?}` is a tool the model calls**, not a retrieval the
  harness runs before a turn: a fact costs nothing until it is asked for, and the model
  knows when it needs one. Any of the query's words in the claim or scope, the kind, a path
  a fact rests on (or a file under a directory) or its scope covers; current and
  unanchored before doubtful, then more words matched, then most recently checked; twenty
  at most, saying when more match. In every profile with every tool, and named by
  `reviewer` and `workflow` (which name `remember`) and by `explore` and `plan` (the
  read-only investigators, who would otherwise lose the layout the prompt no longer
  carries). The brief's line naming it is left out for an agent without it
  (`Troupe.Instructions.to_prompt/2`'s `recall`), so a profile that lists its tools is not
  told of a tool it cannot call. BM25 and vectors are later, as #248 proposes.
- **`.troupe/memory.md` is a generated view**, rewritten whenever a fact changes: the
  brief's stamp (`built_at`, `head`, `survey`) and `generated`, the hash of the body, then
  a line saying it is generated from `facts.jsonl` and that an edit is read back, then a
  section per kind and an item per fact (an agent's note as notes read before, `- <day>
  <agent>: ...`). No facts, no view. Clients that read the brief's `status`, `sections`
  and `text` read it as before. **A person's edit is not lost:** a view whose body is not
  the one generated is read back item by item against the facts it was generated from
  before it is generated again; a new item is a fact of the person's (`by: person`,
  unanchored), and a fact whose item was taken out is forgotten, so the edit means what it
  says. **A brief from before facts** (a `memory.md` and no `facts.jsonl`) is migrated on
  first load: every item a fact (`by: migrated`, unanchored, checked when the brief was
  built, a dated note on its day), an unknown section's items as notes led by its title,
  its stamp carried over; nothing of the text is left out. An unstamped `memory.md` beside
  facts it was not generated from (an old brief in a checkout that pulled another's facts)
  adds its items and takes nothing away. Not chosen: a separate file recording what was
  generated (one more file that could disagree), and reading the view back on every read
  as the source of truth (the view cannot carry anchors).
- **When the brief is due** (`Troupe.Session.Memory.status/2`, so `refresh_due?/2`,
  `memory.get` and Decision 835's `brief.due` with it): `absent` with no facts; `stale`
  when it was never built, is older than `memory_max_age_days`, or a command or convention
  rests on a file that changed or went **after the brief was last checked** (the file's
  mtime, or for a gone one its nearest directory's, against `built_at`); `fresh`
  otherwise. The tracked-file-count drift goes (Decision 696 and TUI Decision 54 kept it):
  it missed 149 changed files in 69 commits, and costs a `git ls-files` at every look. The
  "after the last check" is what keeps a cheap librarian that ran and left a moved fact as
  it was from being started again at every session: the fact stays marked in every prompt
  until a librarian or an agent re-anchors it. A librarian's stamp (`checked/1`) also
  counts every unanchored fact as checked, which is all a check of one can be; a moved
  fact it leaves alone.
- **What this supersedes.** Of Decision 649: the brief as prose read whole into every
  prompt, and `remember`'s note reaching the next agent's prompt (it reaches `recall`; U26's
  slice changes `remember` itself). Of Decision 696: "or the repository has drifted", and
  the file count a stamp recorded (`files` is read from an old brief, never written).
  The rest of both stands: the brief is the daemon's, a librarian's run that ends as it
  meant to stamps it, and a failed try holds off the next (Decision 713).
- **The contract with U26** (the chunk's fourth wave, fixed in the brief): `put/3`,
  `list/2`, `recall/2`, `status/2`, `delete/2`, `core/1` as above; facts are the string-keyed
  maps above plus `"status"` when read. `core/1`'s facts also carry `changed`, `gone` and
  `changed_at` for the prompt. U26 writes facts from `remember` and the librarian, raises
  the survey to 2, and adds `facts` and `generated` to `memory.get`.
- **Proof.** `Troupe.Memory.FactsTest`: #248's slice-1 done-definition (a `command` fact
  anchored on `mix.exs`, its `check` alias edited within the second it was hashed, the next
  prompt and a real session's system prompt saying "may no longer be true" and the brief
  `stale`), which failed on the chunk's tip; the hashes, head, evidence, id, times and the
  line's field order; every refused anchor, and anchors in the file pointing out of the
  repository read as `missing` with nothing read; the four statuses; the cache by size and
  mtime; 25 concurrent writes landing, one process per repository, and a killed store
  restarted with the facts; a torn line and another writer's line; the view and its
  deletion with the last fact; a person's edit read back (changed, added and taken-out
  items, an unknown heading, a multi-line item kept with its id); today's five-section
  brief migrated with every line of text in the view; an unstamped brief beside facts; the
  prompt's core, marks, recall line and cap; recall by words, kind, path and scope, and its
  order; due with no facts, a moved command, by age, and not for a moved layout fact, fifty
  new files, or a move the last check already saw; a view's claims of many lines, lists
  and fences reading back as themselves. `Troupe.Tools.RecallTest` (the tool's answer, and
  the line named to `build` and `plan` and not to a workspace agent without the tool),
  `Troupe.MemoryTest`, `Troupe.Tools.RememberTest` (a note is the next session's to recall;
  the stamp and the hold as before, a hold not past a change after the build).
