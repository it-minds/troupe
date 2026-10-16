---
number: 906
title: "A sign-in or a SCIM push adopts the row SCIM gave its subject as `externalId` only when that row's email or `userName` agrees, and otherwise merges nothing, audits it and lists the pair; a SCIM `PUT` replaces the person at its id; a push under `removed:` or `svc:` is refused; a removed person comes off `notify` lists and their spend goes to the tombstone; and the chart's control port takes TLS only by default, saying a plaintext refusal once a minute per address, with a `PlaneCAMissing` condition on a profile whose namespace has no CA"
date: 2026-10-16
status: accepted
issue: 715
supersedes: [759, 899, 902]
paths:
  - apps/troupe_plane/lib/troupe/plane/identity.ex
  - apps/troupe_plane/lib/troupe/plane/login.ex
  - apps/troupe_plane/lib/troupe/plane/scim.ex
  - apps/troupe_plane/lib/troupe/plane/web/router.ex
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - apps/troupe_plane/lib/troupe/plane/control/listener.ex
  - apps/troupe_plane/lib/troupe/plane/control/refusals.ex
  - apps/troupe_operator/lib/troupe/operator/reconciler.ex
  - charts/troupe/values.yaml
  - charts/troupe/templates/_helpers.tpl
  - clients/gui/apps/console/src/views/Profiles.tsx
  - apps/troupe_plane/test/troupe/plane/identity_gaps_test.exs
  - apps/troupe_plane/test/troupe/plane/control_tls_test.exs
  - apps/troupe_operator/test/troupe/operator/reconciler_test.exs
  - clients/gui/apps/console/test/profiles.test.tsx
  - docs/admin/routine-tasks.md
  - docs/admin/authentik.md
  - docs/admin/integrations.md
symbols:
  - Troupe.Plane.Identity.adoption/3
  - Troupe.Plane.Identity.lookalikes/0
  - Troupe.Plane.Identity.remove_user/2
  - Troupe.Plane.SCIM.put_user/1
  - Troupe.Plane.SCIM.replace_user/2
  - Troupe.Plane.Control.Refusals
gist: "Adopt an externalId's row only if its email or userName agrees, else audit and list; SCIM PUT by id; removed: and svc: refused; requireTls on by default"
---

Issue #715, and the identity and control-channel lines of `defects.md` D128. Settled by
the maintainer on 2026-10-16: an adoption needs a second attribute to agree, and
`plane.controlTls.requireTls` turns on in 0.20 as Decision 902 said it would. This replaces
the part of Decision 899 that adopts on the `externalId` alone and its "Not done" about
`removed:` subjects at SCIM; the part of Decision 759 that keeps a `PUT` keyed on its body
and answers a refused `POST` or `PUT` without SCIM's error body; and the part of Decision
902 that leaves `requireTls` off in the chart, logs each refusal, and says no profile
status reports a missing CA. The rest of all three stands.

**An adoption needs the email or the `userName` to agree.** A sign-in, or a SCIM push,
that finds nobody under its subject but finds the row SCIM gave that value as
`externalId` (Decision 899) takes the row over only when the row's email or its
`userName` equals, ignoring case and surrounding space, what the sign-in or push carries:
a token's `email`, and its `preferred_username` (else `upn`); a push's primary email and
its `userName`. `Identity.adoption/3` answers `:none`, `{:adopt, row}` or
`{:refused, row}` for both doors. The `externalId` is one provisioning attribute; mapped
wrongly, it alone handed one person's row, sessions, shares and team administration to
whoever signed in under that value. A second attribute from the same provider has to be
mapped wrongly the same way for that to happen. A token or push that carries neither
value has nothing that agrees and is refused: an MCP client's access token without
`email` or `preferred_username`, as the first sign-in after a claim switch, makes a row of
its own. That is the cost of not guessing, and the pair is listed for it.

- **Refused, nothing is merged.** A sign-in gets a row of its own under its subject, as
  any first sign-in does; the row SCIM made stays where it was, with everything on it. A
  push cannot make a second row, since `users.external_id` is unique (899), so it is
  refused `409` with `scimType` `uniqueness` (RFC 7644 §3.12), which a provider shows in
  its provisioning log, and changes nothing. A `PUT` to the row's own id is not an
  adoption and is unaffected.
- **Audited and listed.** Each refusal is `person.adopt_refused` on the audit trail, by
  the signing-in subject or by `scim`, naming the subject, the row's id and subject, and
  which door, and nothing the token or push said about the person; it is logged the same
  way. `admin.identity.duplicates` lists each refusal that still stands, a set with
  `by: "external_id"`: the row SCIM made and, for a sign-in, the row the sign-in made,
  with what to do in `likely`. It is read from the audit trail because a refused push
  leaves no second row to find; a refusal stops being listed once the row is under its
  `externalId` again or is gone. Look-alike sets that only repeat a listed pair are left
  out.

**A SCIM `PUT` replaces the person at its id** (RFC 7644 §3.5.1). `SCIM.replace_user/2`
fetches the row by the id in the path, and a body that would key it on another subject, a
different `externalId` or, without one, a different `userName`, is refused `400`
`mutability`, the rule a `PATCH` already had (754); otherwise the body is written to that
row under its own subject. Before, a `PUT` for an id that existed upserted on the body's
subject, so a body naming somebody else changed them. A refused `POST` or `PUT` now
answers SCIM's error body (`scimType`, `detail`) like every other refusal.

**`removed:` and `svc:` are refused at SCIM** as they are at sign-in: a push whose subject,
`externalId` else `userName`, starts with either answers `400` `invalidValue`. A person
under one could never sign in and would be named where a removed person's sessions or a
principal are.

**A removed person's subject names nothing they leave behind.** `Identity.remove_user/2`
takes the subject off every trigger's `notify` list (the audit's `notified_by` names the
triggers), so a person provisioned later under it is not let into the next run; and moves
their usage records and reservations to the tombstone's marker, so a cap read by subject
starts at nothing for whoever arrives under it, while a team's totals, which are by team,
do not change. A trigger's revisions are history and keep the list they were written
with; the next firing makes a revision from the trigger as it now is. In `gitops` mode
the repository's `notify` comes back at the next change to the resource, as for a move
(751).

**TLS only by default.** The chart's `plane.controlTls.requireTls` is `true`. Every pod a
0.19 operator made dials with TLS, and 0.19's operator gave every new pod template the
CA, so by 0.20 a pod still in plaintext is one an older operator made and its drain has
not replaced. `routine-tasks.md` says what to check before upgrading: each pod's
enrolment line on the plane says "over TLS" or "in plaintext", and none still running may
say the second; `requireTls: false` keeps such a pod enrolling until it is replaced. The
chart still refuses `requireTls` without `enabled`, and its message now says to set both,
since the default is on: silently dropping the requirement when TLS is off would be a
setting that means nothing. The plane's own default, with no chart, stays off: a plane
started without `TROUPE_PLANE_CONTROL_TLS_DIR` has no certificate to require.

**A refusal is said once a minute per address.** A pod an old operator made reconnects
every 250 ms to two seconds until it is replaced, and with TLS required each connection
was a warning. `Troupe.Plane.Control.Refusals` keeps, per peer address (not port, which
changes at each reconnect), when the last line was said and how many went unsaid since;
the next line after a minute carries that count. A public ETS table the listener owns, as
`Replay`'s is; an address quiet for an hour is forgotten. Two refusals from one address at
the same instant may both be said.

**`PlaneCAMissing` on a profile.** Where the installation gives pods the plane's CA
(`TROUPE_PLANE_CONTROL_CA` set, from `plane.controlTls.enabled`), each pass looks for the
`troupe-plane-ca` ConfigMap in the profile's namespace after applying: `True` with
`NotWritten` and the file it could not read when there is none, `False` with `Present`
when there is, and `False` with `NotGiven` where pods are given no CA. Looked for rather
than inferred from the pass, since a pass that could not read the file leaves the CA an
earlier pass wrote. Beside `SecretMissing`, not part of `Ready`, for the same reason: the
profile reconciled. The new console did not show a profile's conditions at all; its
profile page now has "What the cluster says", every condition with its message, as the
LiveView pages did.

**Proof.** The plane's `identity_gaps_test.exs`: SCIM first under `oid`, the sign-in that
moves the row, then back on `sub` a sign-in whose email agrees adopting the row, one whose
`preferred_username` agrees adopting it, and one that agrees on neither getting its own
row, with `person.adopt_refused` audited without an email and the pair in
`admin.identity.duplicates`, and its next sign-in asking nothing again; a push that agrees
updating SCIM's row and one that does not answered `409` `uniqueness`, audited and listed;
a `PUT` changing only the person at its id, and one carrying another person's body refused
`mutability` with nobody changed; pushes under `removed:` and `svc:`, as `externalId` and
as `userName`, refused `invalidValue`; a removal taking the subject off a trigger's
`notify`, moving the month's spend to the marker with the team's total unchanged, and the
person pushed again starting at nothing. Every one but the adoptions that agree failed on
the chunk tip. `ControlTLSTest`: three plaintext dials from one address said once, and
`Refusals` saying the count after a minute. `ReconcilerTest`: `PlaneCAMissing` true before
the file is there, false once a pass writes the CA and after a pass that cannot read it,
and `NotGiven` without a CA path; both failed on the tip. The console's
`profiles.test.tsx`: the conditions of a profile the fake reports a missing CA for.
`helm template` renders `TROUPE_PLANE_CONTROL_REQUIRE_TLS` by default and refuses
`enabled: false` alone; on the tip it rendered nothing.
