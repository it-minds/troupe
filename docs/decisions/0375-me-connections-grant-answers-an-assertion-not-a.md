---
number: 375
title: "`me.connections.grant` answers an assertion, not a token"
date: 2026-09-15
status: accepted
paths:
  - apps/troupe_plane/test/troupe/plane/person_credentials_test.exs
gist: "`me.connections.grant` answers an assertion, not a token"
---

A short-lived key
manager token scoped to the caller's own slot would be a token the plane minted, a
token the plane minted is a token the plane *held*, and a plane that held one could
have read the slot. So it answers the assertion instead — a signed statement of who
the caller is, which the plane is entitled to make because it is the thing that
authenticated them — and the client exchanges that with the key manager itself.

The same mechanism a pod uses, which is the argument for it: there is one way to
become a person at the key manager, and the plane is on neither side of it.
