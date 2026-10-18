---
number: 922
title: "The organisation's, each team's and each worker profile's memory documents are kept on the plane, every version with who saved it and audited, edited in the console by the administrators whose they are, each at most 8192 bytes; every session in a scope reads them as instructions from the organisation before the person's own file and the repository's, in that order, a pod's from the activation and a laptop's from the daemon's signed copy of me.memory, and no agent can change one"
date: 2026-10-18
status: accepted
issue: 55
paths:
  - apps/troupe_protocol/lib/troupe/protocol/memory.ex
  - apps/troupe_protocol/lib/troupe/protocol/plane_signature.ex
  - apps/troupe_plane/lib/troupe/plane/memory.ex
  - apps/troupe_plane/lib/troupe/plane/memory/document.ex
  - apps/troupe_plane/priv/repo/migrations/20261018000922_memory_documents.exs
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/admin/api.ex
  - apps/troupe_plane/lib/troupe/plane/admin/console.ex
  - apps/troupe_plane/lib/troupe/plane/audit.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_core/lib/troupe/plane_memory.ex
  - apps/troupe_core/lib/troupe/plane_keys.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/config/layers.ex
  - apps/troupe_core/lib/troupe/config/explain.ex
  - apps/troupe_core/lib/troupe/instructions.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_worker/lib/troupe/worker/plane/commands.ex
  - apps/troupe_worker/lib/troupe/worker/session/restore.ex
  - clients/tui/lib/troupe/client/instructions.ex
  - clients/gui/packages/client/src/admin.ts
  - clients/gui/apps/console/src/views/Memory.tsx
  - clients/gui/apps/console/src/views/Profiles.tsx
  - clients/gui/apps/console/src/views/bits.tsx
  - clients/gui/apps/console/src/nav.ts
  - PROTOCOL.md
symbols:
  - Troupe.Protocol.Memory
  - Troupe.Plane.Memory
  - Troupe.PlaneMemory
  - Troupe.Plane.Admin.memory_put/5
gist: "Org, team, profile memory on the plane, versioned, audited, 8192 bytes each; sessions read them first, org then team then profile, as instructions; no tool writes them"
---

#55 slice 1. Until now the only memory was a repository's (`.troupe/memory.md`, Decisions
649 and 838), which no other repository, person or team sees. The maintainer decided the
slice on 2026-10-18: layered memory files, the organisation's, a team's and a profile's,
on the plane and edited in the console, each reaching every session in its scope as an
instruction layer, like a project brief, with the person's own memory on top, read-only
to agents. Decision 860 had left exactly these levels to #55. This records how.

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
the plane's, not its manifest's. A change is a textarea with its size against the limit,
then the preview (the shared `Preview`, with a line-by-line `TextDiff` in place of the
fields' diff), then *Save*, then the audit's record, as every edit in the console is. The
diff is the plane's (`List.myers_difference/2` on lines), so what the preview shows is what
the plane compared.

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

**Named everywhere a layer is.** `troupe config --explain` (and `--session`, and the pod's
answer) lists each after the files, `memory   the team design's memory, version 5
(https://plane.example.test, fetched ..., kept in ...)`, a pod's as `(the plane, with the
session's activation)`, and `--json` has `memory`, each with `scope`, `name`, `version`,
`hash`, `source` and `fetched_at`. The TUI's `/context` names each by its label and
version, first.

## Read-only to agents, and treated as instructions

No tool writes them. On a pod they exist only in the session's configuration; on a laptop
the copy is in the state directory, outside every workspace, where `write_file`,
`edit_file` and `shell`'s sandbox do not reach (`Workspace.resolve/3` refuses it as
outside), and `remember` writes only the repository's facts. The section's preamble is what
an agent asked to change one reads. They are the organisation's word, in the instruction
section, not fenced as data: that is what an administrator writing them means, and they
come only from the plane, signed on a laptop, over the control channel to a pod.

## Not in this slice

A shared facts store, librarian-written team briefs and user-level memory on the plane
(out of scope by the slot); `troupe config pull` fetching memory beside the organisation's
document (it refreshes at the next link); the desktop app showing the layers (it has no
instructions view today); a child profile reading its parent's memory; a profile deleted
and made again under its name finding the old memory (the rows stay with the name);
announcing a refreshed copy to clients as `config.changed` is announced for the document.

## Proof

- `apps/troupe_plane/test/troupe/plane/memory_test.exs`: versions numbered and kept with
  who saved them, the text normalised, a version's line diff against the one before, the
  audit rows with the version from and to; the same text making no version and no row; a
  save over a replaced version refused naming the one in force; past the limit refused at
  the preview and the put with nothing written; the preview's diff, size and effect writing
  nothing; a team admin changing their team's, reading the organisation's, `not_found` on
  another team's, forbidden on the organisation's and a profile's, their audit listing
  their team's row; a platform admin editing all three, an unknown profile and scope
  refused; nobody who administers nothing reading any; a pod's session's documents in
  order and another team's left out; a cleared document reaching none; `me.memory` signed
  as `memory`, verified against the plane's served key and refused as `client_defaults`,
  holding the organisation's and the person's team's and not the design team's or the
  profile's; a person in no team getting the organisation's alone.
- `apps/troupe_plane/test/troupe/plane/bundles_test.exs`: the activation push carrying the
  organisation's, the team's and the profile's memory, none of another team's, after an
  empty list before any was saved. `admin_parity_test` and `console_coverage_test` hold the
  four methods to the table, the MCP tools and Company memory.
- `apps/troupe_core/test/troupe/plane_memory_test.exs`: a signed copy read into the
  configuration, the organisation's first; the copy edited on disk refused with the
  sentence and nothing of it read, and refused unsigned with the key pinned; an expired copy
  holding with its warning; the copy outside the workspace's writable reach; a pod reading
  the activation's documents and never the machine's copy; a document past the limit kept
  to it and marked; the instructions' order, outside the budget, the section's read-only
  words and the provenance's `version`; `config --explain` text and JSON naming each.
- `apps/troupe_core/test/troupe/instructions_prompt_test.exs`: a real session's prompt
  with the organisation's and a team's memory, then the person's own `AGENTS.md`, then the
  repository's, and the `instructions_loaded` event listing them in that order.
- `apps/troupe_gateway/test/troupe/gateway/plane_memory_test.exs`: a link to a signing fake
  plane keeping `me.memory` with its signature, and a session started after it listing the
  two documents first in `context.get`; a plane with no `me.memory` leaving the copy.
- `apps/troupe_worker/test/troupe/worker/plane_memory_test.exs`: `session.activate` with
  `memory` putting the organisation's, the team's and the profile's before the repository's
  `AGENTS.md` in the turn's system prompt, and `explain_session` naming each with its
  version; an activation with none giving none.
- `clients/tui/test/troupe/context_command_test.exs`: `/context` naming the organisation's
  and a team's memory first, each with its version.
- `clients/gui/apps/console/test/memory.test.tsx`: the organisation's with its version,
  a change previewed line by line, saved on confirm, the audit's note and the plane's row;
  a version opening onto its change; a conflict said and nothing saved; a team admin
  changing their team's and only reading the organisation's, another team's not listed; the
  limit held before anything is asked; a profile's edited on its page. `shell.test.tsx`
  now has no area left undrawn.

All of these failed on the chunk's tip (`4ce0c7b`), but for the shell's, which asserted the area undrawn: there was
no memory table, no admin method, no `me.memory`, no `memory` in the activation, and no
memory scope in the instructions.
