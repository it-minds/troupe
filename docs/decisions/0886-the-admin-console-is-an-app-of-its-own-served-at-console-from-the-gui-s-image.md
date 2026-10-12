---
number: 886
title: "The administrative console is an app of its own in the GUI's workspace, built into the GUI's image and served at its own path on the plane's host by an Ingress of its own; it signs in with the plane's own sign-in and calls `admin.*` and `me` and nothing else"
date: 2026-10-12
status: accepted
issue: 56
paths:
  - clients/gui/apps/console/
  - clients/gui/packages/client/src/admin.ts
  - clients/gui/packages/client/test/support/admin.ts
  - clients/gui/scripts/fake-console.ts
  - clients/gui/Dockerfile
  - clients/gui/docker/nginx.conf
  - charts/troupe/templates/gui-deployment.yaml
  - charts/troupe/values.yaml
  - apps/troupe_plane/lib/troupe/plane/settings.ex
  - docs/admin/console.md
gist: "Console: own app (imports nothing of desktop, nor it of console), GUI image at /console/, own Ingress and console.enabled; plane sign-in (PKCE), tab-scoped; only admin.* and me"
---

#56 slice 1. The maintainer decided on 2026-10-12 that the console is its own app: not
part of the desktop GUI, which must be usable without a plane, as the console must be
without the GUI; on the GUI's stack (React, Vite and TypeScript in the `clients/gui`
workspace, on `@troupe/client` and the Afterglow tokens); talking only to the `admin.*`
surface; and the LiveView console at `/admin` stays until the new one covers what it does.
This records where it is served, how it is signed in to, and what slice 1 holds.

## The app

`clients/gui/apps/console` is `@troupe/console`, a package of the workspace beside
`apps/desktop`. It depends on `@troupe/client` and the fonts and nothing of the desktop
app's, and the desktop app depends on nothing of it; `test/boundary.test.ts` reads both
apps' sources and manifests and fails on an import either way. The design tokens and the
mark are generated into each app (`pnpm tokens` writes `src/tokens.css` and `src/mark.ts`
in both, and `tokens:check` diffs both) rather than imported across, and `pnpm icons`
writes the console's favicon from the same mark in Afterglow's values, which
`icons:check` holds. `pnpm build`, `typecheck` and `test` are the workspace's, so CI's GUI
job covers it with no change.

Development is `pnpm console:fake` and `pnpm console`, as the desktop app's is `pnpm fake`
and `pnpm dev`: the identity provider and plane the tests use, with the plane's
administrative half (`packages/client/test/support/admin.ts`) seeded with three teams,
a version policy and an organisation's document, signing a browser in as a platform
admin, a team admin or nobody (`CONSOLE_AS`). That half follows `Troupe.Plane.Admin`, not a
screen: the roles, `not_found` for a team that is not a team admin's, the ladder's
refusal with the ceiling quoted, and every write answering and recording the audit's diff.

## Where it is served: the GUI's image, at `/console/`, with an Ingress of its own

The image `clients/gui/Dockerfile` builds carries the console's bundle beside the desktop
app's web build, at `/console/` in nginx's root, with its own SPA fallback and the same
`headers.conf`. The chart's `console:` block (`enabled: true`, `basePath: /console`) adds
an Ingress on the plane's host that rewrites `basePath` to `/console/` on the GUI's
Service; the one Deployment runs while either `gui.enabled` or `console.enabled` is on,
each has its own Ingress, and the chart refuses a console at `/` or at the GUI's path.
`TROUPE_CONSOLE_BASE` (default `console`) is baked into the bundle as `TROUPE_GUI_BASE`
is, for the same reason.

- **Not its own image.** A new image is a new registry package, which is private until an
  organisation's administrator says otherwise (a chart pulling it fails until then), a
  matrix entry in the images and release workflows, and a Deployment of its own in every
  cluster, all for a few hundred kilobytes of static files with nothing to configure. The
  apps stay apart where it matters, in the code and in the chart's switches.
- **Not the plane serving it.** The plane's release would grow a Node build stage and ship
  a bundle on the Elixir release's path; its pages carry the plane's policy, which allows
  inline style for LiveView, where the GUI's image sends the app's stricter one.
- **Its origin is the plane's own.** Its calls to `/rpc`, `/auth/exchange` and
  `/.well-known/troupe` are same-origin, so `plane.corsOrigins` needs nothing. It opens no
  socket to a worker, so `operator.workerAllowedOrigins` (Decision 884) needs nothing
  either.
- **Its policy is the app's** (Decision 803): the bundle has no inline script and no style
  attribute (`boundary.test.ts` checks the page), its fonts are bundled, and it connects
  to its own origin and, over TLS, to the identity provider. The production build was run
  under `headers.conf`'s headers with no violation.

## How it is signed in to: the plane's own sign-in, and no new token

The console signs in exactly as the GUI's browser build does: the identity provider's
authorization code flow with PKCE from the page (`AuthSession`, `flow: "redirect"`),
then `/auth/exchange`, then the same short-lived plane token every client holds. There is
no admin-scoped token, and none was invented: the plane works out the actor on every
`admin.*` call (`Admin.actor_for/1`), a platform admin from the configured provider group
and a team admin from the teams a platform admin named them on, so a role taken away holds
at the next call. The provider must allow `https://<plane host><console.basePath>` as a
single-page application's redirect URI; the sign-in screen names it when a provider
refuses.

- **The refresh token is kept for the tab** (`sessionStorage`, under keys of its own), not
  in `localStorage` as the GUI's browser build keeps its own: an administrator's sign-in
  that ends with the tab is one fewer thing left behind on a shared machine. A reload keeps
  it; a new tab is a redirect to a provider the person is signed in to and back.
- **What it calls.** Discovery, the provider and the exchange to sign in; `me`, once, for
  who is signed in and whether they are a platform admin; and `admin.*` for everything
  else. A team admin is somebody `admin.teams.list` answers for; somebody it refuses for
  want of a role is told they administer nothing rather than shown a console of refusals.
  `signin.test.tsx` records every request through a real redirect and fails on any other
  method.
- **Break-glass** is the LiveView console's (`/admin/breakglass`), a cookie rather than a
  token, and stays there.

## What slice 1 holds

The shell: the brief's map in four groups (Watch, Configure, Operate, Govern), the area a
role cannot use hidden rather than disabled, a deep link to every screen and team tab,
who is signed in to which plane, light and dark, and a loading, error and empty state for
every read. An area not drawn yet says what it is for and links to the same area in the
current console. Every change is previewed (the diff, and what it does in words), then
confirmed, plainly where it can be changed back and by typing the team's name where it
erases (a shorter `erase_after_days`); the plane's refusal is shown where it was made; and
the change's audit diff, as the write answered it, is shown once applied.

- **Client versions** (`admin.clients.get`, `admin.clients.put`, Decision 868): per
  component the plane answers for, the recommended version, the minimum and the blocked
  list; changed by a platform admin, read by either.
- **The organisation's document** (Decision 869): the *client defaults* settings with where
  each came from, changed and reset through `admin.setting.put` and `reset`; and the
  enforced set, edited key by key. **The keys are the plane's**: `admin.settings.list` now
  carries, on the `client_enforced` setting, `enforceable`, each key the protocol's
  `Organisation` lists with its kind (`ceiling`, `order` with its order, `fixed`), what it
  means to a machine, and the type its value takes. The console builds its fields from
  that, so a key the protocol adds appears with no console change and none is offered that
  the plane would refuse; against a plane without the list it shows the set as stored.
- **Teams** (`admin.teams.list`): the list, searched, and a team in the brief's tabs,
  *Members and groups*, *Access*, *Admins*, *Limits* and *Danger zone*, each read. Limits
  shows every value in force with the rung that decided it and the ladder behind it (the
  team's `effective`), and edits through `admin.team.update`, quoting the ceiling before
  it is sent. The danger zone, a platform admin's, reads `admin.team.disable.preview`.

## Left for slice 2

The other edits the team tabs name stay in the current console, and each tab says so:
linking and unlinking a group (with `admin.team.unlink.preview`), granting and revoking a
profile (revoking warns of the sessions it turns read-only), naming and removing a team
admin, enabling a group as a team, and removing a team behind its typed name. Then the
other areas in the brief's order, the command palette, and the plane's index and `/admin`
pointing at the new console once it covers them.

## Proof

- `apps/console/test`: the boundary; the redirect sign-in against the fake provider and
  plane with every method recorded, the tab-scoped store and sign-out, a team admin's and
  a non-admin's consoles; the shell's map, identity, deep links, a hidden area's address,
  light and dark, and the loading, error-with-retry and empty states; each screen's read,
  preview, confirm, refusal and audit note, and a team admin's read-only views.
- On the chunk's tip there was no `apps/console` (`pnpm --filter @troupe/console build`:
  no project matched), the chart rendered no console (the chart job's new step failed on
  it), and `client_defaults_test.exs`'s new test failed on the `enforceable` list.
- `client_defaults_test.exs`: the list as JSON, its keys in the protocol's order, and each
  kind and type.
- In a browser, against the fake plane: `pnpm console:fake` with `pnpm console`, and the
  production build served at `/console/` under `headers.conf`'s headers on the fake
  plane's origin, signed in through the redirect, every screen in dark and light, a limit
  and the enforced set changed through preview and confirm, as a platform admin and as a
  team admin, with no console message.
