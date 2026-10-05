---
number: 112
title: A collaborator's input is billed to the owner's team budget
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_plane
gist: A collaborator's input is billed to the owner's team budget
---

The budget belongs
to the session and a session has one owner, so `user` and `metadata.troupe_owner` on
every gateway request name the owner rather than whoever is typing. Recorded here
because it is a policy choice with a plausible alternative — billing the speaker —
and the alternative would make a session's cost depend on who happened to answer.
