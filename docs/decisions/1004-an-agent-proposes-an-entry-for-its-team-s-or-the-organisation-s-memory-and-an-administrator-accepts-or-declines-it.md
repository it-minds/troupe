---
number: 1004
title: "An agent proposes an entry for its team's or the organisation's memory, and an administrator who may change that level accepts or declines it: remember takes level team and organisation as a proposal kept in memory_proposals and in no document; accepting writes it as an entry with the session and agent as its provenance, declining needs a sentence; the session is told either as one config_note; the setting memory_proposals switches proposals off; and a profile's extends changing tells its running sessions, the memory_changed line saying the chain moved"
gist: "An agent writes above me only as a proposal, in no document until an admin who may change that level accepts it; a decline needs a sentence"
date: 2026-11-16
status: accepted
issue: 55
paths:
  - apps/troupe_core/lib/troupe/tools/remember.ex
  - apps/troupe_core/lib/troupe/plane_memory.ex
  - apps/troupe_plane/lib/troupe/plane/memory/proposal.ex
  - apps/troupe_plane/lib/troupe/plane/memory/proposals.ex
  - apps/troupe_plane/lib/troupe/plane/memory.ex
  - clients/gui/apps/console/src/views/Memory.tsx
---

## A proposal, not a write

**`remember` takes `level: "team"` and `level: "organisation"`**, with `claim` and `topic`
as `me` does (and `team` on a person's machine in several teams). The tool's description
says, only where the host can send one, that a proposal is reviewed and is in nobody's memory
until it is accepted, so the agent does not say it is in effect; its answer says "awaiting
review" and "do not say it is remembered". A profile's memory has no level: it is the
profile's administrator's alone, and a session's profile is not something its agent chose.
The librarian proposes nothing, as it writes no person's memory.

**The plane keeps it in `memory_proposals`** (migration `20261116001004_memory_proposals`):
the level, the team, the topic, the entry (one line, at most 1024 bytes, as an entry of a
person's is), the session, the agent, where the session ran (`pod` or `machine`), the person,
and what became of it. A pending proposal is in no document and reaches no session. A pod
proposes over its control link (`session.memory.propose`); the team is the session's own,
read off its row as its owner is, so a pod proposes only for a session it holds. A person's
machine proposes through its daemon (`me.memory.propose`, as the person); a team is one of
theirs, the one named or their only one, and with several and none named the refusal names
them. Each person has at most twenty pending, so an agent in a loop does not fill a queue.

**Who decides is who may change the level**: a team's admins and the platform admins for a
team's, a platform admin for the organisation's, the same rule `admin.memory.put` keeps.
`admin.memory.proposals` lists the pending ones the caller may decide, oldest first;
`admin.memory.accept` writes the entry at the end of its topic's section (made where there is
none) as the next version, saved by the administrator, audited as `memory.put` with the
proposal's `session` and `agent`, so the blame (Decision 951) names the agent and its session
for the line; `admin.memory.decline` needs a sentence and writes nothing. Each is decided
once: a second decision is `conflict`, naming who decided it and how. A team admin asking
for another team's is told it is not there, as its team is not.

**The session is told** in the plane's words, as one `config_note` (key `memory_proposals`,
`proposal` its id): a pod's at once (`memory.proposal.decided` over the control link), a
machine's with its daemon's next poll, since every `me.memory` answer now carries the
person's own proposals (pending, and decided in the last seven days). The line is written
once whatever hears it twice: the session's log is read for the proposal's id first. A
session not running is told nothing; the person's app shows the decision anyway.

**Audit**: `memory.propose`, `memory.proposal.accept` and `memory.proposal.decline`, each on
the level's subject (`organisation`, `team/<name>`), with the proposal's id, its topic, the
person, the session and the agent, and a decline's reason; never the entry's text, as a
save's row holds none. An erased session's proposals that were not accepted go with it; an
accepted one is the document's, as its version is.

**Off**: the platform setting `memory_proposals` ("Agents may propose memory", a switch, on
by default, under what a new session runs with, Decision 991's label and unit). Off, every
proposal is refused with a sentence the agent relays, naming the setting and offering the
repository's memory or the person's own; what waits stays to be decided, and the console
says proposals are off above it. A profile cannot switch them off for its sessions alone:
that would be a field on every profile's spec, its resource and its form, for a choice no one
has asked to make per profile yet; it is left as #965.

## A profile's `extends` reaching running sessions

Now a save of a profile whose `extends` moved
(`Fleet.put_profile/1`, and a gitops profile followed from its resource) tells the running
sessions of the profile and of every profile that extends it at once, as a save of a
document in the chain does (`Memory.announce/1`). And each profile's document the plane sends
carries `chain`, the profile names along it, the one that extends nothing first: the harness
compares the chain before and after (`Troupe.PlaneMemory.chain_change/2`) and the
`memory_changed` line begins "The profile dev's chain changed: it is base → dev now (it was
dev)", with `chain: {from, to}` on the event. A plane from before it sends no chain, and the
line is as it was. The chain is not part of a stamp: what a session runs under is the
documents.

## Not chosen

- **An agent writing a team's document directly, with an undo.** The levels above a person
  are the organisation's instructions to every session in scope; a word in them that nobody
  with authority over them read first is the thing #55 kept out since slice 1.
- **The proposal as a draft version of the document.** Versions are what sessions read and
  what rollback restores; a pending version would have to be skipped by both, and two
  proposals on one document would conflict with each other before either was read.
- **Telling a machine's session over a new push.** The daemon dials the plane and nothing
  dials the daemon; its poll is the channel it has, and a decision five minutes late is no
  worse than a save five minutes late.
