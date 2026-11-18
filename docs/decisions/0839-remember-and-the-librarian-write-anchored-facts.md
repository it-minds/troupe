---
number: 839
title: remember and the librarian write facts anchored on the files they were read from, with evidence Troupe takes from the session, and memory.get, memory.forget and the TUI's /memory show and forget them one by one
date: 2026-10-10
status: accepted
issue: 248
paths:
  - apps/troupe_core/lib/troupe/tools/remember.ex
  - apps/troupe_core/lib/troupe/tools/recall.ex
  - apps/troupe_core/lib/troupe/memory/facts.ex
  - apps/troupe_core/lib/troupe/memory.ex
symbols:
  - Troupe.Tools.Remember.run/2
  - Troupe.Memory.survey_version/0
  - Troupe.Client.Daemon.memory_page/1
gist: "remember: kind/claim/anchors (tracked files only); Troupe takes hash, seq, exit; replaces: librarian any, agent own or moved; recall by status; survey 2"
---

**`remember` writes facts.** It takes `kind` (`command`, `convention`, `overview`,
`layout`, `negative`, `note`), `claim`, `anchors` (workspace-relative paths) and an
optional `scope` glob, and writes through `Facts.put/3`. What makes the fact evidence is
Troupe's, never the model's: the store hashes each anchor as it writes, and `remember`
gives it the session, the seq of the `tool_call_started` that began this call (read from
the session's own log), who wrote it (`librarian` for the librarian, otherwise
`agent:<profile>`) and, for a `command` fact, the exit status of the session's latest run
of a command the claim names. A command is named when it is the claim, or one of the
claim's code spans, word for word (whitespace aside); a looser match (a substring) would
give `mix test`'s status to a claim about `mix test apps/x`.

**Anchors are held to the workspace.** Each is resolved as the file tools resolve a read
(`Workspace.resolve/3`): a path out of the workspace, a link out of it, a directory or a
file that is not there is refused by name, before the store holds them to its own edge
(838: not in `.git`, not memory's own files, at most eight, none over 10 MiB). Not
`resolve_readable/3`: a read root would let a fact carry the hash of a file outside the
repository, and a hash is an oracle for what a file holds.

**Only a file git tracks is an anchor.** In a git repository the store refuses, for every
writer (`Facts.put/3`, so the librarian, an agent, a migration alike), a file git ignores
or has never been given (`git ls-files --cached`; an added file counts): the hash of a
`.env` would otherwise go into a `facts.jsonl` that may be committed, and a hash is an
oracle for a short secret. Where git cannot answer inside a repository the anchor is
refused, not guessed.

**`replaces` re-verifies.** With a claim, the new fact is written and the one it names is
dropped once it is; alone, it drops that fact. The same kind and claim written again is
the same fact to the store (838), its id kept and its anchors and evidence this call's,
and is not then dropped. That is how a fact that may no longer be true is re-anchored,
corrected or dropped. A person's fact (`by: person`, a hand edit read back) is theirs:
`remember` neither replaces nor drops it, and only `memory.forget` removes it. The
librarian may replace or drop any other fact; another agent only one it wrote itself (the
same `by`) or one that is `moved` or `missing`, and is told so otherwise. `remember` is
`:auto` and in the read-only set (`explore` and `plan` have it), so without this one agent
a prompt talked round could erase what the librarian checked, unasked.

**The librarian writes no notes.** Asked for one, `remember` refuses it by the agent's
name: a note is what an agent learned working here, and a survey learns commands,
conventions, an overview and a layout. Enforced, not only asked, because the prompt asked
before and a cheap model does not always listen.
