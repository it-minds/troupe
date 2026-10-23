---
number: 929
title: "A save of an organisation's, a team's or a profile's memory reaches the sessions already running in its scope at their next turn, on a pod because the plane tells the pod and on a laptop through the daemon's signed poll of me.memory every five minutes, with a line saying what changed and to which version; a child profile reads its chain's memory, the one that extends nothing first; a deleted profile's memory is deleted with it; the desktop app lists every instruction layer; troupe config pull fetches memory; and signing out drops memory.json"
date: 2026-10-23
status: accepted
issue: 55
paths:
  - apps/troupe_core/lib/troupe/session/plane_memory.ex
  - apps/troupe_core/lib/troupe/session.ex
  - apps/troupe_core/lib/troupe/plane_memory.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_gateway/lib/troupe/gateway/memory.ex
  - apps/troupe_gateway/lib/troupe/gateway/daemon.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_worker/lib/troupe/worker/plane/commands.ex
  - apps/troupe_plane/lib/troupe/plane/memory.ex
  - apps/troupe_plane/lib/troupe/plane/fleet.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/admin/api.ex
  - clients/tui/lib/troupe/cli/model_config.ex
  - clients/tui/lib/troupe/client/remote.ex
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/gui/packages/client/src/instructions.ts
  - clients/gui/packages/client/src/session.ts
  - clients/gui/packages/client/src/transcript.ts
  - clients/gui/packages/client/src/admin.ts
  - clients/gui/apps/desktop/src/views/Instructions.tsx
  - clients/gui/apps/desktop/src/views/Session.tsx
  - clients/gui/apps/console/src/views/Memory.tsx
  - PROTOCOL.md
symbols:
  - Troupe.Session.PlaneMemory
  - Troupe.Gateway.Memory
  - Troupe.PlaneMemory.changes/2
  - Troupe.Plane.Memory.announce/1
  - Troupe.Plane.Memory.chain/1
  - Troupe.Plane.Memory.forget/1
gist: "A memory save reaches running sessions next turn (pod push, laptop 5-min signed poll) as memory_changed; child reads its chain's; deleted profile's goes"
---

#55 slice 2. Decision 922 delivered the organisation's, a team's and a worker profile's
memory documents to every session in their scope, read once as the session started, and
named what it left: a running session not hearing of a save, `troupe config pull` not
fetching memory, a child profile not reading its parent's, a deleted profile's memory
staying with its name, no instructions view in the desktop app, no `config.changed` for a
refreshed copy, and `memory.json` kept after sign-out. This records how each is closed.

## A save reaches a running session at its next turn

**One holder per session.** `Troupe.Session.PlaneMemory` is a small process in the session's
tree, under the log and above the agent, as `Session.ClientTools` is, so what it holds
outlives an agent's restart. Its registry entry carries the documents the session was last
given; `put/2` replaces them, `given/1` reads them without asking the process. Nothing else
of the session's configuration moves: memory is the one part a save on the plane changes
while the session runs.

**Taken as a turn begins, never during one.** Each agent compares the documents it read
with what the session was given as its turn begins (`take_memory`, before the instruction
files are read), by scope, name, version and hash. Where they differ it takes the new ones
into its configuration, writes `memory_changed` with each change's versions from and to
(`Troupe.PlaneMemory.changes/2`) and the sentence a client shows (`The organisation's memory
changed: the team design's memory is now version 6 (it was 5). Read from this turn on.`), and
the turn's instructions are read with them. So a turn's system prompt is the same on every
call of it (Decision 798's hold), and the same versions given again say nothing. A
subagent takes them at its own next turn; one started after has them from its parent's
configuration, or takes them at its first turn where its parent had not yet.

**What the session explains moves with it.** `Troupe.Session.resolved/1` lays the given
documents over the layers the session started with, so `config.get` naming the session,
`troupe config --explain --session` and `context.get` name the versions its next turn reads.
That narrows Decision 918's "what it started with" for memory alone, and is why Decision
922's objection to reading the copy at every turn (a running session's instructions moving
without `config --explain` saying so) no longer holds: the move is given, logged and
explained, not read from a file behind the session's back.

**On a pod, the plane tells the pod.** A save (`admin.memory.put` that makes a version) calls
`Troupe.Plane.Memory.announce/1`: every active team session with a pod in the document's
scope (the organisation's: all; a team's: that team's; a profile's: that profile's and every
profile that extends it, `Extends.descendants/1`) is sent `session.memory`, a notification
to its pod with the session's id, its epoch and every document the session now reads
(`for_session/2`). A notification, as a bundle's announcement is: a save never waits on the
slowest pod, and a pod that missed it has the documents with the session's next activation,
which carries them anyway. The worker takes it only for a session up there at the plane's
epoch (`running_at`, as `session.input`), and refuses one it is not running. A
`session.activate` for a session already up gives it the activation's documents the same
way, so a re-activation is not a way for them to go stale.

**On a laptop, a signed poll.** The daemon dials the plane and nothing dials the daemon, so a
push would need a standing connection the daemon has only while a session is offered
(Decision 921). Instead `Troupe.Gateway.Memory` asks `me.memory` every five minutes while
the daemon holds a plane token, besides at every `identity.link` that brings one (as
before) and when a client hands it an answer (`config.memory`). The answer is checked
against the key this machine pinned for the plane and kept as Decision 922 keeps it; a copy
whose documents changed is given to every session running on the daemon, then announced as
`config.changed` with scope `memory` and the changed documents as its keys, in that order, so a
client that heard it and sends a turn finds the session already holds them. A copy that
changed nothing says nothing. Five minutes: a save is an administrator's edit, rare and not
urgent to the second, and one call of a few kilobytes per signed-in machine every five
minutes costs the plane little. Not chosen: riding the relay connection, which exists only
while a session is offered and would make memory depend on steering.

## `troupe config pull` fetches memory

`troupe config pull` asks `me.memory` beside `me.client_defaults` and hands the answer,
signature and all, to the daemon's new `config.memory`, which keeps it through the same
writer. The command says which documents this machine now reads, each with its version, and
that the sessions running here read it from their next turn when one changed. A plane from
before memory gives none, and the pull is not a failure for it.

## A child profile reads its chain's memory

As a profile's rules and bundle are composed from its chain (Decisions 908, 910 and 913),
a session reads the memory of every profile in its chain, **the one that extends nothing
first and its own last** (`Memory.chain/1`, from `Extends.chain/1`), after the
organisation's and its team's. Nearer comes later and wins, as everywhere else in the
instructions. Each is named as its own profile's (`memory:profile/<name>`), so the
provenance says which profile wrote what. A chain that cannot be read (a profile in it gone)
is the profile alone, as its rules are then. A save of a parent's document reaches the
running sessions of every profile below it. The console's profile page shows, above the
profile's own editor, each document it inherits, with the profile it is from, the version
in force, who saved it and when, and where it is changed (`admin.memory.get`'s `inherited`).

## A deleted profile's memory goes with it

`Fleet.delete_profile/1`, the one place a profile row is deleted (an administrator's
`profile.delete`, or a GitOps profile gone from the cluster), deletes the profile's memory
documents, **every version**, in the same transaction (`Memory.forget/1`), so a profile made
again under the name starts with none. **The text is not kept for the audit**: the audit
never held it (Decision 922's `memory.put` rows name the version, size and hash, and who
and when), and those rows stay, so the trail still says who saved what version of the
deleted profile's memory and when; what the document said goes with the profile. Keeping
the versions under the name was what made a new profile inherit an old one's words; keeping
them under some other key would be a second store nobody reads. A team's needs nothing: its
documents are keyed by the team's id, which a team made again does not share.

## The desktop app's instructions view

A session's backstage has an **Instructions** pane: every layer its next prompt is read
from, in order (the organisation's memory, a team's, each profile's of its chain, the
person's own `AGENTS.md`, the repository's files and its brief), each with where it came
from and its version: a memory document's version and the plane's URL with when this
machine fetched it, or the activation on a pod; a file's path and the start of its hash. A
file found and not read stays listed, muted, saying why. Shown, never edited. It is the
session's `context.get` (`SessionView.context()`, laid out by `instructionLayers`), which a
pod answers over the session's own connection, and it reads again when a `memory_changed`
arrives and when this computer's settings change. `context.get` now lists the documents the
session's next turn reads (on a pod, the activation's, which no file on the pod holds; it
listed none there before) and says where they came from (`memory_from`). The transcript
shows `memory_changed` as the harness's sentence, in the desktop app and the TUI.

## `memory.json` is dropped on sign-out

`identity.sign_out` for the plane the copy came from, and `identity.unlink`, delete
`memory.json` whether or not the daemon held a token (one restarted since the sign-in holds
none), give the sessions running here an empty list, which they read from their next turn,
and announce it. The organisation's words are for its signed-in members; a machine whose
person signed out is no longer one. **The key pinned for the plane stays**: it is trust in the
plane, not the organisation's content, and the next sign-in is checked against it.
`organisation.json` is left as it is: it holds defaults and limits, not words for agents,
and dropping it is a different question.

## Not in this slice

A shared facts store, librarian-written briefs and user-level memory on the plane (the
slot's out of scope). A profile whose `extends` changes reaches its running sessions' memory
at their next activation, not their next turn: only a save announces. `PROTOCOL.md` still does
not document the plane-to-pod pushes (`session.activate`, `session.memory`) as a section of
their own.

## Proof

- `apps/troupe_core/test/troupe/plane_memory_refresh_test.exs`: a session started with the
  organisation's version 1 given version 2 and a team's: nothing until its next turn, then
  the new text in the prompt and the old gone, one `memory_changed` with the versions from
  and to and the sentence, `explain_session` naming version 2 and the team's; the same
  versions again saying nothing; an empty list taking them away, said; a session not
  running refused.
- `apps/troupe_worker/test/troupe/worker/plane_memory_test.exs`: `session.memory` to a
  session up on the pod read at its next turn, the change logged, `explain_session`
  following; refused at a stale epoch and for a session not up there.
- `apps/troupe_gateway/test/troupe/gateway/plane_memory_test.exs`: a save on a signing fake
  plane reaching a session running on the daemon through the poll, `config.changed` with
  scope `memory`, the next turn reading it, `context.get` naming version 3; `config.memory`
  keeping an answer, saying what changed, announcing it, the session's next turn reading it,
  the same answer again changing nothing; sign-out of another plane keeping the copy, of the
  copy's plane dropping it, keeping the pinned key and taking the documents from the
  session's next turn; `context.get` naming a session's given documents, not the copy.
- `apps/troupe_plane/test/troupe/plane/memory_test.exs`: a three-profile chain read
  organisation, base, standard, dev, `admin.memory.get` of the child listing the two it
  inherits with their versions and who saved them; a deleted profile made again under its
  name with no document and no versions, and the audit's two saves still there without the
  text.
- `apps/troupe_plane/test/troupe/plane/bundles_test.exs`: a save telling the pod holding a
  running session `session.memory` with its epoch and what it now reads; another team's save
  telling it nothing; a parent profile's save reaching a child profile's session, the
  parent's document before the child's.
- `clients/tui/test/troupe/model_config_test.exs`: `config pull`'s memory handed to
  `config.memory` as the plane signed it, and what is kept said; a refusal said, exit 1.
  `remote_translate_test.exs`: `memory_changed` drawn as the harness's sentence.
- `clients/gui/packages/client/test/instructions.test.ts`: the layers in order with their
  source and version, a file not read listed and why, a pod's memory named as the
  activation's. `transcript.test.ts`: `memory_changed` as a system line.
- `clients/gui/apps/desktop/test/instructions-view.test.tsx`: a local session's pane listing
  organisation, team, the person's own and the repository's files with their sources and
  versions, nothing editable, and reading again when `memory_changed` arrives; a team
  session's pane listing what its pod reads, the activation's memory first.
- `clients/gui/apps/console/test/memory.test.tsx`: a profile's page showing what it inherits
  from the profile it extends and where it is changed; the preview's new sentences.

All of these failed on the chunk's tip (`db62353`): there was no holder, no
`session.memory`, no poll, no `config.memory`, no chain in `for_session/2`, no deletion of a
profile's documents, no `inherited`, no instructions pane, and `context.get` on a session
given its documents listed the machine's copy.
