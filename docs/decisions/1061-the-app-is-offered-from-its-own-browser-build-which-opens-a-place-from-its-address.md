---
number: 1061
title: "The line that offers the desktop app is the app's own browser build's, not the console's; the browser build opens a session or an artifact from its address and writes where the person is back into it; a copied link names the web app beside the troupe:// line"
date: 2026-11-18
status: accepted
issue: 1118
supersedes: [1002]
paths:
  - clients/gui/apps/desktop/src/views/AppBanner.tsx
  - clients/gui/apps/desktop/src/links.ts
  - clients/gui/apps/desktop/src/App.tsx
  - clients/gui/apps/desktop/src/shell.ts
  - clients/gui/apps/console/src/views/OpenInApp.tsx
  - clients/gui/packages/client/src/deeplink.ts
symbols:
  - AppBanner
  - stepForAddress
  - sessionLinkText
  - artifactLinkText
gist: "Banner (same words, install, dismissal per version, phone) moves from the console shell to the desktop browser build, never in Tauri; #/session/<id> and #/artifact/<id> under the app's base open the place or say why in stepFor's line, held in sessionStorage across a redirect sign-in, written back with replaceState while signed in; #daemon= is parameters, a place is never; console keeps per-row Open in the app, which says itself when nothing opened; copied links add <plane.app>/#/<kind>/<id>; private session's console line is #/sessions/invited/<id>"
---

Narrows Decision 1002's "every web surface offers the desktop app". The console is the
surface with no twin in the app; the desktop app's browser build, served at the plane's
`/app`, is the one whose reader is better off in the app. So the line moves there: drawn at
the top of the shell and the launcher when `inDesktopApp` is false, with the place's link
(`session/<id>`, `artifact/<id>`, `open`, each with `?plane=` of the plane signed in to, and
`open` with none before one is). Its words, install fallback from `plane.downloads` (read
from the sign-in's discovery), dismissal per recommended version and phone variant are
1002's. The docs theme keeps its own line. The console keeps "Open in the app" on session
rows and artifact cards, since an administrator may have the app; with no banner left to
hand the install to, the link says beside itself that nothing opened, with the installer.

The browser build reads `#/session/<id>` and `#/artifact/<id>` at load and on `hashchange`.
An address names a place on the plane this web app signs in to and is followed as that
plane's `troupe://` link would be (`stepFor`), so a refusal, Local only and "Sign in
there?" are the same sentences; a session is asked of the plane first, and one gone or not
shared says so (`SESSION_GONE`), and the address gives way to where the person is. A place waiting for a sign-in is held in `sessionStorage`,
because a browser's sign-in leaves the page and returns to the bare address. While signed
in, the app writes the place back with `replaceState` (no history entry), so copying the
address is a web link; under Local only it writes none, since the address would refuse itself.

A fragment starting `#/` is a place; any other is parameters, where `#daemon=` is adopted
and removed as before, and a place left alone. A place is never read out of parameters, so the two do not
compete and a combined fragment is not supported.

`sessionLinkText` and the artifact share text add `<plane.app>/#/<kind>/<id>` where
discovery names an app. A private session's console line stays, pointed at
`#/sessions/invited/<id>` where 0.43 moved the page: the web app holds no keys of this
computer and cannot read a sealed session; the console reads it through the relay.

Not chosen: keeping the banner in the console beside the app's (two surfaces arguing over
one person); a query string or path route (nginx would need a rule per place, and a path
leaks to the server log). Undone, a browser reader of `/app` is never offered the app, a
web link opens the launcher instead of the place, and copied links send people without the
app to a `troupe://` line that does nothing.
