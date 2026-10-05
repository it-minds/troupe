---
number: 755
title: A person's name at the key manager is a column of its own, fixed when the plane first knows them and left alone by a re-key, and whatever reaches the key manager for a person takes it from the plane
date: 2026-10-02
status: accepted
issue: 341
paths:
  - ARCHITECTURE.md
  - PROTOCOL.md
  - apps/troupe_gateway/lib/troupe/gateway/private.ex
  - apps/troupe_gateway/test/troupe/gateway/private_test.exs
  - apps/troupe_plane/lib/troupe/plane/connections.ex
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - apps/troupe_plane/lib/troupe/plane/erasure.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/identity.ex
  - apps/troupe_plane/lib/troupe/plane/identity/user.ex
  - apps/troupe_plane/lib/troupe/plane/tokens.ex
  - apps/troupe_plane/priv/repo/migrations/20261002000755_person_kms_name.exs
  - apps/troupe_plane/test/troupe/plane/control_test.exs
  - apps/troupe_plane/test/troupe/plane/person_credentials_test.exs
  - apps/troupe_plane/test/troupe/plane/private_erasure_test.exs
  - apps/troupe_plane/test/troupe/plane/subject_claim_test.exs
  - apps/troupe_protocol/lib/troupe/kms.ex
  - apps/troupe_protocol/lib/troupe/kms/policy.ex
  - apps/troupe_protocol/lib/troupe/protocol/bundle.ex
  - apps/troupe_worker/lib/troupe/worker/connections.ex
  - apps/troupe_worker/test/troupe/worker/person_credentials_test.exs
  - docs/admin/configuration.md
  - docs/developer/architecture.md
gist: A person's name at the key manager is a column of its own, fixed when the plane first knows them and left alone by a re-key, and whatever reaches…
---

Issue #341. What a person keeps there, their
credentials for person-mode MCP servers and their private sessions' data keys, was
under `troupe/people/<subject>/`, and the plane cannot move that subtree (375, 377), so
a person moved to another claim (751) connected their servers again and could not
restore a private session on another device.
- **The name.** `users.kms_name`, unique. The migration fills it with each person's
  subject, so nothing in the key manager moves and an installation that never switches
  its claim sees no difference. Somebody first known afterwards is named by their
  subject too, rather than by `users.id`: the key manager's tree then reads as the
  people in it, and a daemon older than its plane keeps working for everybody it
  worked for. An id never collides, and that is the one case it is used for: a
  newcomer whose subject is already somebody's name, which only a switched claim can
  bring about (one person's new value being another's old one), is named by their own
  id rather than share a subtree. Nullable, because a replica of the release before,
  still serving during the rollout, writes people without one; `User.kms_name/1` reads
  such a row as its subject, which is what the name was, and a re-key writes that
  down before it moves the subject.
- **A re-key leaves it.** `Identity.rekey/2` moves the subject and every column that
  says *who*, and not the name. Where SCIM made a row under the new value first, the
  row the old one is folded into takes the old one's name, once the old one is gone:
  everything the person stored is under it, and nobody could sign in as SCIM's row
  without being moved first.
- **Carried with the assertion.** A pod or a daemon does not derive the name; it comes
  in the answer whose token reaches it. `kms.assertion` answers `key_manager: {name}`
  beside the assertion, and `session.assertion` and `me.connections.grant` add `name`
  to their `key_manager`. The assertion's `sub` is the name, so the person policy,
  templated on the alias name OpenBao takes from `sub`, covers the name's subtree with
  no change to the role, the policy or anything an installation wrote. The pod
  (`Troupe.Worker.Connections`) keeps the name beside the token and reads slots under
  it; the daemon (`Troupe.Gateway.Private`) makes or finds a private session's key
  under it; `me.connections.list` and the console's per-server list ask under it. Not
  carried at activation or in the plane token: those name the session's owner and the
  caller, who are subjects, and a name that arrived apart from its token could
  disagree with it.
- **Older clients.** A plane that answers no name is from before this, and a pod or
  daemon then uses the subject, which is what the name was there. A daemon from before
  this, against a plane with it, reads under the subject; for a moved person it is
  refused, and their private sessions stay local on that machine until it is upgraded.
  Nobody else sees a difference.
- **Proof:** the plane's `person_credentials_test.exs`, against the development OpenBao
  and its JWT auth: a credential connected through the grant and a private session's
  key written where `session.assertion` says, before a switch to `oid`; after her next
  sign-in moves her, she is listed as connected, the grant and `session.assertion`
  answer her old name and path, and the tokens they exchange for read both back. The
  worker's `person_credentials_test.exs`: a pod, with a real plane over its link, finds
  the credential before the move and after it, with the session's owner as either
  subject. The gateway's `private_test.exs`: a second device, linked under the new
  subject, gets the key the first sealed with and reads its segment. These three
  failed on the tip of #339's branch. Also the plane's `subject_claim_test.exs` (the
  name kept by a move and by a fold, a newcomer named by their subject or, where a
  moved person has it, their id, a row without one keeping its subject) and
  `control_test.exs` (`kms.assertion` for a moved owner names their old name).
