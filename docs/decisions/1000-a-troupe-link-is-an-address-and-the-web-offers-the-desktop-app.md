---
number: 1000
title: "A troupe:// link is an address and nothing more: three forms, refused whole when it carries anything else, a new plane confirmed in words before any request; and every web surface offers the desktop app, from the version the plane recommends"
date: 2026-11-16
status: accepted
issue: 959
paths:
  - clients/gui/packages/client/src/deeplink.ts
  - clients/gui/apps/desktop/src-tauri/src/deep_link.rs
  - clients/gui/apps/desktop/src-tauri/src/lib.rs
  - clients/gui/apps/desktop/src-tauri/Cargo.toml
  - clients/gui/apps/desktop/src-tauri/tauri.conf.json
  - clients/gui/apps/desktop/src-tauri/capabilities/default.json
  - clients/gui/apps/desktop/src/links.ts
  - clients/gui/apps/desktop/src/App.tsx
  - clients/gui/apps/desktop/src/views/SignIn.tsx
  - clients/gui/apps/console/src/views/AppBanner.tsx
  - clients/gui/apps/console/src/views/Shell.tsx
  - apps/troupe_plane/lib/troupe/plane/client_versions.ex
  - apps/troupe_plane/lib/troupe/plane/web/router.ex
  - docs/overrides/main.html
  - PROTOCOL.md
symbols:
  - parseAppLink
  - appLink
  - followAppLink
  - Troupe.Plane.ClientVersions.downloads/0
gist: "troupe://open|session/<id>|artifact/<id> with ?plane=<https url> only; any other parameter, a fragment, userinfo or a non-https plane refuses the whole link in one line; a plane not signed in to opens the sign-in filled in with 'This link is for <host>. Sign in there?' and nothing is sent until Sign in; the shell only checks scheme and length. /.well-known/troupe gains plane.downloads (recommended desktop version + three installers) and plane.console; the console and docs banner opens or installs, dismissed per recommended version"
---

#959 gives the desktop app a URL scheme and every web surface a way into it. Three things
were open, and each is settled here.

- **What a link may carry.** Exactly three forms, each a place the app already shows:
  `troupe://open?plane=<url>`, `troupe://session/<id>?plane=<url>`,
  `troupe://artifact/<id>?plane=<url>`; `open` may leave the plane out (the docs site has
  none), and then only brings the app forward. `plane` is the one parameter, an `https`
  address (http only for this computer, as in development) with no user, password, query
  or fragment; an id is the plane's own shape and never a path. Anything else, a `token`
  or a `code` included, refuses the **whole** link rather than following it with the rest
  ignored: a link that carries more than Troupe writes is not one Troupe wrote, and
  following its harmless part would teach people that such links work. The refusal is one
  line in the window and nothing else happens. The parser is the client package's
  (`parseAppLink`), so the desktop app, the console and any later client read a link the
  same way; the shell checks only the scheme and a length (`deep_link.rs`), keeps what came,
  and makes no request because of a link.

- **A plane the app is not signed in to.** The sign-in screen, with the address filled in
  and "This link is for <host>. Sign in there?", and no request to that plane until the
  person presses Sign in: the click is the confirmation the issue asks for, in words, before
  the first sign-in. A sign-in kept for another plane is not restored meanwhile. Signed in
  to another plane, the window asks first ("Sign out and sign in there" or "Stay here")
  rather than leaving it. Signed in to that plane, the app goes straight to the place. Under
  Local only no plane link is followed, said in a line. A link opens only what the person
  may already see: a share link's key stays in its `https` line, and the `troupe://` line
  copied under it opens the artifact once the `https` one has given the role.

- **Where the banner's downloads come from.** The discovery document, which anybody may read,
  gains `plane.downloads`: the `desktop` component's recommended version, its release page,
  and the installer each platform's installer step puts there (`_x64-setup.exe`,
  `_universal.dmg`, `_amd64.AppImage`), from `client_release_url` when the plane names it
  and GitHub's release otherwise; and `plane.console`, for the console's page copied beside
  a session's link. The recommended version is what a page offers, not a refusal, so a
  reader without a sign-in learns nothing the signed `me.client_versions` keeps back (the
  `/downloads` route's reason for its bare 404 stands). Nothing installs from it: the app's
  own update still reads the signed policy.

The banner's "did it open" is a guess, said in `followAppLink`'s comment: the page losing
focus or sight within 1.5 s counts as opened. Chrome's own "Open Troupe?" question takes the
focus too, so a person who cancels it is not offered the install, and a slow app reads as
not installed; both links stay in front of them either way. Dismissal is kept in
`localStorage` under the recommended version, so a new recommendation shows it again. No
banner inside the desktop app (`__TAURI__` or `__TAURI_INTERNALS__` present).

The scheme is registered by each installer from `tauri.conf.json`; only an AppImage, which
has no installer, registers it at start (`APPIMAGE` set). A debug or developer build
registers nothing, so it never takes the scheme from the app a person installed; it reads a
link passed as its one argument, which is how Windows and Linux hand one over, and that is
how it is tried by hand. The single-instance plugin, with its `deep-link` feature, hands a
second launch's link to the running window; it is not registered in a debug build, so there
a link starts a second copy.
