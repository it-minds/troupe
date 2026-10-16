---
number: 909
title: "The plane reads no request body over four mebibytes on any route, refusing one by its declared length before reading it; a plane with a control certificate takes TLS only unless told `false`, and warns when it takes plaintext; removing the GitHub App deletes its key and webhook secret from transit; and the desktop app counts as running only a daemon that answers `initialize` with the file's token, started off the window's thread"
date: 2026-10-16
status: accepted
supersedes: [904, 906]
paths:
  - apps/troupe_plane/lib/troupe/plane/web/body_limit.ex
  - apps/troupe_plane/lib/troupe/plane/web/endpoint.ex
  - apps/troupe_plane/lib/troupe/plane/web/router.ex
  - apps/troupe_plane/lib/troupe/plane/control/tls.ex
  - apps/troupe_plane/lib/troupe/plane/control/listener.ex
  - config/runtime.exs
  - charts/troupe/templates/plane-deployment.yaml
  - apps/troupe_plane/lib/troupe/plane/github.ex
  - apps/troupe_plane/lib/troupe/plane/github/key.ex
  - apps/troupe_plane/lib/troupe/plane/github/webhook_secret.ex
  - apps/troupe_protocol/lib/troupe/kms/policy.ex
  - clients/gui/apps/desktop/src-tauri/src/daemon.rs
  - apps/troupe_plane/test/troupe/plane/body_limit_test.exs
  - apps/troupe_plane/test/troupe/plane/control_tls_test.exs
  - apps/troupe_plane/test/troupe/plane/github_test.exs
  - docs/admin/github.md
  - docs/admin/configuration.md
symbols:
  - Troupe.Plane.Web.BodyLimit
  - Troupe.Plane.Control.TLS.required?/0
  - Troupe.Plane.GitHub.delete/1
  - Troupe.KMS.Policy.github_app/3
gist: "4 MiB body limit at the endpoint, 413 by Content-Length unread; with a control cert, TLS only unless \"false\"; App delete deletes its transit keys; alive = initialize answered"
---

A sweep of small defects from `docs/developer/defects.md` D128 and what the chunk 36
fixers noticed. Four of them change a rule somebody could undo without knowing why; the
rest are bugs with tests of their own and are named in the pull request.

**One limit on a request body, held where the body is read.** The endpoint parsed every
body with `Plug.Parsers`' own default, eight megabytes, before either router saw the
request, so the API router's four mebibytes never applied behind it: `/rpc`, `/mcp`, SCIM,
`/auth/exchange` and the GitHub App's webhook all read a stranger's 8 MB. Now
`Troupe.Plane.Web.BodyLimit` is the one number. It is plugged into the endpoint before the
parsers and refuses a body whose `Content-Length` is over it with `413`, before a byte of
the body is read; the parsers take the same `length`, so a body sent without one is read
only that far and is `413` too. The router keeps both for when it is mounted alone. Four
mebibytes stays the figure because `admin.bundle.publish` is the largest legitimate body.
A client that keeps sending a body after the refusal may see the connection close under
it rather than the answer; that is what "before it is read" costs.
`body_limit_test.exs` sends the head alone and is answered `413` on six routes.

**A plane with a control certificate takes TLS only, left unsaid** (partly replaces 906,
which turned it on in the chart alone, and through it 902's "unset is off").
`TROUPE_PLANE_CONTROL_REQUIRE_TLS` unset is now on wherever
`TROUPE_PLANE_CONTROL_TLS_DIR` is set and off where it is not, since a port with no
certificate can speak only plaintext; `"true"` and `"false"` say it outright. So a plane
deployed without the chart is no longer the one place plaintext is still taken by default.
The chart writes `"true"` or `"false"` whenever it mounts a certificate, rather than
omitting the variable when `requireTls` is off, which would now mean on. The control
listener's line at start is a warning whenever the port takes plaintext or has no
certificate to take TLS with, and stays information for TLS only.

**Removing the GitHub App deletes its key and webhook secret from transit** (partly
replaces 904's "the transit key stays, unused"). Transit adds a version to a key only of
the type it already has, so an App set again after a removal with a key of another size
(RSA 3072 after 2048) was refused `{:key_type, ...}` with nothing to do about it from the
plane. Rotating on the next set was the other choice, but the plane's policy names one key
for the App and one for the secret, so a key of another type would need a new name and a
policy change anyway; deleting needs only `delete` on each key and `update` on its
`config`, which `Policy.github_app/3` now grants and `docs/admin/github.md` shows. The
secret goes with it, so no delivery signed with it is taken after the App is gone. A role
whose policy predates this still removes the App: the row is deleted first, and a refused
deletion leaves both keys and says so in the plane's log, naming the missing paths.

**The desktop app counts as running only a Troupe daemon that takes the file's token.**
`alive` dialled the port `daemon.json` names and called anything that accepted a daemon,
so a port another program had taken since the daemon died kept the app from starting one
and sent it to a stranger. Now it upgrades `/v1/socket` and sends `initialize` with the
file's token, and only a result counts: a `101` that then refuses the token is a daemon
that is not the file's. Waiting for a daemon that said it stops (the update) still asks
only whether the port accepts (`listening`), because a daemon closing its files may stop
answering before it lets go of them. `daemon_start` is an async command whose wait runs on
a blocking thread: a synchronous command runs on the window's thread, and the window drew
nothing for up to thirty seconds while a daemon started.
