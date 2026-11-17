---
number: 947
title: "A turn records the memory versions it ran under; the console sees who is behind; a stale pod session re-reads before its next turn: instructions_loaded names each memory document's scope, name, version and hash; a pod's session asks the plane with session.memory.read as each turn begins and is answered with the documents in force where it is behind; a laptop's daemon says what each of its sessions read with its poll of me.memory; admin.memory.get and preview list the running sessions a document reaches with the version each read, admin.memory.nudge tells a pod's session again, the session list marks one behind; the editor rolls back to a version as a new version and sets two versions side by side; and troupe memory --status says where a machine stands"
date: 2026-10-25
status: accepted
issue: 55
paths:
  - apps/troupe_protocol/lib/troupe/protocol/memory.ex
  - apps/troupe_plane/lib/troupe/plane/memory.ex
  - apps/troupe_plane/lib/troupe/plane/memory/read.ex
  - apps/troupe_core/lib/troupe/session/plane_memory.ex
  - apps/troupe_gateway/lib/troupe/gateway/memory.ex
  - apps/troupe_worker/lib/troupe/worker/memory_read.ex
symbols:
  - Troupe.Protocol.Memory.stamp/1
  - Troupe.Plane.Memory.turn/2
  - Troupe.Plane.Memory.machine/2
  - Troupe.Plane.Memory.readers/1
  - Troupe.Plane.Memory.standing/1
  - Troupe.Plane.Memory.nudge/2
  - Troupe.Session.PlaneMemory.before_turn/2
  - Troupe.Session.PlaneMemory.reads/0
  - Troupe.Worker.MemoryRead
  - Troupe.Gateway.Memory.status/0
gist: "Turns name memory versions (instructions_loaded memory); pod asks session.memory.read per turn, re-reads if behind; laptop poll reports; console readers, nudge, rollback"
---

#55, as the maintainer decided it on #765 on 2026-10-25 ("memory, proven read"): sessions
record the memory versions each turn ran under; the console shows who is behind; a stale
pod session re-reads before its next turn; rollback and side-by-side in the editor.
Enforcement otherwise unchanged.

## What a turn ran under

**In the log.** `instructions_loaded` already listed each memory document among its files
with its version and hash. It now carries `memory` as well: each document read, as the plane
names it, `{scope, name, version, hash}` with `scope` `organisation`, `team`, `profile` or
`user` (the instruction listing calls the person's own `person`, Decision 943; here it is
the plane's word, so the stamp a session logs is the one it reports and the plane keeps). The
event is written when what the prompt was read from changed, so each turn runs under the last
one before it, and `memory_changed` says when that moved. `Troupe.Protocol.Memory.stamp/1` is
the one shape, in the protocol app because the plane, the core and the daemon all compare by
it: scope, name, version and hash, never the text.

**What each session's last turn read is kept beside it.** `Troupe.Session.PlaneMemory`, the
holder Decision 929 placed in the session's tree, keeps the stamps of what its root agent's
turn read and when it began (`read/2`, `reads/0`). The root's turn, not each agent's: the
plane's question is what a session runs under, and a subagent takes what the root was given.

## A pod's session asks as its turn begins

The plane knows both the versions in force and, once told, what a session holds; the pod is
the one that knows a turn is starting. A person's input reaches a pod over the session's own
connection, not through the plane, so the plane cannot speak at `input.send`; nor would
`input.send` cover every turn (a loop's iteration, a queued input, a review pushed as
`session.input`). So the turn asks: as the root agent's turn begins, before it takes what it
was given (`take_memory`), `Troupe.Session.PlaneMemory.before_turn/2` calls the check the host
installed. A pod installs `Troupe.Worker.MemoryRead`, which sends `session.memory.read
{session_id, epoch, documents}` over the control link with the stamps the session holds. The
plane (`Memory.turn/2`) compares them with `for_session/3`'s documents, keeps what the turn
reads, and answers `current: true`, or `current: false` with the documents in force; the pod
gives them to the session's holder, the turn takes them at once and says so as
`memory_changed`, as a push would have. What the plane keeps is what the turn runs under: the
reported stamps where current, the versions it sent where behind. A session the pod does not
hold is `not_found`, a stale epoch `conflict`, as `session.memory.put` is.

**A check that cannot answer stops nothing.** Two seconds, then the turn runs on what it
holds and the pod's debug log says why; the next activation carries the documents anyway. A
turn waiting on the plane would make the plane's availability every pod's latency, and the
memory a turn would otherwise miss is at most one save old. One small request a turn, on a
connection already open, is the cost: the control link carries no session content (its own
rule), and stamps are none.

**Not chosen:** acknowledging `session.memory` and re-sending unacknowledged pushes. That
would say what a pod was given, not what a turn ran under, and a session idle for an hour
would be "current" without having read anything; the turn's own question answers both.

## A laptop says so with its poll

The daemon already asks `me.memory` every five minutes and at every link (Decision 929).
Every ask now carries `sessions`: for each session running on the machine that has had a
turn, its id, when the turn began and the stamps. A field on a call it makes anyway was
cheaper than a `me.memory.read` of its own; the cost is that the console's word on a laptop is
up to five minutes old, which it says. The plane (`Memory.machine/2`) keeps at most 64 a call,
for the caller alone, and never over a pod's row or another person's (the upsert is
conditioned on both). Nothing else of a session goes: no title, no workspace, no text. A
laptop's sessions have no plane row, so `memory_reads` is keyed by the session id, not by a
foreign key, and a row nothing has spoken of for a week is pruned at the next machine's call.

## The console sees who is behind

`memory_reads` is one row per session, moved on by its next turn: never a history, since
"who is behind" is a question about now. `admin.memory.get` and `admin.memory.preview` carry
`readers` (`Memory.readers/1`): every running session the document reaches that has had a
turn, by the same scope rule a save announces by (the organisation's: all; a team's: its pod
sessions and its members' machines; a profile's: its and its descendants' pod sessions),
each with where it runs, its owner, profile and team, the version of this document its last
turn ran under and when, and whether that is behind; `behind` counts them. A pod's session
is running while the plane has it active on a pod; a machine's while its daemon named it in
the last fifteen minutes, three polls. A session with no turn yet is not listed: it reads the
version in force at its first. The person's own memory has no readers here: no
administrator's method reads anything of it (Decision 943).

`admin.memory.nudge {scope, name, session_id}` sends one pod's session `session.memory` again,
for one that is behind and that an administrator will not leave to its next turn's question.
A machine's session is not told, as nothing dials the daemon (Decision 929); the answer says
it hears at its next poll. A nudge changes nothing else and is not audited. Who may nudge is
who may change the document. `admin.sessions.list` marks each running pod session `memory:
current` or `behind` (`Memory.standing/1`, the in-force documents computed once per team,
profile and owner in the listing); the Sessions page shows `memory: behind`.

**Rollback** (`admin.memory.rollback {scope, name, to, version}`) is a put of version
`to`'s text as the next version, over `version` as every save is, so the history keeps
every version and a rollback is itself undone the same way. Audited as `memory.put`, with
`rolled_back_to` and `note: "rolled back to v3"` beside the version, size and hash. A
method of its own, not a `rollback` argument on the put, so the put's `text` stays
required.

## `troupe memory --status`

For the person's own debugging, the daemon's `me.memory.status` (`observe`) answers the
versions its copy holds and when it was fetched, asks the plane and keeps the answer as every
answer is, says whether the copy had the versions in force, and lists each session running
here with what its last turn read and whether that is current against the copy now. Signed
out, or with the plane unreachable, it still says what the copy holds and why the plane was
not asked. `troupe memory --status` prints it and exits 0 whenever it could ask the daemon.
Under `troupe memory` rather than `troupe doctor`: it asks the plane, which `doctor`'s
offline checks do not.
