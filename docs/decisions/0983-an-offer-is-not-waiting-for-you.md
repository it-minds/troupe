---
number: 983
title: An offer at a session's start (onboarding, the brief, your servers for a pod) is not work waiting for a person; its panel wears none of the reserved colour and nothing counts it as waiting
date: 2026-11-15
status: accepted
issue: 898
supersedes: [835]
paths:
  - clients/gui/apps/desktop/src/views/Onboard.tsx
  - clients/gui/apps/desktop/src/views/Offer.tsx
  - clients/gui/apps/desktop/src/styles.css
  - clients/gui/apps/desktop/test/start-onboarding.test.tsx
gist: "An offer blocks nothing: no Waiting for you pill, no pink edge; the head stays Idle and the rail's count leaves it out. Reserved colour is for approvals and questions"
---

Issue #898. The onboarding panel drew `<Pill status="waiting" />`, "Waiting for you" in
the reserved colour, on the approval panel's pink edge and footlight. The session's head
said Idle at the same moment, the list row said Idle and the rail's "Waiting for you"
count left it out, because `needsYou` (`@troupe/client`'s `transcript.ts`) counts open
approvals and questions and the root agent's own `waiting`, and nothing else. Two answers
on one screen. This amends Decision 835's desktop flow in that one place (its
`supersedes` is that part): the questions still sit where the approval panel sits, in
835's order, with its default first and filled.

- **An offer is not a wait.** The agent carries on whatever the person answers about
  onboarding, the brief or their servers for a pod session; nothing has stopped for them.
  DESIGN.md §12 keeps the reserved colour for "waiting for you", meaning work has stopped
  and a person must decide, and §6 has the approval as the one thing in the footlight.
  Counting an offer as waiting would light every new session in a repository with other
  tools' files pink, in the head, the list and the rail, until the person answered a
  question they may not care about. So the other way round: the counts stay as they are,
  and the panel stops claiming the state.
- **What the panel wears.** `.approval.offer`: the machine's quiet cyan for the heavy top
  edge, the strong hairline for the rest, the one raise for its shadow instead of the
  footlight, the mask in cyan, and the default answer filled in the cyan every other
  screen's one filled button has. No pill: the heading says what it is ("Onboard 4 files
  from Claude Code and Cursor into Troupe's own?"), and a status pill that is not a status
  would be the word without the state. It keeps the panel's layout, its sticky place and
  its scrolling body, so it still sits where a person looks.
- **Your servers for a pod** (`Offer.tsx`, Decision 748) are an offer in the same sense:
  the session runs without them until the person answers, so the same class and no pill.
  The question a private session asks before it is offered for steering is a dialog the
  person opened and stays in the reserved colour; it is not touched here.
- **Not chosen.** Counting an offer in `needsYou`, so head, list and rail all said
  waiting: one answer everywhere, but the wrong one, for the reason above. A quiet "Offer"
  pill in the idle grey: a pill reads as a session's state, and an offer is not one.

**Proof.** `clients/gui/apps/desktop/test/start-onboarding.test.tsx`, "is an offer, not a
wait": the onboarding panel has the `offer` class and no `.pill.waiting`, says no
"Waiting for you", the head shows Idle and no waiting pill, and the rail's "Waiting for
you" carries no count. It failed before the change on the panel's waiting pill.
