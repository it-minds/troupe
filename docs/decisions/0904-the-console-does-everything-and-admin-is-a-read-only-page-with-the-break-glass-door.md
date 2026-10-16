---
number: 904
title: "The console draws every area the LiveView console had, and `/admin` is a read-only page and the break-glass door, whose one change is putting sign-in and the admin settings back to the deployment's"
date: 2026-10-16
status: accepted
issue: 56
supersedes:
  - 892
  - 901
paths:
  - apps/troupe_plane/lib/troupe/plane/web/admin_router.ex
  - apps/troupe_plane/lib/troupe/plane/web/admin_moved.ex
  - apps/troupe_plane/lib/troupe/plane/web/live/overview.ex
  - apps/troupe_plane/lib/troupe/plane/web/live/layout.ex
  - apps/troupe_plane/lib/troupe/plane/web/index.ex
  - apps/troupe_plane/lib/troupe/plane/admin/console.ex
  - apps/troupe_plane/lib/troupe/plane/github.ex
  - apps/troupe_plane/test/troupe/plane/panel_test.exs
  - apps/troupe_plane/test/troupe/plane/console_coverage_test.exs
  - apps/troupe_plane/test/troupe/plane/console_walkthrough_test.exs
  - clients/gui/apps/console/src/nav.ts
  - clients/gui/apps/console/src/owed.ts
  - clients/gui/apps/console/src/views/Integrations.tsx
  - clients/gui/apps/console/src/views/Identity.tsx
  - clients/gui/apps/console/src/views/IdentityProvider.tsx
  - clients/gui/apps/console/src/views/Policy.tsx
  - clients/gui/apps/console/src/views/Pods.tsx
  - clients/gui/apps/console/src/views/Hosts.tsx
  - clients/gui/apps/console/src/views/Budgets.tsx
  - clients/gui/apps/console/src/views/Connections.tsx
  - clients/gui/apps/console/src/views/Unbuilt.tsx
  - clients/gui/apps/console/test/coverage.test.ts
  - clients/gui/packages/client/test/support/admin.ts
  - docs/admin/console.md
gist: "/admin reads and resets sign-in and the admin group to the deployment's, nothing else; every method placed on a console area; no page links /admin"
---

#56 slice 4, decided by the maintainer on 2026-10-16: the console is completed with
Integrations (the GitHub App), Identity (people, groups, principals, duplicates), Policy and
settings, and Provisioners and hosts, and then the LiveView console at `/admin` becomes
break-glass only: a read-only page, the break-glass sign-in, and a link to `/console`. Its
editors and their routes go.

This takes back two things earlier slices said: Decision 892's "the LiveView console stays as
the way in when it cannot be used" (it stays, but only reads) and Decision 901's "every
LiveView page stays until the last slice" (this is the last slice).

## What the console draws now

Beyond slices 1 to 3: **Integrations**, **Identity**, **Sign-in**, **Policy and settings**,
**Workers and pods**, **Provisioners and hosts**, **Budgets** and **Connections**. The
maintainer's list named the first four and the hosts; the others are here too because the
LiveView pages that did them go in this slice, and an editor removed with nothing in its
place would be a capability the product stops having (a person's own cap, a pod's drain,
the identity provider's card, the SCIM token). Every write is previewed and confirmed as
before; what destroys or stops something is typed by its subject's name (a principal's
subject, a machine's name, a pod's name, the App's id, the SCIM base URL). A secret the
plane answers once is shown once, with a copy button, and the plane keeps only its hash.

- **Each role is shown what the plane answers it** (Decision 901's rule): Integrations and
  Identity become a team admin's too (the App and the hosts to read; their own team's
  principals). Pods, hosts, sign-in and connections stay a platform admin's.
- **The GitHub App gains two methods**: `admin.github.check` (four checks: an App id, that
  transit signs with its key, that GitHub knows the App by the JWT that key signs, that
  every installation set is one GitHub lists; writes nothing) and `admin.github.delete`
  (confirmed by the App id; forgets the row, so the App is unconfigured; the transit key
  stays, unused). The maintainer's "set it, read it, test it, and remove it" needed both,
  and neither could be done through `admin.github.put`.
- **`admin.profile.choices`** answers the provider types (the protocol's `wire/0`, Decision
  894's one list) and the size classes, so the profile editor offers them rather than free
  text and says what the chosen type asks for.
- **`owed.ts` keeps a trigger's run and key rotation** only: Runs and review and the key a
  new webhook trigger is made with are Decision 905's, in this chunk, and the two left are
  done over the admin API, which a trigger's page says. **Company memory** is unbuilt and
  has no method.
- **`admin.github.deliveries`** lists what the App's webhook took (Decision 905's
  `github_deliveries`) with what the plane did with each, a platform admin's, on
  Integrations beside the webhook secret, which `admin.github.put` takes and never answers.

## What `/admin` keeps

The OIDC sign-in and the break-glass door, unchanged, and the Overview page: the fleet, each
profile and each team's spend, read-only, linking into the console. Every other path that
was a page redirects to the same place in the console (`/admin/workers/dev` to
`#/profiles/dev`, `/admin/provider` to `#/signin`), or to `/admin` on a plane deployed
without the console, which that page says is administered with `troupe admin`, `/rpc` or
the admin MCP tools.

**One change remains, in a break-glass session only**: putting the sign-in settings
(`admin.provider.reset`) and the two settings that decide who administers
(`platform_admin_group`, `groups_claim`, `admin.setting.reset`) back to what the deployment
says, beside the identity check and sign-in as the plane holds it. That is a judgement this
slice makes, and the reason is Decision 664: the identity provider became editable from the
console because "the break-glass door opens the console without the provider; reset deletes
the row and the deployed value is back". A strictly read-only `/admin` would leave a
provider or an admin group saved wrong in the console with no way back but the database,
which is the thing break-glass exists to avoid. Nothing is typed there: a reset only ever
goes back to the floor the deployment set, and a value the deployment itself has wrong is a
Helm change and a rollout. If the maintainer wants `/admin` strictly read-only, the
`#repair` section of `Live.Overview` and its two events are what to remove; the runbooks in
`routine-tasks.md` and `authentik.md` then need the database or the deployment instead.

What break-glass can no longer do is *set* a value. `authentik.md`'s provider migration
used to set `platform_admin_group` from behind the glass; it now sets it in the deployment
and, where the console stored one, resets that.

## Where each method is done

`Troupe.Plane.Admin.Console` now places every method on an area of the console's map (the
same ids as `nav.ts`, in the same four groups) or gives a reason it is API-only. Its
`owed/0` and `unbuilt/0`, which held the LiveView console to its own debt, are gone: the
console's `owed.ts` is the one list of what is not drawn yet. The plane's
`console_coverage_test` checks that every method is placed and that every placement is on
an area of the map; the console's `test/coverage.test.ts` reads `console.ex` and checks that
its map is the plane's and that every placement is kept, called from a screen or owed on
that same area.

## What the LiveView tests proved

`panel_test.exs` kept its sign-in, role and overview tests and gained the break-glass page's
and the redirects'. What the removed pages' tests proved of the plane is in API tests
(`admin_test.exs`: integrations' hosts against the policy and notification targets checked
again, the identity check on the group given, the profile choices; `github_test.exs`: check
and delete) or already was (sponsors, budgets, the ladder, client versions, the enforced set,
gitops refusals, the audit chain, erasure, provisioner guarantees). What they proved of a
page is in the console's tests, against the fake plane. `console_walkthrough_test.exs` walks
an empty plane to a working one through the admin methods the console calls, as `/rpc`
dispatches them. `gitops_console_test.exs` and `gitops_triggers_console_test.exs` were
LiveView-only and go.

## Proof

On the chunk's tip `owed.ts` listed 31 methods across ten areas, nine areas of the map linked to
`/admin`, and `/admin` routed fifteen pages besides its overview. `apps/console/test`: `integrations`,
`identity`, `identity-provider`, `policy`, `operate`, `budgets` (with connections) and the
profile editor's choices, each against the fake plane, whose administrative half now
follows `Troupe.Plane.Admin` for these methods; `coverage.test.ts` against the shorter
`owed.ts` and the plane's placements. The plane suite with `KUBECONFIG=/nonexistent`.
