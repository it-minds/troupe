---
number: 899
title: "A plane holds one row per person and per group: a push or a sign-in that finds nobody under its subject reuses the row SCIM gave that `externalId`, duplicates are merged into SCIM's row before `users.external_id` is made unique, and a SCIM `DELETE` removes a person behind a tombstone and a group with the team built on it alone"
date: 2026-10-13
status: accepted
issue: 707
supersedes: [754, 759]
paths:
  - apps/troupe_plane/lib/troupe/plane/scim.ex
  - apps/troupe_plane/lib/troupe/plane/login.ex
  - apps/troupe_plane/lib/troupe/plane/identity.ex
  - apps/troupe_plane/lib/troupe/plane/identity/user.ex
  - apps/troupe_plane/lib/troupe/plane/identity/tombstone.ex
  - apps/troupe_plane/lib/troupe/plane/sessions.ex
  - apps/troupe_plane/lib/troupe/plane/erasure.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/admin/console.ex
  - apps/troupe_plane/lib/troupe/plane/web/router.ex
  - apps/troupe_plane/priv/repo/migrations/20261013000899_one_row_per_person.exs
  - apps/troupe_plane/test/troupe/plane/one_row_per_person_test.exs
  - apps/troupe_plane/test/troupe/plane/scim_answers_test.exs
  - apps/troupe_plane/test/troupe/plane/scim_entra_test.exs
  - clients/gui/apps/console/src/views/Teams.tsx
  - clients/gui/apps/console/src/owed.ts
  - docs/admin/authentik.md
  - docs/admin/integrations.md
symbols:
  - Troupe.Plane.SCIM.delete_user/1
  - Troupe.Plane.SCIM.delete_group/1
  - Troupe.Plane.Identity.remove_user/2
  - Troupe.Plane.Identity.lookalikes/0
  - Troupe.Plane.Repo.Migrations.OneRowPerPerson.merge/1
gist: One row per `externalId`, found before a push or sign-in makes anybody; duplicates merged into SCIM's row; SCIM DELETE removes the row, a tombstone keeps the rest
---

Issue #707. A plane fed by SCIM and by sign-in showed the same person, and the same
group, more than once, and a SCIM `DELETE` removed nothing. Settled by the maintainer on
2026-10-13; this records how. It replaces the part of Decision 759 that made a `DELETE`
soft ("One way to deactivate" names a `DELETE` among the ways to deactivate) and the
sentence of Decision 754 that has a group's `DELETE` empty it. The rest of both stands:
`active: false` in a push or a PATCH still deactivates and keeps the row, and a `POST` of
somebody the plane has is still a create.

- **A person is found by their `externalId` too.** A push keys on its subject,
  `externalId` else `userName`; one that finds nobody under it but finds a row whose
  `external_id` is the `externalId` it carries updates that row and keeps that row's
  subject. A sign-in that finds nobody under its subject, after Decision 751's move, but
  finds a row whose `external_id` is that subject moves the row there with
  `Identity.rekey/2`, the same move, audited as `person.rekey`. SCIM names a person by the
  value the subject claim carries, so a row whose `external_id` is not its subject is one a
  sign-in under another claim moved; without this, the next push after a `subject_claim`
  switch made a second row with the same `external_id`, and switching back made a second
  row at sign-in. A deactivated row found this way is still refused (Decision 381).
- **`users.external_id` is unique where set**, a partial index, and `User.changeset/2`
  reports a clash as a changeset error, so a push that would give a second row the value
  answers `400` rather than `500`.
- **The duplicates already there are merged by the migration**, not by an admin task: the
  index must come after the merge and before the plane serves, and a task run after the
  upgrade would leave the index unbuildable on exactly the planes that need it. One person
  is every row whose `external_id` is the value, and every row whose `subject` is the value
  that SCIM has not named otherwise. The row kept is SCIM's, since its `id` is what the
  provider holds: the one whose `subject` is also the value, else the newest carrying it,
  which the provider created last. The others are folded into it as Decision 751 folds a
  moved person: sessions (owner and owner id), ACL entries, shares made out to them, team
  administration, sponsored principals, the sponsor in a run's origin, triggers' `notify`,
  usage records and open reservations move; the audit trail and every `*_by` keep the name
  they were written with. The kept row takes the key-manager name of the row known first,
  under which what they stored before there were two is, and its own ceiling, else a
  folded row's. Each set is one `person.merge` row on the audit trail, chained like every
  other, with the kept and folded ids and subjects and the key-manager names left behind,
  and is logged. The SQL is the migration's own, because a migration is the plane as it
  stood then; `merge/1` is public so a test runs it on seeded duplicates.
- **What only looks alike is reported, not merged.** The same email or display name under
  different keys proves nothing: two people may share an address, and only the provider
  knows which of a group's two ids is right. `Identity.lookalikes/0` lists such sets with
  where each row came from (a sign-in writes neither `externalId` nor `userName`) and the
  mismatch it most likely comes from: the subject claim against SCIM's `externalId` for a
  person, a groups claim naming a group by its name while SCIM pushes its id for a group.
  `admin.identity.duplicates` answers both, for a platform admin; `admin.groups.list`
  marks each group in a set with `looks_duplicated`, and the new console shows that where a
  group is chosen to become a team. The console's Identity area is where people and groups
  are listed and where the rest belongs; it is owed there. A pair sharing an `externalId`
  never appears, since it was merged.
- **A SCIM `DELETE` of a person removes the row.** `GET` and `DELETE` of the id answer
  `404` afterwards and filters do not find them. A tombstone (`person_tombstones`) keeps
  the former id, subject, `externalId`, `userName`, display name and key-manager name. Their
  team sessions that are running or waiting are parked first, each giving back its slot and
  its slice under the subject it was reserved for; then all their sessions go read-only and
  are owned by the tombstone's marker, `removed:<tombstone id>`, so nothing matches them to a
  subject again. They stop administering every team, their ACL entries go, shares made out
  to them are revoked, and the principals they sponsor stop (`sponsor_left`, as a
  deactivation does). Their memberships go with the row. Audited as `person.remove` by
  `scim`, under the subject they had, with what was done.
- **Somebody the provider sends later under the same subject is somebody new.** They do
  not inherit the removed person's sessions, ACL entries or administration, and are not
  given the removed person's key-manager name, which a tombstone holds as a user row does:
  whatever the removed person stored there stays theirs, for an erasure (#636) to remove,
  and an erasure of their private sessions finds it through the marker
  (`Identity.kms_name_of/1`). A provider deleting somebody is offboarding them; handing a
  re-hire the old sessions would be a decision about access that the provider did not make,
  and is not made here.
- **A SCIM `DELETE` of a group removes it** with its memberships and links. A team built
  on it and on no other group is disabled as an administrator would disable it: grants
  revoked with their sessions read-only and the profiles' teams written again, its triggers
  deleted, then the row, audited as `team.disable` by `scim`. A team that draws from other
  groups too keeps them, and its `group_id`, the record of which group it was enabled from,
  moves to one of them, since the database deletes a team with the group it records. The
  group's own deletion is audited as `group.delete`, naming the teams disabled and kept.
- Not done here: erasing a removed person's sessions or key-manager data (#636); a
  provider subject that starts `removed:` is not refused, on the same footing as `svc:`;
  `mix troupe.index.rebuild` restores a session's owner from its manifest, which names the
  subject, not the marker.
- **Proof:** the plane's `one_row_per_person_test.exs`. The real sequence through the
  router and `Login.from_claims/1`: a sign-in, a push, a switch to `oid`, the same push
  again keeping one row, then a `DELETE` with the `GET` and filter answering nobody, the
  tombstone, the session read-only under the marker, the administration gone, the
  principal stopped, the audit naming them, and the same person signing in again as a new
  row that sees none of it. A sign-in after switching back finding SCIM's row by its
  `externalId`. A removed person pushed again named by their own id at the key manager. A
  group's `DELETE` disabling the team built on it alone and moving the other team's record.
  The migration's merge on a database with the index made plain again and two rows for one
  person, keeping SCIM's, moving the session, ACL and administration, auditing a chain that
  verifies, the unique index building after it, and a second merge finding nothing. Look-
  alike people and groups reported with their likely causes, flagged in `admin.groups.list`,
  and refused to a team admin. On the chunk tip a reproduction of the push after the switch
  held two rows, the sign-in after switching back made a new one, and a `DELETE` left `GET`
  answering `200`. The migration also ran forward on a scratch database migrated to the
  release before and seeded with both kinds of duplicate: one merged, the lookalikes
  reported, the index unique and refusing a second row. `scim_answers_test.exs` and
  `scim_entra_test.exs` ask a `DELETE` for the removal rather than a deactivation, and the
  console's `teams.test.tsx` for the flag.
