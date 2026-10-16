---
number: 914
title: "Only a webhook that names no repository has a trigger key, and `POST /trigger/<id>` opens no other; a run by hand is one per caller per minute; a refused adoption is settled by a platform admin or by a later sign-in that agrees, folding the sign-in's row into SCIM's; a push the unique `externalId` refuses is a `409` naming the pair; and a manifest written after a removal names the tombstone until somebody new arrives under the subject"
date: 2026-10-16
status: accepted
supersedes: [899, 903, 906]
paths:
  - apps/troupe_plane/lib/troupe/plane/triggers.ex
  - apps/troupe_plane/lib/troupe/plane/index.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/admin/api.ex
  - apps/troupe_plane/lib/troupe/plane/identity.ex
  - apps/troupe_plane/lib/troupe/plane/login.ex
  - apps/troupe_plane/lib/troupe/plane/scim.ex
  - apps/troupe_plane/test/troupe/plane/identity_gaps_test.exs
  - apps/troupe_plane/test/troupe/plane/trigger_ingress_test.exs
  - apps/troupe_plane/test/troupe/plane/trigger_sources_test.exs
  - clients/gui/apps/console/src/views/Identity.tsx
  - clients/gui/apps/console/test/identity.test.tsx
  - docs/admin/bundles-and-triggers.md
  - docs/admin/routine-tasks.md
symbols:
  - Troupe.Plane.Triggers.keyed?/1
  - Troupe.Plane.Admin.trigger_run/3
  - Troupe.Plane.Admin.identity_adopt/3
  - Troupe.Plane.Identity.adoption/3
  - Troupe.Plane.Identity.settle/2
  - Troupe.Plane.Identity.fold/2
  - Troupe.Plane.Identity.removed_owner/2
gist: "A key is a plain webhook's alone; a manual run keys on the caller and the minute; a refused pair is settled by admin.identity.adopt or a later agreeing sign-in, SCIM's row kept"
---

Chunk 37's slot E37, a sweep of what `defects.md` D129 and the chunk 36 and 37 fixers left
in triggers and identity. Each item below had a test that failed on the chunk's tip. This
replaces, of Decision 906, "a token that carries neither value ... makes a row of its own.
That is the cost of not guessing" and the push answered `400` for the unique index; of
Decision 899, its "Not done" about `mix troupe.index.rebuild`; and of Decision 903, "with
no row, a session whose manifest was last written no later than a removal under that
subject is that tombstone's", which is now wider. The rest of all three stands.

## A trigger key is a plain webhook's

`admin.trigger.key.rotate` minted a key on any trigger, a schedule's and a GitHub
repository's included, and `POST /trigger/<id>` then fired it with whatever event body the
holder sent: a door nobody asked for, on a trigger whose source is something else.
`Triggers.keyed?/1` says which triggers a key fires: a webhook that names no repository. A
schedule is fired by the plane, a repository's trigger by the App's signed deliveries, a
manual one by a person or a principal who signed in. Rotation on any other is refused
`invalid_params` with what fires it instead, and mints nothing. `Triggers.by_key/2` checks
it too, so a key a trigger kept from before its source changed opens nothing, and the
endpoint's one `401` for every refusal stays one answer, not an oracle. The key is not
cleared when the source changes: it is dead without being removed, and a trigger changed
back to a webhook is given a new one by a rotation, as any webhook made another way is.

## A run by hand is one per caller per minute

`trigger_run/3` keyed on the caller and the second; its docstring and PROTOCOL.md said the
minute. The minute wins. A webhook without its own `Idempotency-Key` and a schedule's tick
are drawn on the minute; a second click, or a retry of a call whose answer was lost, a
second or two later, is the case the key is for, and on the second it made a second session
whenever the two straddled a boundary. The cost: a person who means a second run in the
same minute is handed the first one, which the answer says, and waits until the next.

## Settling a refused adoption

Decision 906 refused an adoption whose email and username both disagree, listed the pair,
and left only the provider to settle it, which it cannot when a person's email and username
both changed, or a token carries neither.

- **A later sign-in that agrees folds.** `Identity.adoption/3` answers `{:fold, row, held}`
  when the one under the subject is a row a sign-in made (no `externalId`, no `userName`),
  the row SCIM gave the subject as `externalId` is another, and what the sign-in carries
  agrees with SCIM's row: the rule an adoption needs, met later, as by the desktop app's
  token after an MCP client's that carried neither. Chosen over refusing to make the row:
  refusing would lock out the MCP client's sign-in (`--auto` tools, an agent) until the
  person signed in elsewhere first, for nothing gained, since the row it makes is folded the
  moment evidence arrives. `Identity.fold/2` folds the sign-in's row into SCIM's, which
  takes the subject, as an adoption would have moved it: SCIM's id is what the provider
  holds. Audited `person.adopt` by the subject, `via: "sign-in"`.
- **A push is not given a fold.** That a push agrees with SCIM's row says nothing about who
  holds the token under the subject, which is the person the fold would hand the row to.
  The push keys on the sign-in's row, and the unique `externalId` refuses it.
- **That refusal is a `409` naming the pair**, `uniqueness`, with both rows' ids and that
  `admin.identity.adopt` folds them, audited `person.adopt_refused` with the row it keyed on
  as `other`, and listed with the other refusals, rather than a `400` with a changeset's text.
- **`admin.identity.adopt {row, subject}`**, a platform admin's, destructive and confirmed
  by the subject, settles a listed pair whatever the email and username say: with a row a
  sign-in made under the subject, it is folded as above; with none (a refused push leaves no
  second row), nothing moves now, and the next push or sign-in under the subject adopts
  SCIM's row, since `adoption/3` reads the settlement off the audit trail as the listing
  reads refusals. A row under the subject that SCIM named by another `externalId` is
  somebody else's and is refused. A settled pair is no longer listed. The console's Identity
  screen offers **Settle** on each set `by: "external_id"`, typed by the subject, its preview
  saying that whoever signs in under the subject is given SCIM's row.
- **A fold keeps the key-manager name of the row known first**, as Decision 899's merge
  does, and answers the other. What the other row stored at the key manager (a private
  session's data key) stays under that name; nothing moves there. A sign-in row made after a
  claim switch has usually stored nothing.

The listing names, on a set `by: "external_id"`, its `subject` and SCIM's `row`, which is
what `admin.identity.adopt` takes.

## A rebuilt index keeps the tombstone

`Identity.removed_owner/2` named the tombstone only for a manifest written no later than the
removal. A session parked as its owner was removed can have its manifest written after, and
a rebuild of a lost index then handed it to the subject, so to whoever the provider sent
later under it. Now: the first tombstone removed at or after the manifest was written, as
before; else the last one under the subject, unless somebody is under the subject now who
arrived before the manifest was written, whose it then is. Nobody else could have written
it: the subject named nobody between the removal and the arrival. The same function decides
whom an old trigger revision's `notify` lets in, and the same reading holds there. Left: a
person moved under the subject by a re-key (Decision 751) arrived when their row was made,
not when they moved, so a manifest written between the removal and the move would be read
as theirs; that needs a removal, a re-key onto the removed subject and a lost index together.

## Not done

- An editor for rules under the organisation's `defaults:` on a plane. The plane keeps no
  such rules (its `client_defaults` are the provider and the models), so an editor needs a
  new setting and a new key in `me.client_defaults`, and the rules it would carry hold
  exactly as the enforced set's do (Decision 907: no rule is a default a person replaces).
  Whether a plane should offer a second place to say the same is the maintainer's choice.
- `DoctorCLITest`'s race with other tests' leftover writers, and the plane suite's fake pod
  displaced by another checkout's worker link on a reused port, are test changes and decide
  nothing.

## Proof

On the chunk's tip, nine tests failed: `TriggerIngressTest` (a schedule's, a manual one's
and a repository's rotation refused, and a key kept from before a source change opening
nothing), `GitopsTriggersTest` (a schedule's rotation refused), `TriggerSourcesTest` (two
runs by hand a second apart are one run), and in `IdentityGapsTest` a bare token then an
agreeing one folding, a push onto a refused sign-in's row answering `409` naming both, an
administrator settling a sign-in's pair and a refused push, refusing a row SCIM named by
another `externalId`, and a rebuilt index keeping the tombstone for a manifest written after
the removal while a session of the person who arrived later is theirs. All pass, beside the
plane's admin, parity, coverage, SCIM, login, one-row-per-person and trigger suites. The
console's `identity.test.tsx` settles a pair behind the typed preview and finds it gone.
