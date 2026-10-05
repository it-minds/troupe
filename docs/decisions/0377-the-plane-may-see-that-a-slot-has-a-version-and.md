---
number: 377
title: The plane may see that a slot has a version, and nothing more
date: 2026-09-15
status: accepted
paths:
  - apps/troupe_plane/test/troupe/plane/person_credentials_test.exs
gist: The plane may see that a slot has a version, and nothing more
---

Its policy gains
`list` and `read` on `metadata/troupe/people/+/mcp/*` — KV v2 metadata, which is
versions and timestamps and never a value. That is exactly what a panel needs in
order to say "Ada has connected Jira" and the most it should ever be able to say.
No `delete`: removing a credential uses the same grant as writing one, so an
administrator can retire a server from the bundle and can neither read nor remove
somebody's credential.
