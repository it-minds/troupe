---
number: 759
title: "A SCIM create answers `201` with where the resource is, a delete of an id the plane does not have answers `404`, and a push with `active: false` deactivates a person the way a `DELETE` and a `PATCH` do"
date: 2026-10-03
status: accepted
issue: 356
paths:
  - apps/troupe_plane/test/troupe/plane/scim_answers_test.exs
  - apps/troupe_plane/test/troupe/plane/scim_connector_test.exs
  - apps/troupe_plane/test/troupe/plane/scim_entra_test.exs
  - apps/troupe_plane/test/troupe/plane/subject_claim_test.exs
  - apps/troupe_plane/test/troupe/plane/web_test.exs
gist: "A SCIM create answers `201` with where the resource is, a delete of an id the plane does not have answers `404`, and a push with `active: false`…"
---

Issue #356, the SCIM items of defect D56, left by
754, which kept `POST` and `PUT` as they were.
- **The answers RFC 7644 gives.** A `POST` to `/Users` or `/Groups` answers `201`, the
  resource, and its path in `Location`, the same as its `meta.location` (section 3.3);
  both are relative to the plane, as `meta.location` already was, because a plane
  behind an Ingress without `TROUPE_BASE_URL` does not know the name it is reached by.
  A `PUT` still answers `200` (3.5.1). A `DELETE` of a user answers `404` for an id
  nobody has, as one of a group already did (3.6), and `204` otherwise.
- **A create of somebody the plane has is still a create.** A push upserts on the
  subject, so a `POST` of a person who signed in before their first push, or one
  pushed before, updates that row and answers `201`. The RFC's answer to a duplicate
  is `409`, which would leave somebody who signed in first unprovisionable: a row
  sign-in keyed on Entra's object id, which no push has named yet, does not answer the
  provider's filter on `userName` (754), so the provider creates, and a refusal there
  is a refusal at every cycle.
- **One way to deactivate.** `put_user/1`, behind `POST` and `PUT`, writes through
  the same function as a `PATCH` and a `DELETE`, which stops the principals the
  person sponsors before it writes `active: false`. Stopping only touches principals
  still running, so the same push again, or a `DELETE` after a `PUT`, stops nothing
  twice; a push that keeps them active does nothing to principals.
- Unchanged: a `PUT` keys on the body's subject rather than the `id` in its path, and
  a refused `POST` or `PUT` answers `400` without SCIM's error body.
- **Proof:** the plane's `scim_answers_test.exs`, through the router with the
  connector's bearer: a user's and a group's create with `Location` equal to
  `meta.location`, a person who signed in first created as the same row, a replace's
  `200`, a delete's `204` and `404` for an unknown and a malformed id on users and
  groups, a `PUT` with `active: false` stopping a sponsored principal (and refusing
  sign-in) and the same `PUT` again leaving its `disabled_at`, and a `PUT` with
  `active` true or absent leaving it running. The creates, the unknown delete and the
  stop failed on the tip. `scim_entra_test.exs`, `scim_connector_test.exs`,
  `subject_claim_test.exs` and `web_test.exs` asked for `200` or either on a create,
  and now ask for `201`.
