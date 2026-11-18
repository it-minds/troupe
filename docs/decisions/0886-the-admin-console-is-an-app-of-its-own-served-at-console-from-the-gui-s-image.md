---
number: 886
title: "The administrative console is an app of its own in the GUI's workspace, built into the GUI's image and served at its own path on the plane's host by an Ingress of its own; it signs in with the plane's own sign-in and calls `admin.*` and `me` and nothing else"
date: 2026-10-12
status: accepted
issue: 56
paths:
  - clients/gui/apps/console/
  - clients/gui/packages/client/src/admin.ts
  - clients/gui/scripts/fake-console.ts
  - clients/gui/Dockerfile
  - clients/gui/docker/nginx.conf
  - charts/troupe/templates/gui-deployment.yaml
  - charts/troupe/values.yaml
  - apps/troupe_plane/lib/troupe/plane/settings.ex
gist: "Console: own app (imports nothing of desktop, nor it of console), GUI image at /console/, own Ingress and console.enabled; plane sign-in (PKCE), tab-scoped; only admin.* and me"
---

The maintainer decided on 2026-10-12 that the console is its own app: not part of the
desktop GUI, which must be usable without a plane, as the console must be without the GUI;
on the GUI's stack (React, Vite and TypeScript in the `clients/gui` workspace, on
`@troupe/client` and the Afterglow tokens); talking only to the `admin.*` surface; and the
LiveView console at `/admin` stays until the new one covers what it does.

## The app

`clients/gui/apps/console` is `@troupe/console`, a package of the workspace beside
`apps/desktop`. It depends on `@troupe/client` and the fonts and nothing of the desktop
app's, and the desktop app depends on nothing of it; `test/boundary.test.ts` reads both
apps' sources and manifests and fails on an import either way. The design tokens and the
mark are generated into each app (`pnpm tokens` writes `src/tokens.css` and `src/mark.ts`
in both, and `tokens:check` diffs both) rather than imported across, and `pnpm icons`
writes the console's favicon from the same mark in Afterglow's values, which `icons:check`
holds.

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
  to its own origin and, over TLS, to the identity provider.

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
- **Break-glass** is the LiveView console's (`/admin/breakglass`), a cookie rather than a
  token, and stays there.
