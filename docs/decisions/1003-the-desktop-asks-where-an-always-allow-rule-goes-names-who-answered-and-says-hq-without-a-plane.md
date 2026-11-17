---
number: 1003
title: "The desktop app asks where an Always allow rule goes, this workspace (the default) or everywhere, once per rule; an answered question names who answered where two or more people steer; a row a client types with other arguments carries that client's `usages` and `examples`, so `/hq` names no plane there; the start screen carries the brand once, the rail's; a session on this computer is owned by the signed-in person's name"
date: 2026-11-16
status: accepted
issue: 956
supersedes: []
paths:
  - clients/gui/apps/desktop/src/views/Approval.tsx
  - clients/gui/apps/desktop/src/views/Question.tsx
  - clients/gui/apps/desktop/src/views/Session.tsx
  - clients/gui/apps/desktop/src/views/StartSession.tsx
symbols:
  - severalSteer
  - Troupe.Commands.for_client/2
gist: "Always allow asks This workspace (default) / Everywhere; 'answered by <name>' with 2+ steerers; usages/examples maps (/hq takes no plane on the desktop); brand once (the rail's); local session's Owner is the signed-in name"
---

**Where an Always allow rule goes.** Decision 989 had the desktop send `scope:
"everywhere"` and never ask, although the daemon takes `workspace` too. Now the approval's
Always allow opens one line under the row, "Always allow <tool> where?", with two buttons,
**This workspace** (focused, the default) and **Everywhere**; nothing is sent until one is
pressed, and pressing Always allow again closes the line. The default is the workspace's
`.troupe/config.local.yaml`, the narrower of the two and the person's own file, never the
repository's; everywhere is their `config.yaml`. A workspace not trusted is refused by the
daemon, and the card shows its sentence, which says how to trust it or to allow it
everywhere. Not chosen: a menu that opens over the conversation (DESIGN.md §6: an approval
never blocks reading), and a setting for the default (one more thing to find for a choice
made once per rule). This amends 989's "the desktop sends `scope: \"everywhere\"`".

**Who answered.** `question_answered` carries its actor's name since Decision 992; the
client folds it into the question's entry as `answeredBy` and `answeredByName`. Where two or
more people steer the session (`severalSteer`: the reader, everyone its presence has heard
of, and whoever wrote a message or answered an approval or a question), the record reads
"Asked: … — answered by Bob Example: main", the reader's own "answered by you". A session
one person steers reads as before: naming the only person there says nothing. The harness's
own word on its budget and failure questions names nobody, and none is drawn.

**A client's own usage.** Decision 984 chose no `usages` map, and 996 left `/hq`'s usage
and example naming a plane URL on the desktop, which is signed in to one plane and takes
no address. A row now also carries `usages` and `examples`, maps from a client's name to
its own usage and example (`null`, none), chosen as `summaries` and `details` are: `/hq`
has `{"desktop": "/hq"}` and `{"desktop": null}`. A client's own usage keeps only the
`args` it names, so the palette's row and its detail pane read the same strings. An
older harness sends neither map, and each client shows what it did.

**The brand once.** The start screen drew its own head (the mask and "troupe") under the
rail's lockup, so the name stood twice, one above the other. DESIGN.md §0 gives the brand to
the rail's lockup, which opens the launcher, and to the phone's top bar (Decision 987); the
start screen's head is removed, not hidden (§8), and the screen opens on its hero.

**The owner of a session on this computer.** The backstage's Owner fact said "you" for a
session on this computer, where the daemon's list carries no `owner_name`. Where the person
is signed in to a plane it now says their name as the plane's `me` gives it (Decision
992's "a name that is only the subject is no name"), and "you" while nobody is signed in,
when this computer's user is the only name there is. A team session's owner is as before.
