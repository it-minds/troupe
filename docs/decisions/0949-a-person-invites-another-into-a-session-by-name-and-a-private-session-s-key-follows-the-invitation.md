---
number: 949
title: "A person invites another into a session by name, to observe or control: a pod session's invitation is its grant made visible, a private session's key goes from its owner's daemon into the invitee's own slot at the key manager, which the plane holds the path of and cannot read, taking one back re-keys the session forward, and everybody present is named"
date: 2026-10-25
status: accepted
issue: 765
paths:
  - apps/troupe_plane/lib/troupe/plane/invites.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/erasure.ex
  - apps/troupe_plane/lib/troupe/plane/remote/watch.ex
  - apps/troupe_plane/lib/troupe/plane/sessions/session.ex
  - apps/troupe_plane/priv/repo/migrations/20261025000949_session_invites.exs
  - apps/troupe_plane/test/troupe/plane/invites_test.exs
  - apps/troupe_protocol/lib/troupe/kms.ex
  - apps/troupe_protocol/lib/troupe/kms/open_bao.ex
  - apps/troupe_protocol/lib/troupe/kms/policy.ex
  - apps/troupe_protocol/lib/troupe/sessions/cipher.ex
  - apps/troupe_protocol/lib/troupe/sessions/context.ex
  - apps/troupe_protocol/lib/troupe/sessions/sealer.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_worker/lib/troupe/worker/plane/commands.ex
  - apps/troupe_gateway/lib/troupe/gateway/invites.ex
  - apps/troupe_gateway/lib/troupe/gateway/private.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/test/troupe/gateway/invites_test.exs
  - apps/troupe_core/lib/troupe/commands.ex
  - clients/tui/lib/troupe/client/invites.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/client/remote.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/gui/packages/client/src/invites.ts
  - clients/gui/packages/client/src/fleet.ts
  - clients/gui/packages/client/src/remote.ts
  - clients/gui/apps/desktop/src/views/Invites.tsx
  - clients/gui/apps/console/src/views/Invited.tsx
  - clients/gui/apps/console/src/views/Remote.tsx
  - docs/user/sessions-shared.md
  - docs/admin/roles-and-permissions.md
  - PROTOCOL.md
symbols:
  - Troupe.Plane.Invites
  - Troupe.Gateway.Invites
  - Troupe.KMS.invited_slot/4
  - Troupe.KMS.generation/2
  - Troupe.Sessions.Sealer.rekey/4
gist: "Invite = grant made visible; a private session's key goes into the invitee's own slot from its owner's daemon, the plane holding paths it cannot read; revoke re-keys forward"
---

#765, the maintainer's call of 2026-10-25: "by name, observe or control; a pod session's
invite is the grant made visible; a private session's key is wrapped into the invitee's own
OpenBao slot; revoke re-keys forward."

## A pod session

**The invitation is the grant made visible.** `session.invite {session_id, subject, role}`
by the owner or an admin of the session's team writes the ACL row `session.grant` writes,
`observe` a viewer and `control` a collaborator, and a row in `session_invites` of who
invited whom and when, which the invitee's list and the session's head read. The pod is
pushed `acl.changed`, so a connection already open meets it at its next command, and
`invite.changed`, which gives the log `session_invited` (best effort, as `share.changed`:
a dormant session has no tree, and the row is the record). `session.uninvite` removes both,
pushes `role: null`, which the pod's mirror holds as refused, and `session_uninvited`. Both
are audited.

**Who may be invited.** A person the session's profile covers: a member of a team granted
the profile, whose rules they would act under. Anyone else is `forbidden` with `not on this
profile's teams` and the profile. A platform admin may be invited by anybody. A service
principal never: it has nobody to tell and its sessions are a team's. `people.search`,
prefix on the display name, email or subject, offers only people who share a team with the
caller and, given a session they may invite into, those its profile covers, at most 25.

**Told over the watch.** `invites.changed {invites}`, the whole list, on the watch socket
Decision 942 opened (`initialize` carries `invites` and `capabilities.invites_changed`), each
time an invitation to that person changes, and `invites.list` over `/rpc` for a plane from
before or a watch that is down. The console's Mine has *Invited to you*, and opens a pod
session from it with `session.open` (read to follow it, activate to steer it) on the same
attachment its laptop sessions use; the desktop app marks the plane's row with who invited
the person. A view open under an invitation that is no longer listed closes with a sentence.

**Everybody present is named.** `session.invites` to anybody who may see the session or is
invited into it; the desktop head says *Shared with Bea (follows), Cy (steers)*, and its
owner's head has *Invite*, a picker and *Remove*; the terminal's `/invite` alone says the same.

## A private session

**The key follows the invitation into the invitee's own slot, not a wrapped copy on the
plane.** The brief allowed a transit rewrap or a wrapped-key row. Neither is open to the
plane without the raw key: transit rewraps to a newer version of the same key, never to
another, and the plane may read no key. So the owner's daemon, the one holder of the key,
hands it over: it asks the plane where the invitee's slot is (`session.invite_slot`, which
refuses whom `session.invite` would, before anything is put anywhere), signs in at the key
manager as the owner, and puts each generation of the key at
`troupe/people/<invitee>/invited/<session>/k<n>-<random>` with `create` and nothing else;
then `session.invite` names those paths (`keys`), one per generation, or is refused. The
person policy gains exactly that rule (`create` on `people/+/invited/*`), and OpenBao prefers
the invitee's own rule for their own subtree, since its first wildcard comes later, so they
read it and nobody else can. A per-person transit key was tried first: a transit key name may
not hold `@` or `|`, which people's names do, and a templated policy cannot hash.

**What the plane can and cannot read.** It holds the paths, and with the new
`troupe-plane-invites` grant may `delete` their metadata, which destroys every version, and
nothing on the data path: it cannot read the session's key, a copy of it, or a byte of the
log, which stays sealed under keys only the owner and the invitees hold. The owner cannot
read back what it put in another's slot nor overwrite it (proven against OpenBao), a person
not invited cannot read the slot, and an invitee reads only their own. Invitees read the
sealed copy through `session.keys` (an assertion for their own name and the paths) and
`session.presign`/`session.objects` for `get` and `head` only.

**The invitee reads it on their own machine, not in the console.** The brief had the console
render it. A page the plane serves could only decrypt it with code the plane serves, which
would make "the plane cannot read it" depend on the plane not changing that code. So the
daemon reads it (`session.read_sealed`), the desktop app shows it as *Shared with you*, and
the console lists it with where to read it.

**Followed, not steered.** This departs from the brief, which had a `control` invitee steer
it "when the owner offers the session". Decision 921 never offers a private session, and the
relay carries what an offered session says past the plane in the clear; offering one to its
invitees would end the property this decision is for. So a private session's invitation is
`observe`, and `control` is refused saying why; lifting 921 for invitees is the maintainer's
call, not this one's.

**Revoking re-keys forward.** `session.uninvite` destroys the person's copies and marks the
row `rekey_due`; the owner's daemon seals what is pending under the key it holds, makes the
next generation at `<session>.k<n>` (a path of its own, since KV keeps a bounded number of
versions and the oldest going would lose the start of the log), seals everything after under
it (`Sealer.rekey/4`), puts it in the slot of each person still invited, and reports it
(`session.rekeyed`, refused where a person still invited has no key in it); then the log says
`session_uninvited`. Done at once when the daemon can; otherwise at the next link that carries
the session on, before anything more is sealed. A segment is under one generation, and a
reader with several tries each: AES-GCM verifies under one only, so the format is unchanged.
**What was read stays read**: the plane stops serving them and the slot copy goes, but they may
have kept what they read and its key, and the docs say so.

**The daemon's own log decides whom a new key goes to.** It puts a new key only in the slots
of people the plane lists and the session's own `session_invited` events name; a plane that
listed somebody this machine never invited gets no key for them, and its refusal of the rest
leaves the session `rekey_due`.

**Erasure destroys every copy.** The invitees' copies first, then every generation and one
past the last reported; the session is `erasure_pending` until all are gone (Decision 756's
rule, extended), and a plane without the invites grant leaves such an erasure pending.

## Not in this

- A copy put in a slot for an invitation the plane then refuses stays in the invitee's slot:
  the slot check before makes it a race, and nothing but the plane may delete there.
- The terminal reads no shared private session; the desktop app does. HQ does not list
  invitations.
- A dormant pod session gets no log line for an invitation until it is told again.

## Proof

- `apps/troupe_plane/test/troupe/plane/invites_test.exs` (12), with a fake pod over the real
  control channel and the development OpenBao with a plane credential of the plane's policies
  and nothing more: an invitation by email is the ACL row, pushed and logged, listed to the
  invitee and named in the head; a non-member refused and nothing written; a platform admin
  invited; only the owner or team admin invites; taking it back ends the grant and tells the
  watch; the picker; the watch pushes `invites.changed` to the invitee alone. A private
  session's key in the invitee's slot: the plane's credential cannot read it, nor the owner's,
  nor an uninvited person's, and the invitee's can; invited only with every generation, in the
  invitee's slot, and observe only; revoking destroys the copy, refuses the removed person
  everything, and re-keys with the remaining invitee holding both generations; erasure
  destroys every generation and copy, and stays pending without the invites grant. All twelve
  failed on the tip.
- `apps/troupe_gateway/test/troupe/gateway/invites_test.exs` (5), real MinIO and OpenBao:
  every generation put in the invitee's slot and the log line; revoking seals what follows
  under a second key the removed person was not given (the second segment does not open under
  the first key); an invitee's daemon reads the whole log with its keys; a plane-listed person
  the log never invited is given no key; a link re-keys first where it was taken back
  elsewhere.
- `clients/gui`: the desktop app's `invites.test.tsx` (5) and the console's `invited.test.tsx`
  (2) against the fake plane and daemon; `fleet.test.ts` for the rows. The terminal's
  `invite_command_test.exs`.
