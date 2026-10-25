---
number: 946
title: The GitHub App's OpenBao grant is optional on a plane that has no App and required once one is set up, so a plane whose App would stop signing is not reported healthy
date: 2026-10-25
status: accepted
issue: 765
supersedes: [934]
paths:
  - apps/troupe_plane/lib/troupe/plane/kms_check.ex
  - apps/troupe_plane/lib/troupe/plane/github.ex
  - apps/troupe_plane/test/troupe/plane/kms_check_test.exs
gist: The App's grant is required once GitHub.configured? holds (id, key, installation), optional before; the check, not Policy's list, decides
---

**Why.** Decision 934 made the plane check its OpenBao grants look-only from one list,
`Troupe.KMS.Policy.plane_grants/1`, and called the GitHub App's grant optional: a plane
without an App needs none of it, and missing it left the plane healthy. That holds only
before an App exists. Once one is set up, the grant is what signs the App's tokens and
checks its webhooks; without it "one set up before stops signing", as the grant's own text
says, and the console's Overview still showed the plane healthy, with the grant under
nothing that asked for attention. D134 and D135 recorded it: the grant was always
reported optional, an App configured or not.

**The decision.**

- **Required once there is an App.** `Troupe.Plane.KMSCheck.run/1` marks the `github-app`
  grant required when `Troupe.Plane.GitHub.configured?/0` holds: the App has an id, a key
  in transit and at least one installation, which is what `admin.github.get` already
  answers as `configured`. Before that it stays optional, and a missing one still says
  "(needed only for that)".
- **The check decides, not the list.** `plane_grants/1` is in `troupe_protocol`, which
  knows nothing of a plane's App, and `mix troupe.openbao.policy` writes
  `docs/admin/openbao.md` from it; the page already says the grant is "only with a GitHub
  App". So the list keeps `required: false` and the check, which runs on the plane, turns
  it on. The role line a plane that cannot log in is given lists the required policies,
  so it names the App's too once there is an App.
- **An App half set up is not one.** An id without a key, or a key without an
  installation, signs nothing yet; the grant is optional until all three are there, and
  importing the key is what fails meanwhile, with the refusal `admin.github.put` gives.

The rest of Decision 934 stands.

**Proof.** `kms_check_test.exs`: with a token that holds every required grant and not the
App's, the plane is healthy and the grant optional with no App row, and not healthy, the
grant required and its sentence without "(needed only for that)", once an App row with an
id, a key version and an installation exists. The second test failed on the chunk's tip
(`ok: true`, `required: false`) before the change.
