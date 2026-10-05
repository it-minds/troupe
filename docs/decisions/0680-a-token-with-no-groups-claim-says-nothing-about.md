---
number: 680
title: A token with no groups claim says nothing about groups
date: 2026-09-22
status: accepted
paths:
  - apps/troupe_plane/test/troupe/plane/mcp_auth_test.exs
gist: A token with no groups claim says nothing about groups
---

Every provider token the
plane accepts — a login's id token, an MCP client's access token — went through the
same `Login.from_claims/1`, which replaced the person's memberships with the token's
groups claim, reading an absent claim as an empty one. Replacing is right: a group a
login no longer carries is one the person has left. Absence is not: an MCP client's
token is minted for the scopes the client asked for, the plane advertised only its own
MCP scope, and so the first tool call a platform admin made through Claude removed
every membership they had, their admin group included, and every call after did the
same. Now an absent claim leaves memberships alone, a present and empty one still
clears them, and the MCP resource metadata advertises the sign-in's scopes beside the
MCP one, so the token carries what a login's does. Proof: `Troupe.Plane.LoginGroupsTest`.
