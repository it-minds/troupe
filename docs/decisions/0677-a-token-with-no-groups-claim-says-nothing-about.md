---
number: 677
title: A token with no groups claim says nothing about groups
date: 2026-09-22
status: accepted
paths:
  - apps/troupe_plane/test/troupe/plane/login_groups_test.exs
gist: A token with no groups claim says nothing about groups
---

Every provider token
the plane accepts — a login's id token, an MCP client's access token — goes through
`Login.from_claims/1`, which replaces the person's memberships with the token's
groups claim. Replacing is right: a group a login no longer carries is one the
person has left. Reading an absent claim as an empty one is not: an MCP client's
token is minted for the scopes the client asked for, and read that way the first
tool call a platform admin made through Claude removed every membership they had,
their admin group included. So an absent claim leaves memberships alone, a present
and empty one still clears them, and the MCP resource metadata advertises the
sign-in's scopes beside the MCP one, so the token carries what a login's does.
Proof: `Troupe.Plane.LoginGroupsTest`.
