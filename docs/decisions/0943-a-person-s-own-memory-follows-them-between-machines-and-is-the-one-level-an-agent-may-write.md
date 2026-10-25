---
number: 943
title: "Each person has one memory document of their own on the plane, kept by their id, versioned and audited as the organisation's levels are and read by nobody else; every session they run reads it after the organisation's, team's and profile's and before the repository's; they change it with troupe memory, the desktop app's Instructions pane and the console's Mine; and it is the one level an agent may write, by remember with level me adding one entry under the day's heading, through the daemon's me.memory.put on a laptop and session.memory.put on a pod, the organisation's levels staying read-only to agents"
date: 2026-10-25
status: accepted
issue: 55
paths:
  - apps/troupe_protocol/lib/troupe/protocol/memory.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_plane/lib/troupe/plane/memory.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/identity.ex
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - apps/troupe_core/lib/troupe/user_memory.ex
  - apps/troupe_core/lib/troupe/tools/remember.ex
  - apps/troupe_core/lib/troupe/instructions.ex
  - apps/troupe_core/lib/troupe/plane_memory.ex
  - apps/troupe_gateway/lib/troupe/gateway/memory.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_worker/lib/troupe/worker/user_memory.ex
  - clients/tui/lib/troupe/cli/memory.ex
  - clients/tui/lib/troupe/cli.ex
  - clients/gui/packages/client/src/instructions.ts
  - clients/gui/packages/client/src/daemon.ts
  - clients/gui/apps/desktop/src/views/Instructions.tsx
  - clients/gui/apps/console/src/views/Mine.tsx
  - PROTOCOL.md
  - docs/user/memory.md
symbols:
  - Troupe.Plane.Memory.own/1
  - Troupe.Plane.Memory.save_own/4
  - Troupe.Plane.Memory.append_own/3
  - Troupe.UserMemory
  - Troupe.Worker.UserMemory
  - Troupe.CLI.Memory
gist: "One user-level memory per person (by id, nobody else reads it), read after org/team/profile; remember level me only appends an entry; org levels stay read-only to agents"
---

#55's rest, as the maintainer decided it on #765 on 2026-10-25: agents may write to the
**user level only**; the organisation's, a team's and a profile's memory stay read-only to
agents. Decisions 922 and 929 put the organisation's three levels on the plane and named the
person's own as left. This records how it is kept, who reads and writes it, and how an agent
adds to it.

## The document

A fourth scope of `memory_documents`, `user`, with the person's **id** as its owner, so a
re-key (Decision 751) keeps it where it is; a fold into the row SCIM made moves it to that
row with the sessions; removing the person deletes every version in the transaction that
buries them. Everything else is the other levels': one row per version with who saved it, the
8192-byte limit, normalised text, a save over the version edited refused as `conflict`, the
same text again making no version, and `memory.put` in the audit on `user/<subject>` with the
version, size and hash and never the text. An agent's entry's row names the session it came
from.

**Nobody else reads it.** There is no administrator's method for it: `admin.memory.*` refuses
the scope as it did, `admin.memory.list` never lists one, and the console offers no such page.
The person reaches it only as themselves: `me.memory` answers their own after the
organisation's documents, with `user`, the version a save names (there for a document never
saved or cleared); `me.memory.preview` and `me.memory.put` are theirs. A service principal has
none.

## Where it is read

**After the organisation's levels and before the repository's.** Narrowest wins, and the
person's own memory is theirs, but the organisation's instructions come first, as Decision
921 has it; so the order is the organisation's, the team's, the profile's chain, the person's
own, then their `<config>/AGENTS.md` and the repository's files and brief. In the prompt it is
a section of its own, *The person's own memory*, whose preamble says it is the person's, that
an agent may add to it with `remember` and `level: "me"` and change nothing in it, and where
they edit it. Not chosen: inside *Your organisation's memory*, whose preamble tells an agent
it may change none of it.

In the instruction listing (`context.get`, `instructions_loaded`) its scope is **`person`** and
its path `memory:user`: `user` was already the person's own `AGENTS.md` there, and a client
from before this reading `person` as an unknown file is better than one reading the plane's
document as a file on this machine. The change line says *Your memory changed* when it alone
changed.

It reaches every session the person runs: on their machines in the signed `me.memory` copy,
on pods with every activation and every `session.memory`, whose document lists now carry the
owner's own whichever level was saved. A save of it tells the pods of the person's running
sessions; the daemon that saved it asks `me.memory` again at once, so the sessions on that
machine read it at their next turn, and other machines at their next poll.

## Who writes it

**The person**, through `troupe memory` (show, `--edit` in `VISUAL`/`EDITOR`, `--clear`), the
desktop app's Instructions pane (edited in place, the only layer that is, through the daemon,
and not under Local only), and Mine in the console (with the preview the administrators'
pages have; this narrows Decision 942's "the memory their machines read, to read and not to
change" to the organisation's levels). The terminal and the desktop app go through the daemon's `me.memory` and
`me.memory.put`, sent with the daemon's own sign-in, because the daemon is what hands the new
version to the sessions running there.

**An agent**, by `remember` with `level: "me"`, and only by appending: one entry, `claim`
alone, white space folded onto one line, at most 1024 bytes, which the plane puts under a
heading of the day below what is there. The model names no document and no path, as
Decision 649 has it for the brief; the plane writes the text, so no entry can replace a word
the person wrote. The argument is **`level`**, not `scope`: `scope` was already the glob a
repository fact applies to. On a laptop the daemon installs itself as where the entry goes
(`Troupe.UserMemory`) and sends `me.memory.put {append}`; on a pod the worker sends
`session.memory.put {session_id, scope: "user", append}`, and the plane reads whose memory it
is off the session's row, as it reads `kms.assertion`'s subject, refuses any other scope, a
session that pod does not hold, a stale epoch and a deactivated owner. Signed out, or with no
plane, it is refused with a sentence that offers the repository. Past the limit the plane
refuses it and names `troupe memory --edit`. The librarian writes no entry: what it surveys is
the repository's. The organisation's levels have no `level` at all. The tool's description
names `level` only where a host installed somewhere for the entry to go, so a session with no
plane is not told of one it cannot use and the offline bench's tool definitions stay within
their budget; the schema lists it as a bare `enum`.

**The control channel carries the entry.** It carries no session content (the control
connection's own rule), and memory is not that: the documents already go down to a pod with
every activation (Decision 922), and the entry that comes back is one an agent was asked to
keep for its person, theirs from then on, as the text of a `me.memory.put` is. Nothing else
of the session's goes with it.

## Not in this slice

Provenance and history per document beyond the audit row (who or which session wrote each
line, soft delete); a change to a profile's `extends` reaching its sessions at their next
turn; agents proposing changes to a team's memory for review. The daemon has no Local only of
its own: an agent's entry is refused only where the daemon holds no plane token.

## Proof

- `apps/troupe_plane/test/troupe/plane/user_memory_test.exs`: a person's saves versioned,
  conflict-checked, the same text making none, audited on `user/<subject>` without the text; a
  preview writing nothing and refusing past the limit; entries under the day's heading below
  what is there, folded; a full document refusing an entry and naming `troupe memory --edit`;
  a principal refused; no administrator listing, reading or changing it and another person's
  machine and session reading none; a pod's session reading it after the organisation's
  levels, a cleared one none; a re-key and a SCIM fold keeping it, removal deleting it;
  `me.memory` signed, with `user`.
- `apps/troupe_plane/test/troupe/plane/control_test.exs`: `session.memory.put` adding to the
  session owner's, the audit naming the session; every other scope `forbidden`, another pod's
  session `not_found`, a stale epoch `conflict`, nothing written.
- `apps/troupe_plane/test/troupe/plane/bundles_test.exs`: the activation carrying the owner's
  own last and nobody else's; an entry telling the pod of her running session and not his; an
  organisation's save keeping her own in what her session is told.
- `apps/troupe_worker/test/troupe/worker/user_memory_test.exs`: an entry from a pod's session
  over a real control link landing in its owner's document, another session refused.
- `apps/troupe_core/test/troupe/tools/remember_me_test.exs`: an entry through the installed
  host, one entry and nothing in the repository; signed out offering the repository; anchors
  refused, no level for the organisation's; a session's call logged with what it wrote.
- `apps/troupe_core/test/troupe/instructions_prompt_test.exs` and `plane_memory_test.exs`: the
  person's section after the organisation's and before their own `AGENTS.md`, listed as
  `person` with its version; `config --explain` naming it; the change line.
- `apps/troupe_gateway/test/troupe/gateway/plane_memory_test.exs`: `me.memory` and
  `me.memory.put` through the daemon, a running session reading the save at its next turn, a
  stale version said; `remember` with `level: "me"` in one session landing on the plane and a
  second session reading it at its next turn with `memory_changed`; signed out, a sentence.
- `clients/tui/test/troupe/memory_cli_test.exs`: the command line, show, edit, nothing
  changed, a conflict, clear, signed out.
- `clients/gui/apps/console/test/mine.test.tsx`: Mine previewing and saving a person's own
  over the version edited, a conflict said, the organisation's still read-only, no `admin.*`.
  `apps/desktop/test/instructions-view.test.tsx`: the pane listing it as its own layer, edited
  in place, a conflict said; signed out, why. `packages/client/test/instructions.test.ts`.

All of these failed on the chunk's tip (`08f1e008`): there was no `user` scope, no
`me.memory.put`, no `session.memory.put`, no `level` on `remember`, and no person's section.
