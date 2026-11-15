---
number: 995
title: "The console answers a pod session's approval as the desktop does: Allow once, the session-wide answer in the shared calls' words (callScopedLabel), Deny, and Always allow only where the session's server names approval_allow_always, which a pod does not; a publication on a pod also offers letting it publish unasked for the session; a relayed laptop session keeps Allow once and Deny with the line saying why"
date: 2026-11-15
status: accepted
issue: 928
supersedes: [942]
paths:
  - clients/gui/apps/console/src/views/Remote.tsx
  - clients/gui/apps/console/test/invited.test.tsx
  - clients/gui/packages/client/src/calls.ts
symbols:
  - RemoteSession
  - callScopedLabel
gist: "Console pod approvals: once, for this session, deny, always only where named; relayed laptop approvals stay once and deny with the line"
---

Issue #928's fourth item, from #904. A pod session opened from the console (one somebody
invited the person into to steer, Decision 949) drew the relayed laptop's answers: Allow
once and Deny. The desktop app offers the same session three: Allow once, the
session-wide answer and Deny. Decisions 921 and 942 say the console steers what is the
person's; what it may answer was decided only for a laptop's session (921, 945).

This amends the console's part of Decision 942, which drew one approval panel for both.

**A pod session the person may steer** is answered as the desktop answers it, in the
words of the shared `calls.ts`: *Allow once*; the session-wide answer, `allow_session`,
labelled by `callScopedLabel` (*Allow every command for this session*, *Allow every file
change for this session*, *Allow `tool` for this session*); and *Deny*. A pod's rules are
its worker profile's, so loosening one for the rest of the session is the same act it is
at the desktop, recorded the same way, with the person as the one who answered.

**Always allow only where the server names it.** The button is drawn where the session's
own `initialize` names `approval_allow_always`, as the desktop draws it. A pod does not
name it: its rules are its worker profile's, which an administrator sets, and a lasting
rule of one person's has no place there (Decision 989). So on today's pods the console
draws no Always allow, and not a disabled one either (DESIGN.md §8).

**A publication on a pod** also offers *Allow, and let it publish unasked for this
session* where the agent proposed an audience, as the desktop does, with the audience
chosen in the panel.

**A laptop's session through the plane is unchanged** (Decision 945): Allow once and Deny,
and the line *From another device a call is allowed or denied once: allowing it for the
rest of the session is done at the laptop.* The relay refuses `allow_session` and
`allow_always` from another device, and a button that is refused once pressed is not
drawn.

**The record** of an answered approval says *Allowed for this session* and *Always
allowed* as the desktop's does.

**Not chosen: the console saying it cannot answer for the session.** The pod would take the
answer, and the person may steer the session; saying "use the desktop" would send them to
another app for a button the console can draw.

## Proof

`clients/gui/apps/console/test/invited.test.tsx`: a pod session invited to steer draws
*Allow once*, *Allow every command for this session* and *Deny*, no Always allow and not
the laptop's line, and the session-wide answer reaches the pod as `allow_session` and is
recorded *Allowed for this session by you*. It failed on the chunk's tip, which drew two
answers. `remote.test.tsx`'s relayed approval still offers no session-wide answer and says
why.
