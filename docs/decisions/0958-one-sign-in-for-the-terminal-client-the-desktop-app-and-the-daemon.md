---
number: 958
title: "One sign-in for the terminal client, the desktop app and the daemon: the desktop app keeps its refresh token in the TUI's credentials.json under a shared lock, starts at that plane, and links a daemon nobody has linked when it connects"
date: 2026-10-27
status: accepted
supersedes: [710, 764]
paths:
  - clients/gui/apps/desktop/src-tauri/src/signin.rs
  - clients/gui/apps/desktop/src-tauri/src/secrets.rs
  - clients/tui/lib/troupe/remote/credentials.ex
  - clients/tui/lib/troupe/remote/tokens.ex
symbols:
  - TokenStore.lock
  - adoptSignedInPlane
  - Troupe.Remote.Credentials.with_lock/1
gist: credentials.json is the machine's one sign-in, rotated under credentials.lock by whoever refreshes; the desktop app reads it, starts at its plane, and links an unlinked daemon
---

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
