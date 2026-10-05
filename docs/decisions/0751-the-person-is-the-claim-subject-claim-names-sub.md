---
number: 751
title: The person is the claim `subject_claim` names, `sub` by default and `oid` for Entra ID, and a plane switched to another claim moves each person it already knows once, at their next sign-in
date: 2026-10-02
status: accepted
issue: 267
paths:
  - apps/troupe_plane/lib/troupe/plane/identity.ex
  - apps/troupe_plane/lib/troupe/plane/identity/user.ex
  - apps/troupe_plane/lib/troupe/plane/login.ex
  - apps/troupe_plane/lib/troupe/plane/scim.ex
  - apps/troupe_plane/lib/troupe/plane/settings.ex
  - apps/troupe_plane/priv/repo/migrations/20261002000754_scim_user_name.exs
  - apps/troupe_plane/priv/repo/migrations/20261002000755_person_kms_name.exs
  - apps/troupe_plane/test/troupe/plane/scim_entra_test.exs
  - apps/troupe_plane/test/troupe/plane/subject_claim_test.exs
  - config/runtime.exs
  - docs/admin/configuration.md
gist: The person is the claim `subject_claim` names, `sub` by default and `oid` for Entra ID, and a plane switched to another claim moves each person it…
---

Issue #267, the other half of defect D9. Entra's `sub` is
pairwise, a different string in every app registration and no attribute its SCIM
client can send, so the person SCIM made and the same person signing in were two rows.
- **One setting, every door.** `subject_claim` (`TROUPE_OIDC_SUBJECT_CLAIM`,
  `plane.oidc.subjectClaim`) is read in `Login.from_claims/1`, which the CLI's and the
  desktop app's exchange, the console's sign-in and an MCP client's provider token all
  go through. SCIM's subject stays `externalId`, else `userName`; for Entra the
  provisioning mapping sends `objectId` as `externalId`. `oid` is unique within a
  tenant and the plane trusts one tenant's issuer, so `tid` is not part of it. A token
  without the claim is refused as `{:no_subject, claim}`, which names it. A provider
  whose `sub` already is what SCIM sends keeps the default, and nothing changes there.
- **The deployment's, not the console's.** Shown on the Identity provider card and not
  editable there, as `provisioning_mode` is (736): switching it moves people, and
  switching back does not move them back, since somebody moved to `oid` is not found
  under their `sub`. A setting `reset` cannot undo is not one to offer beside a reset.
- **A move, not a fresh start.** Somebody not found under the claim's value but found
  under the `sub` the same token carries is the same person by the provider's word in
  one signed token, and that token would have signed in as them the day before, so
  moving them gives it nothing it did not have. Their row is renamed. If SCIM
  provisioned them under the new value first, which is the order an Entra rollout
  usually goes in, the old row is folded into that one and removed, so SCIM's own id
  for the person stays good; their own spend ceiling is kept where SCIM's row has none.
  Moved is every column that says *who*: a session's owner and the sponsor in a run's
  origin (whose cap it counts against), ACL entries, shares made out to them, the teams
  they administer, triggers' `notify`, usage records and open reservations, and the
  principals they sponsor (left behind, deprovisioning them would leave those firing).
  What says *who did*, the hash-chained audit trail and every `*_by`, keeps the name it
  was written with. One transaction with the old row locked, so two devices signing in
  at once move the person once; afterwards nobody is under the old value, and the next
  sign-in has nothing to do. Logged and audited as `person.rekey` with the two
  identifiers and the claim's name, and nothing else from the token.
- **A plane token minted before the move is refused**, `unauthenticated` with "no such
  user", as a disabled principal's is, because the router resolves the subject on every
  request. Honouring it would need a second name per person that every lookup by
  subject knew, for one token lifetime of fifteen minutes; a client exchanges again on
  its own. A console session holding the old name is turned away and signs in again.
- **The key manager is not moved**, since the plane holds no credential that can read
  or write it (375, 377), and does not need to be: a person's name there is not their
  subject (755).
- In `gitops` mode a trigger's `notify` is the repository's, and the next change to the
  resource puts back whatever the repository says.
- **Proof:** the plane's `subject_claim_test.exs`: with `oid`, an Entra-shaped user
  SCIM provisioned and the same user signing in are one person; the default, with an
  Authentik-shaped `sub`, unchanged; a person known by `sub` moved once at their next
  sign-in, keeping a session, the team they administer and the team they are in, and
  every other column above moved while `created_by` and `granted_by` are not; a second
  sign-in moving nobody; SCIM first, folded in; a token without `oid` refused naming
  it; a plane token from before the move refused. The first and every move failed on
  the chunk tip.
