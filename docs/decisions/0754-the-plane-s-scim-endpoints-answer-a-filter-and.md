---
number: 754
title: The plane's SCIM endpoints answer a filter and take PATCH the way Microsoft Entra ID sends them, keep a user's `userName` beside the subject, and never move a person in a push
date: 2026-10-02
status: accepted
issue: 340
paths:
  - apps/troupe_plane/lib/troupe/plane/identity/user.ex
  - apps/troupe_plane/lib/troupe/plane/scim.ex
  - apps/troupe_plane/lib/troupe/plane/web/router.ex
  - apps/troupe_plane/priv/repo/migrations/20261002000754_scim_user_name.exs
  - docs/admin/integrations.md
gist: The plane's SCIM endpoints answer a filter and take PATCH the way Microsoft Entra ID sends them, keep a user's `userName` beside the subject, and…
---

Issue #340, which #267 needs: with 751 the plane keys a person as Entra's
sign-in does, and Entra's provisioning client still could not find or change them.
`GET /scim/v2/Users` ignored `filter` and answered with everybody, a `PATCH` was read
as a whole user and answered `500`, and `GET /Users/:id` looked the id up as a subject.
- **One filter, and nothing half-read.** `<attribute> eq "<value>"`, on `userName` or
  `externalId` for users and `displayName` or `externalId` for groups: what a provider
  matches on before it creates. Attribute names and `eq` in any case; a `userName` or
  `displayName` compared ignoring case, as RFC 7644 compares them, and `externalId`
  exactly. Anything else is `invalidFilter`, since an answer to part of a filter is
  read as a match.
- **`userName` is kept.** Where an `externalId` comes with it, which under 751 is every
  Entra user, the `userName` was nobody's subject and kept nowhere, so Entra's default
  match, `userName eq "<their UPN>"`, answered nobody about a person the plane had:
  each change after the first push would have been a create, and a removal from
  scope a skip. It is a column on `users`, written by a push and a PATCH and rendered
  as `userName`, and the subject stands in for it on a row no push has named. A label,
  as the email is; a sign-in does not write it.
- **A PATCH changes what a push would**, a user's `userName`, `externalId`,
  `displayName`, email and `active`, a group's `displayName` and members, and accepts
  and ignores the rest (`title`, `name.*`, the enterprise extension), as a `POST`
  does. It is read the way Entra writes one as well as the way the RFC does: `op` in
  any case, a value object without a path whose keys are paths, `"False"` for `false`,
  `members[value eq "<id>"]`. `active: false` is a `DELETE`, and the principals the
  person sponsors stop. It is applied whole or refused whole with SCIM's error body
  and a `400` (a bad op, path or value; removing what is required), never a `500`.
- **A PATCH does not make somebody else.** One that would key the person on another
  subject, a different `externalId` or, without one, a different `userName`, is
  refused as `mutability`: a person moves at sign-in under 751, with their sessions,
  and a push that moved them would leave those under the old name. A group's
  `externalId` is what a groups claim names it by, and does not change either.
- **Members by PATCH are a change, not a list.** A push carries the whole list and
  replaces it; a PATCH names members and adds or removes them, read and written in one
  transaction with the group's row held, so two at once do not lose one. An id nobody
  has is nobody to add, as in a push. A group's PATCH answers `204`, a user's the user.
- **Addressed by the plane's `id`**, `GET /Users/:id` and `/Groups/:id`, and
  `excludedAttributes=members` leaves a group's members out, as Entra asks for groups.
  `DELETE` on a group empties it, which the docs said and the route did not do.
- Unchanged: `POST` and `PUT`, which upsert on the subject and answer `200`; no
  pagination, bulk, ETags or `/Schemas`. (759 revises this: a `POST` answers `201`.)
- **Proof:** the plane's `scim_entra_test.exs`, Microsoft's documented provisioning
  requests with `example.test` names, sent to the router as Entra sends them: a filter
  finding one user and nobody, a group by name without its members, and refusals as
  `invalidFilter`; a user and a group by id; a user's whole sequence (filter, `POST`,
  `Replace` with paths, a new `userName`, `Add`, `Remove`, attributes not kept,
  Disable User) leaving one row with those attributes; the value-object form and
  `"False"`; `active: false` stopping a sponsored principal and refusing sign-in; a
  group's members added and removed by value and by path filter, then renamed, one
  row; `DELETE` emptying it, `PUT` still replacing; and refused PATCHes changing
  nothing. All 13 failed on the tip of #339's branch: the filter answered with
  everybody, an unread filter with `200`, and every PATCH raised.
