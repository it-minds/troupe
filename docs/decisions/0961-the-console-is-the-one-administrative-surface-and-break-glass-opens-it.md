---
number: 961
title: "The console is the one administrative surface: break-glass is a plane token the console's sign-in screen asks for, the plane's LiveView app and its own OIDC flow are gone, and the registration needs no secret"
date: 2026-10-28
status: accepted
issue: 56
supersedes: [886, 904]
paths:
  - apps/troupe_plane/lib/troupe/plane/web/router.ex
  - apps/troupe_plane/lib/troupe/plane/web/admin_moved.ex
  - apps/troupe_plane/lib/troupe/plane/web/index.ex
  - apps/troupe_plane/lib/troupe/plane/breakglass.ex
  - clients/gui/apps/console/src/views/SignIn.tsx
  - clients/gui/apps/console/src/views/Shell.tsx
  - clients/gui/packages/client/src/auth.ts
  - docs/admin/console.md
  - docs/admin/roles-and-permissions.md
symbols:
  - Troupe.Plane.Breakglass.verify/2
  - Troupe.Plane.Breakglass.actor/1
  - Troupe.Plane.Web.AdminMoved
gist: "Break-glass is POST /auth/breakglass answering a plane token marked breakglass; no plane admin pages or OIDC flow; /admin redirects; no client secret"
---

## What was there

The console at `/console` (Decision 886) did everything, and the plane kept a LiveView app
of its own at `/admin` for one day: the day the identity provider cannot let anybody in.
Decision 904 cut that app down to a read-only overview, the break-glass door
(`GET`/`POST /admin/breakglass`, a signed cookie) and one repair, putting sign-in and the
two settings that decide who administers back to the deployment's. Behind it stood the
plane's own authorization-code flow (`/admin/login`, `/admin/callback`, `/admin/denied`,
`/admin/logout`), which needed a confidential client and a client secret at the provider,
and 886 said in so many words that break-glass "is the LiveView console's, a cookie rather
than a token, and stays there". That sentence is what this decision takes back; the rest
of 886 stands. Decision 904 is superseded whole: its page, its door and its router are
what this decision removes, and the one repair it kept is the console's now.

Two surfaces for one job cost more than the day they were kept for. The LiveView app had
its own design system, its own tests, its own sign-in and its own policy exceptions
(inline style, a second cookie), all to show a page the console already showed; its one
repair was a second, narrower editor for settings the console edits; and the provider
registration carried a secret and a redirect URI that existed only for it.

## What changes

- **The door opens the console.** `POST /auth/breakglass` with `{"token": ...}` answers a
  plane token minted for the break-glass subject with the claim `breakglass: true`, its
  `expires_at` and its `subject`. The compare is the constant-time one the HTML door made,
  a wrong token is `403 {"error": "refused"}` and audited with the remote address as
  before, and a door that is not configured answers 404 like a path that does not exist;
  `/.well-known/troupe` says `breakglass` so a client knows whether to offer it. Every
  `/rpc` and `/mcp` call made with that token resolves to the platform admin with no teams
  that the cookie session resolved to, and `me` answers `breakglass: true` so the console
  can mark every screen. The token's expiry ends it and nothing refreshes it: a break-glass
  session is still one that is ended by waiting.
- **The console's sign-in screen has a second way in, "Break glass"**, offered when the
  plane says the door is configured. The token the plane answers is kept as the plane token
  is kept, for the tab, and the shell says on every screen that this is a break-glass
  session. A break-glass session is a platform admin in the console, so what is wrong with
  sign-in or with who administers is fixed where it is set, behind the same checks, rather
  than through a repair page of its own.
- **The LiveView app and the plane-side OIDC flow go.** `GET /admin` and `GET /admin/<old
  page>` redirect to the console (`Troupe.Plane.Web.AdminMoved`), or on a plane deployed
  without one show a short page saying the plane is administered over the admin API. The
  door works there too: the token it answers is a plane token like any other, for
  `troupe admin` and `/rpc`.
- **The registration is a public client's.** With no plane-side redemption there is no
  confidential client, no client secret and no `/admin/callback`: only the single-page
  application redirect URIs the console and the GUI already needed. The `client_secret`
  setting and `TROUPE_OIDC_CLIENT_SECRET` are kept one release, documented as read by
  nothing, and then removed, so a deployment that sets them still starts.

## Choices not taken

- **Keeping a read-only page on the plane.** It would have kept the LiveView stack, the
  second design system and the second sign-in for a page the console draws, and a
  read-only page cannot repair what break-glass exists to repair. Decision 904's reasoning
  for its one repair, that a value saved wrong in the console must have a way back short
  of the database, holds; the way back is now the console itself, opened by the door.
- **A console that works without a sign-in.** A console open to anybody who reaches the
  plane's host would be the escalation the audited door exists to prevent; break-glass is
  loud because using it is a token someone holds, not a page someone finds. A console with
  a sign-in that the provider cannot refuse keeps every change under an actor the audit
  names.

## Proof

- `apps/troupe_plane/test/troupe/plane/breakglass_test.exs`: the discovery flag, the
  exchange for the right token and the refusal and audit for a wrong one, 404 when the door
  is not configured, and a token marked `breakglass` resolving at `/rpc` and `/mcp` to the
  platform admin with no teams that `me` reports as break-glass, and refused once expired.
- `clients/gui/apps/console/test/breakglass.test.tsx`, against the fake plane:
  *Break glass* offered only when the plane says the door is configured, the exchange made
  through the sign-in screen, every screen marked, and the sign-in screen back once the
  token has run out.
- `clients/gui/packages/client/test/breakglass.test.ts`: the client library's break-glass exchange and
  the token kept and presented as a plane token, with nothing refreshing it.
