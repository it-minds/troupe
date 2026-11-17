---
number: 922
title: "The organisation's, each team's and each worker profile's memory documents are kept on the plane, every version with who saved it and audited, edited in the console by the administrators whose they are, each at most 8192 bytes; every session in a scope reads them as instructions from the organisation before the person's own file and the repository's, in that order, a pod's from the activation and a laptop's from the daemon's signed copy of me.memory, and no agent can change one"
date: 2026-10-18
status: accepted
issue: 55
paths:
  - apps/troupe_protocol/lib/troupe/protocol/memory.ex
  - apps/troupe_plane/lib/troupe/plane/memory.ex
  - apps/troupe_plane/lib/troupe/plane/memory/document.ex
  - apps/troupe_core/lib/troupe/plane_memory.ex
  - apps/troupe_core/lib/troupe/instructions.ex
symbols:
  - Troupe.Protocol.Memory
  - Troupe.Plane.Memory
  - Troupe.PlaneMemory
  - Troupe.Plane.Admin.memory_put/5
gist: "Org, team, profile memory on the plane, versioned, audited, 8192 bytes each; sessions read them first, org then team then profile, as instructions; no tool writes them"
---

The maintainer decided the slice on 2026-10-18: layered memory files, the organisation's,
a team's and a profile's, on the plane and edited in the console, each reaching every
session in its scope as an instruction layer, like a project brief, with the person's own
memory on top, read-only to agents.

## The documents

`Troupe.Plane.Memory` keeps them in `memory_documents`, **one row per version**, never
updated: `scope` (`organisation`, `team`, `profile`), `owner` (empty for the
organisation's, the team's id, the profile's name), `version` from 1, `text`, its
`sha256:` hash and `changed_by`. A team's is keyed by its id, so a renamed team keeps its
memory; a profile's by its name, as a profile is. An empty text clears a document: it is a
version like any other and reaches no session. The text a save would leave in force
already makes no version and no audit row.

A save names the version it was edited from (`0` for none). One whose base somebody else
replaced first is refused as `conflict`, naming the version now in force, rather than
overwriting it: the console shows the sentence and the editor is not lost. The unique
index on `(scope, owner, version)` settles two saves at the same instant the same way.

**The limit is 8192 bytes a document** (`Troupe.Protocol.Memory.max_bytes/0`), of its
UTF-8 text, line endings made `\n` and trailing white space off. About two thousand tokens:
three documents in every prompt cost no more than the repository's own instruction files
may (16,000 characters), and a document that wants more is a wiki, not memory. The plane
refuses a save past it, at the preview and the put, with nothing written. A reader holds
a document to the same limit, cut at a character and marked `trimmed`, so a later plane
that allows more cannot grow a laptop's prompt past what this build agreed to. The limit is
in the protocol app because the plane and the reader must agree on it.

## Who edits which

| Document | Reads | Changes |
|---|---|---|
| the organisation's | any admin | a platform admin |
| a team's | its team admins and a platform admin; another team's admin is told `not_found`, as for the team | the same |
| a profile's | a platform admin | a platform admin, on the profile's page |

`admin.memory.list`, `admin.memory.get` (a version, its line-by-line change against the
one before, every version with who saved it and when), `admin.memory.preview` (the change
against the version in force, the size against the limit and which sessions read it and
when, written nowhere) and `admin.memory.put`. A put is audited as `memory.put` on
`organisation`, `team/<name>` or `profile/<name>` with the version, size and hash before
and after; every version's text is kept, so the audit names the versions to compare
rather than copying eight kilobytes into a row twice. A team admin's audit listing has
their team's memory rows (`Audit.about/2`).

**The console.** *Company memory* (the area the map already held, now drawn) has the
organisation's and the teams' the caller administers, each with the version in force, who
saved it and when, its text, *Change*, every version opening onto what it changed, and,
for a team admin, the organisation's read-only with who changes it. A profile's is on the
profile's own page, through the same editor, also on a gitops plane: a profile's memory is
the plane's, not its manifest's.

## How a session gets them

Every session in a scope reads them **as instructions from the organisation, before
everything else**: the organisation's, then its team's, then its profile's, then the
person's own `<config>/AGENTS.md` and the repository's files and brief as before. Nearer
comes later and wins, as the instruction files already said: a team's over the
organisation's, a profile's over the team's, the person's and the repository's over all
three.

- **On a pod**, the plane reads them at every activation (`Memory.for_session/2`: the
  organisation's, the session's team's, the session's worker profile's) and sends them as
  `memory` beside the bundle pin, as it sends the profile's switches and rules (Decision
  879); the worker hands the list to the session as its `plane_memory`, never from a file.
  A save reaches a session the next time it wakes and restarts no pod; an empty list takes
  away what was there. The profile's is its own: a child profile does not read its
  parent's (a follow-up, if wanted, with Decision 908's chain).
- **On a laptop**, the daemon asks `me.memory` after the organisation's document, at every
  `identity.link` with a token and after a person accepts a changed key. The plane answers
  the organisation's and each of the caller's teams', by name, never another team's and
  never a profile's (a laptop's session runs on none), **signed as `memory`** by its key
  (Decision 919). The daemon keeps the answer as `<state>/memory.json` beside
  `organisation.json`, with the signature, which `Troupe.PlaneMemory.read_cache/1` checks
  against the pin on every read, as Decision 919 has the organisation's document checked: a
  copy changed on this machine, or an unsigned one of a plane whose key is pinned, is
  refused with a sentence and the session reads none; one past its week still holds, with
  a warning. A plane without `me.memory` leaves the copy as it was. A laptop's session is
  of no team, so it reads all of its person's teams': that is how "a team's memory reaches
  that team's sessions" reads where the session is the person's.
- **Read once, as the configuration is resolved** (`Troupe.Config.resolve/3`, through
  `Troupe.PlaneMemory.in_force/2`), into the configuration's `plane_memory` and the layers'
  `memory`. So what a session runs with is what explains it (Decision 918), on a pod and on a
  laptop alike; a refreshed copy reaches the next session started, not one running. Not
  chosen: reading the copy at every turn as the instruction files are, which would make a
  running session's instructions move under it without `config --explain` saying so.

`Troupe.Instructions` lists each as a file of its own scope (`organisation`, `team`,
`profile`) first, named `memory:organisation`, `memory:team/<name>`,
`memory:profile/<name>`, with its `version`, `name` and `label`, in `context.get` and the
`instructions_loaded` event, so nothing reaches the prompt without appearing in the
provenance. They are **outside the files' budget**: each is held to its own limit on the
plane, and none is cut to make room for a repository's file or the reverse. The prompt has
them in a section of their own, *Your organisation's memory*, whose preamble says they are
instructions from the organisation that apply as written, which disagreement the narrower
wins, that no tool of the agent's writes them, and that asked to change one the agent says
it cannot and points at the console (Company memory, or the profile's page).

## Read-only to agents, and treated as instructions

No tool writes them. On a pod they exist only in the session's configuration; on a laptop
the copy is in the state directory, outside every workspace, where `write_file`,
`edit_file` and `shell`'s sandbox do not reach (`Workspace.resolve/3` refuses it as
outside), and `remember` writes only the repository's facts. The section's preamble is what
an agent asked to change one reads. They are the organisation's word, in the instruction
section, not fenced as data: that is what an administrator writing them means, and they
come only from the plane, signed on a laptop, over the control channel to a pod.
