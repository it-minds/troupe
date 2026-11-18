---
number: 1012
title: "A worker profile may refuse its sessions' memory proposals with memoryProposals: false, read by the plane at each proposal from a pod and refused in the setting memory_proposals's sentence naming the profile; the field is restrict-only along extends, and a child's own value under a parent's restriction is said in the preview and the effective view"
date: 2026-11-16
status: accepted
issue: 965
supersedes: [1004]
paths:
  - apps/troupe_plane/lib/troupe/plane/memory/proposals.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/extends.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/profile.ex
symbols:
  - Troupe.Plane.Memory.Proposals.propose/5
  - Troupe.Plane.Memory.Proposals.off_reason/1
  - Troupe.Plane.Admin.preview/2
gist: "memoryProposals false refuses a pod session's proposals in the setting's words naming the profile; a parent's false holds, and a child's true is said, not obeyed"
---

Decision 1004 let an agent propose an entry for its team's or the organisation's memory, and
gave the platform one switch, the setting `memory_proposals`. It left a profile's switch as
#965: a review or a trigger profile whose agents should propose nothing had no way to say so
short of switching proposals off for everybody. This replaces that one sentence of 1004; the
rest of it stands.

## The field

`memoryProposals` on a `WorkerProfile`'s spec, an optional boolean with no default of its
own, so no resource changes when the chart is upgraded. `false` refuses every proposal a
session on the profile's pods makes; absent or `true`, the setting decides, as before. It is
a schema addition and nothing more: the operator renders nothing from it (a profile that
says `false` renders what one that does not renders, and no pod is replaced), because the
plane reads it, from the profile's row, at each proposal. `admin.profile.put` refuses any
value but `true` and `false`: a `"false"` saved as text would leave the sessions proposing
while the administrator believed them refused, the reason `repositoryOverridesBundle` is
held to a boolean.

## Refused in the setting's words

`Troupe.Plane.Memory.Proposals.propose/5` takes the session's `:profile` from a pod
(`session.memory.propose` reads it off the session's row, as it reads the team) and refuses,
keeping nothing, where that profile in effect says `false`. The sentence is the setting's,
with what switched proposals off named in the setting's place: "proposals to a team's or the
organisation's memory are switched off for the sessions of the profile <name> (its
memoryProposals is false); nothing was proposed. Remember it for this repository instead, or
in the person's own memory (level me)". The agent relays it, and the same two ways out are
offered whichever switch said no. The setting is checked first, so a plane with proposals
off everywhere names the setting rather than a profile.

A session on a person's machine runs on no profile; only the setting reaches it.

## Restrict-only along `extends`

The field takes the rule `personalTools: forbid` and `repositoryOverridesBundle: false` have
(Decision 908's table): a parent's `false` holds whatever a child says, and a child may still
say `false` where its parent says nothing. Since the row of a profile that extends another is
the profile in effect, the plane's check reads the parent's `false` on the child's row with
no walk of the chain at proposal time.

A child's own `true` under a parent's `false` is kept as written and does nothing, which an
administrator would otherwise learn only from a refused agent. So `Troupe.Plane.Fleet.Extends`
now reports, for every restrict-only field, a value of the child's that a parent's
restriction overrides: "<child> sets memoryProposals to true, and <parent>'s false holds: a
profile cannot undo a restriction of the profile it extends", in the effective view's
`problems`, and `admin.profile.preview` answers the same list as `problems` for the write it
previews (the console lists them among what will happen). Neither refuses the write: the
child's value is a harmless no-op, and refusing it would stop a child from saving anything
while it still carried a value it had before its parent restricted the field.
## Not chosen

- **A per-team or per-grant switch.** A grant only narrows what a profile offers, and nobody
  has asked to narrow this per team; the profile is where a review or trigger's agents are
  defined.
- **Hiding the levels from the `remember` tool on such a profile.** The pod would need the
  field in its activation and the tool's description would change mid-session when the
  profile does; a refusal in words reaches the agent the same way the setting's does.
