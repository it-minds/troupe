---
number: 497
title: The plane holds the prompt while a session waits
date: 2026-09-16
status: accepted
paths:
  - apps/troupe_plane
gist: The plane holds the prompt while a session waits
---

It is the only piece of
session content the plane ever holds, it is held for seconds, and it is cleared the
moment the session is placed. The alternative is a session that starts and then
sits there, which is what dropping it would produce for exactly the unattended runs
that cannot ask again.
