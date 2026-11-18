---
number: 954
title: "A person's artifacts and memory are theirs to see and change in their own app: the desktop app has an Artifacts gallery and a Memory view beside Sessions, read through this computer's daemon, which forwards the plane's artifact.get, artifact.open, artifact.share, artifact.unshare, artifact.rollback and artifact.pin and the person's me.memory.history and me.memory.rollback as them and refuses all of them under Local only; an artifact is shown from its own host in a child window of the shell's, granted nothing and kept on that host, never fetched into the app; and memory is read as entries, one per ## Topic, the closest level's replacing the lower ones"
date: 2026-10-26
status: accepted
issue: 62
paths:
  - clients/gui/apps/desktop/src/views/Artifacts.tsx
  - clients/gui/apps/desktop/src/views/OwnMemory.tsx
  - clients/gui/apps/desktop/src-tauri/src/artifact_window.rs
  - apps/troupe_gateway/lib/troupe/gateway/artifacts.ex
  - apps/troupe_gateway/lib/troupe/gateway/memory.ex
symbols:
  - Troupe.Gateway.Artifacts.forward/2
  - Troupe.Gateway.Memory.history/1
  - Troupe.Gateway.Memory.rollback_own/1
gist: "Desktop Artifacts + Memory via the daemon's forwarded artifact.*/me.memory.*, refused under Local only; artifact shown only in a child window granted nothing; memory as ## Topic entries"
---

Issue #62 and #55, as the maintainer decided them on #765 on 2026-10-26: "The console is
the administrators' panel. What is a person's own — their artifacts, what is shared with
them, their memory — is seen and edited in the desktop app and the terminal."

## Through the daemon, as the person

The app reads both through this computer's daemon and its sign-in, as "Publish…" and the
Instructions pane already did: the daemon is signed in whether or not the app is (offline,
say), and it is what hands a new memory version to the sessions running here. So the daemon
gains the methods the app lacked, each the plane's method of the same name sent on with the
arguments it takes and nothing else (`Troupe.Gateway.Artifacts.forward/2`): `artifact.get`
and `artifact.open` (`observe`, as on the plane), `artifact.share`, `artifact.unshare`,
`artifact.rollback` and `artifact.pin` (`control`). A refusal keeps the plane's own code and
data, so the app tells `not_found` from `forbidden` from `conflict` as it would at the plane;
signed out, or a plane from before the method, is `unavailable` with a sentence. Only a view
or edit link is forwarded (`id, role, expires`); a public link stays the console's.

The person's own memory had no history a person could ask for: the console's side-by-side
and rollback are `admin.memory.*`, which refuse the user scope (Decision 943). So the plane
gains `me.memory.history {version?, against?}` (every version, one beside another, the line
diff, as `admin.memory.get` answers them) and `me.memory.rollback {to, version}` (version
`to`'s text as the next version over the one in force, audited as `memory.put` with
`rolled_back_to` and its note, so `blame/2` keeps who wrote each line), both the caller's own
alone, and the daemon forwards them (`control`: the text is the person's). The daemon's
`me.memory` now carries `documents` beside the person's own, the organisation's and their
teams' from the same signed answer, which the Memory view sets theirs against.

**Local only** (Decision 951): every one of these is refused to a client in Local only, as
`artifact.*` and `me.memory` were; the app asks none of them while its switch is on, says
"Local only: the plane is not asked", and shows what `me.memory.status` says this computer
holds.

## Shown from its own host, in a window granted nothing

Decision 948's isolation holds in the app as in a browser: an artifact's files are never
fetched into the app's origin, which holds the daemon's token. **Open** asks `artifact.open`
at the click and hands the one-time `/enter?ticket=` address to the shell's
`artifact_window_open`, which opens a child webview window at it (`artifact_window.rs`). The
artifacts host redeems the ticket for its own cookie, first-party in that window, and serves
the page under its sandboxed policy. The window is granted nothing: the app's capability names
the main window alone, and a remote page has no IPC. It stays on the host it was opened at
(`on_navigation`); a link anywhere else, or a page's new window, goes to the person's own
browser. One window per artifact, so another version (`/v<n>/`, by `artifact.open {version}`)
reuses it. The shell accepts https only, http only on this machine, and no user in the URL.

Chosen over an iframe because the app's CSP then needs no `frame-src` at all (it stays as it
was), and the host's cookie is first-party in its own window, which a browser that blocks
third-party cookies would withhold from a frame. A browser build of the app opens the address
in a tab of its own instead.

The Instructions pane no longer edits the person's memory in place; it lists it as a layer
and opens *Memory* (this narrows Decision 943's "the desktop app's Instructions pane,
edited in place" to the Memory view).
