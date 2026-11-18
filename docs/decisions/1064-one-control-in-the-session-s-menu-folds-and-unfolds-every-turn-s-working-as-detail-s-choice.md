---
number: 1064
title: "The desktop session's ⋯ menu leads with one control that folds every turn's working (quiet) and unfolds it (everything); it is /detail's per-session choice, so the two never disagree, and a turn opened or shut by hand keeps that until the next change"
date: 2026-11-18
status: accepted
issue: 1117
paths:
  - clients/gui/apps/desktop/src/views/Session.tsx
symbols:
  - useDetail
  - SessionMenu
gist: "⋯ menu's first item: Fold / Unfold every turn's working, aria-pressed and a line naming the level in force; fold = /detail quiet, unfold = /detail everything, the same per-session, in-memory choice; a hand-opened turn stays until the level changes"
---

Narrows Decision 877's "`/detail` sets it for a session". A person reading a long session
shut turns one strip at a time or had to know the command. The session's ⋯ menu now leads
with one control: "Unfold every turn's working" at quiet, "Fold every turn's working" at
tools or everything, `aria-pressed` while anything is open, and under it a line that names
the level in force and what it shows ("Now tools: each turn's tool steps are open, its
thinking shut").

**It is `/detail`'s choice, not a second one.** Folding chooses quiet for the session and
unfolding chooses everything, through the store `useDetail` keeps by daemon connection and
session for as long as the app runs; nothing is written to the log, a file or a setting.
`/detail` moves the control and the control moves what `/detail` says, the live turn
drawn at the same level as the rest. Unfolding goes to everything, not back to the
`transcript.detail` setting: that setting is quiet unless someone changed it, and
unfolding to it would open nothing, and tools leaves the thinking shut. Everything is
also what a click on one turn's strip opens that turn to.

**A turn opened by hand** (its strip) stays as the hand left it until the level changes,
which every use of the control does; then every turn is drawn as the level says, as
Decision 877 has it for `/detail`.

**Where.** The session head is one line by Decision 986 (back, mask, title, tags, who is
here, status, Invite, ⋯), with no room for a view-wide control that is not one of those;
⋯ already holds the view's other show-and-hide choices (backstage, scratchpad). One
place, not both.

Not chosen: a button in the head (breaks the one-line head on a phone); a three-way
control for quiet, tools and everything (the palette has it, and the person asking wants
the replies or the working, not a ladder); a new setting (the choice is this view's for
this run, as `/detail`'s is). Undone, the transcript folds only turn by turn or through a
command a person has to know, or a second store disagrees with `/detail` about what is
open.
