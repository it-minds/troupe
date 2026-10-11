---
number: 859
title: "On a pod, a role the plane narrows holds at the caller's next command: the guard answers the scopes that command runs with, the mirror's role intersected with the token's; it narrows and never widens"
date: 2026-10-11
status: accepted
issue: 494
paths:
  - apps/troupe_worker/lib/troupe/worker/auth.ex
  - apps/troupe_gateway/lib/troupe/gateway/connection.ex
  - apps/troupe_protocol/lib/troupe/protocol/endpoint.ex
symbols:
  - Troupe.Worker.Auth.guard/1
gist: "Pod guard may answer {:ok, scopes}: the mirrored role's, intersected with the token's, for that one command. Narrows at once, never widens."
---

Issue #494. A pod's ACL mirror only revoked: when the plane changed a person's role on a
session with `session.grant`, the pod recorded the new role and then ignored it, because
the connection's scopes were fixed from the token at `initialize`. Somebody granted `owner`
and then made a collaborator kept `admin` on the pod, and with it `shell.run` (Decision
813), until the token expired, at most fifteen minutes later.

The issue allowed either making the narrowing reach the running pod or stating the bound.
Making it reach the pod needed no new mechanism: the plane already pushes the new role as
`acl.changed` (`Troupe.Plane.Harness.push_acl/2`), the worker already mirrors it
(`Troupe.Worker.Auth.put_acl/4`), and the guard is already asked before every command.
What was missing was a way for the guard's answer to reach the dispatcher's scope checks,
so stating the bound would have documented a gap that was a few lines wide.

- **The guard says how many scopes the command gets.** A remote endpoint's guard may answer
  `{:ok, scopes}` as well as `:ok` and `{:error, _}`. `Troupe.Gateway.Connection` dispatches
  that one command with the connection's scopes filtered to those, and keeps its own
  scopes as they were, so a later push that restores the role restores the scopes with it.
  Every check downstream sees the narrowed set: the method table's required scope and the
  handlers' own (`session_owner/1`, which is what refuses `shell.run` to a collaborator).
  Rejected: a list in the worker of the methods each role may call, which would repeat the
  dispatcher's table and miss every in-handler check, `shell.run`'s among them.
- **It narrows and never widens.** The connection intersects, so no guard can grant a
  scope the token did not carry. A collaborator the plane makes an owner keeps `control`
  until their next token, which `auth.refresh` brings within the token's lifetime: a wider
  role is something a signature should vouch for, a narrower one is not.
- **The mirror's role is the role.** No mirrored entry leaves the token as the only word,
  as before; a revocation still refuses with `access revoked`; a role gives its scopes from
  `Troupe.Protocol.Token.scopes_for/1`. A token with no session in it that names several
  sessions gets the fewest scopes of the roles mirrored for them.
- **What a narrowed caller sees** is the refusal a token of the narrower role gets:
  `forbidden` with `data.required_scope`, and `shell.run`'s sentence for the owner's check.
  The connection's `initialize` answer still shows the token's scopes and role; it is a
  description of the token, and the next one will say the new role.

**Proof:** `Troupe.Worker.HarnessAuthTest` ("an owner the plane narrows to a collaborator is
refused a command at once, and a viewer steering", which on the chunk's tip ran the
command; and "a collaborator the plane makes an owner keeps their token's scopes until the
next one"), over a real pod connection with a plane-minted token, and
`Troupe.Worker.AuthTest` ("a role the plane narrows": the guard's answer, and the fewest
scopes across sessions). The bound for widening is in
[roles-and-permissions.md](../admin/roles-and-permissions.md) section 5 and PROTOCOL.md.
