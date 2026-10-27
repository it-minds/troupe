---
number: 958
title: "One sign-in for the terminal client, the desktop app and the daemon: the desktop app keeps its refresh token in the TUI's credentials.json under a shared lock, starts at that plane, and links a daemon nobody has linked when it connects"
date: 2026-10-27
status: accepted
supersedes: [710, 764]
paths:
  - clients/gui/apps/desktop/src-tauri/src/signin.rs
  - clients/gui/apps/desktop/src-tauri/src/secrets.rs
  - clients/gui/apps/desktop/src-tauri/src/lib.rs
  - clients/gui/apps/desktop/src/shell-tauri.ts
  - clients/gui/apps/desktop/src/shell.ts
  - clients/gui/apps/desktop/src/main.tsx
  - clients/gui/apps/desktop/src/hooks.ts
  - clients/gui/apps/desktop/src/views/SignIn.tsx
  - clients/gui/apps/desktop/src/views/Local.tsx
  - clients/gui/packages/client/src/auth.ts
  - clients/tui/lib/troupe/remote/credentials.ex
  - clients/tui/lib/troupe/remote/tokens.ex
  - install.sh
  - install.ps1
symbols:
  - TokenStore.lock
  - adoptSignedInPlane
  - Troupe.Remote.Credentials.with_lock/1
gist: credentials.json is the machine's one sign-in, rotated under credentials.lock by whoever refreshes; the desktop app reads it, starts at its plane, and links an unlinked daemon
---

A person who signed in at the installer (`troupe config`, which runs `troupe login`)
opened the desktop app and was asked to sign in again, and having done so still could not
reach a private session's artifacts: the app said the daemon on this computer was not
signed in to a plane. Three stores and two rules made that: the TUI kept its refresh token
in `credentials.json`, the desktop app kept its own in the OS credential store (710), the
daemon's link was made only by a TUI session attaching (764), and the desktop app handed
its token only to a daemon already linked to the person, leaving the link to a control on
*This computer* that nobody found.

- **One store.** The desktop shell's `secretStore` is `credentials.json` in the Troupe
  config directory, in the TUI's shape and under the TUI's key for a plane (`signin.rs`
  mirrors `Troupe.Remote.Discovery.base/1`), `0600` on unix and an owner-only ACL on
  Windows, as the TUI writes it (TUI Decision 71). Both clients present the same
  `client_id`, the plane's, so a refresh token either took is honoured for the other. A
  sign-in made in either client is both clients', and signing out in either forgets it for
  both: `troupe logout` already tells the daemon to let go of the token, and *Sign out*
  does too (766). The OS credential store is read only to move a sign-in an earlier
  release kept there into the file, and is cleared once it is; 710's concern, which build
  reads which entry, is now about that migration alone, so 710 is superseded.
- **Why a file and not the keychain for both.** Providers rotate the refresh token on
  every use and refuse the old one; a copy seeded into a second store is retired at the
  first refresh from the first, so sharing means one copy, read before every refresh and
  written after. The TUI is an Elixir binary on three platforms with no keychain binding
  worth carrying for one entry, and has kept the token in a user-only file since 71; the
  desktop app can read the same file. The sign-in screen says where the token is kept
  (`capabilities().secrets` is `config-file`), as it said the keychain before.
- **One refresh at a time, across processes.** Two programs refreshing one rotating token
  at the same moment would have the second refused, and a provider that detects reuse may
  revoke both. So `credentials.lock` beside the file is a machine-wide mutex, created
  exclusively and removed after: the TUI's `Credentials.with_lock/1` around
  `Tokens.do_refresh`, which reads the file's token inside it rather than the one it
  loaded at start, and the desktop app's `TokenStore.lock`, optional on the interface and
  held inside the Web Lock `refreshStored` already takes, through `signin_lock` and
  `signin_unlock`. A lock older than a minute was left by a dead process and is broken;
  past fifteen seconds' wait the refresh goes ahead regardless, a sign-in that cannot be
  renewed being the worse outcome. A TUI whose file entry is gone (the desktop app signed
  out) answers `logged_out` rather than spend a token the other program gave up.
- **Starting at the plane.** Before the first render, the desktop shell seeds the
  `planeUrl` preference from the file's `current` plane where the app was told none
  (`adoptSignedInPlane`), so the sign-in screen restores from the stored token without a
  question. A plane the app was told before is kept, and local-only is untouched.
- **Signing in links the daemon.** `handOver` links a daemon nobody has linked, with the
  token, as this person at this plane, the way the TUI already did (764): signing in is
  the person asking, and a daemon left unlinked is one whose private sessions and
  artifacts no client can reach. A daemon linked to somebody else, or to this person at
  another plane, is still left alone; *This computer* remains for undoing a link and for
  a daemon that could not be reached at sign-in. That part of 764's desktop-app rule is
  superseded; the rest of 764 stands. `troupe login` links the daemon at once as well (TUI
  Decision 168), so the installer's sign-in reaches the daemon before any client opens.
- **Not done.** The daemon still signs nobody in and still holds the token in memory only:
  it could read `credentials.json` itself, but renewing a token is the client's business
  (764), and a daemon started at login is handed one by the first client to connect,
  which both now do. The browser build keeps `localStorage` and its own sign-in; it has
  no file to share.
- **Proof.** `signin.rs`'s tests (the file in the TUI's shape and key, `0600`, the TUI's
  labels kept across a rotation, `current` moving on a sign-out, the lock taken once and
  a stale one broken). The client library's `restore.test.ts` (a store's lock held
  around the refresh, the token read and written inside it). The desktop app's
  `private-link` test against the fake deployment (an unlinked daemon linked with an
  honoured token as the app connects; one linked to this person at another plane left;
  the private checkbox offered on the same connection) and `signin` test
  (`adoptSignedInPlane` seeds the plane and keeps one told before). The TUI's
  `remote_login_test` (a refresh spends the token another program rotated the file to,
  seen at the fake provider's token endpoint, and the lock is gone after; a refresh after
  the entry is gone is `logged_out`; the lock waits for its holder and breaks a stale
  one).
