---
number: 954
title: "A person's artifacts and memory are theirs to see and change in their own app: the desktop app has an Artifacts gallery and a Memory view beside Sessions, read through this computer's daemon, which forwards the plane's artifact.get, artifact.open, artifact.share, artifact.unshare, artifact.rollback and artifact.pin and the person's me.memory.history and me.memory.rollback as them and refuses all of them under Local only; an artifact is shown from its own host in a child window of the shell's, granted nothing and kept on that host, never fetched into the app; and memory is read as entries, one per ## Topic, the closest level's replacing the lower ones"
date: 2026-10-26
status: accepted
issue: 62
paths:
  - clients/gui/apps/desktop/src/views/Artifacts.tsx
  - clients/gui/apps/desktop/src/views/OwnMemory.tsx
  - clients/gui/apps/desktop/src/views/Instructions.tsx
  - clients/gui/apps/desktop/src/views/Publish.tsx
  - clients/gui/apps/desktop/src/App.tsx
  - clients/gui/apps/desktop/src/shell.ts
  - clients/gui/apps/desktop/src/shell-tauri.ts
  - clients/gui/apps/desktop/src-tauri/src/artifact_window.rs
  - clients/gui/apps/desktop/src-tauri/src/lib.rs
  - clients/gui/apps/desktop/src-tauri/capabilities/default.json
  - clients/gui/apps/desktop/src-tauri/tauri.conf.json
  - clients/gui/packages/client/src/entries.ts
  - clients/gui/packages/client/src/artifacts.ts
  - clients/gui/packages/client/src/daemon.ts
  - apps/troupe_gateway/lib/troupe/gateway/artifacts.ex
  - apps/troupe_gateway/lib/troupe/gateway/memory.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/memory.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - PROTOCOL.md
  - docs/user/artifacts.md
  - docs/user/memory.md
symbols:
  - Troupe.Gateway.Artifacts.forward/2
  - Troupe.Gateway.Memory.history/1
  - Troupe.Gateway.Memory.rollback_own/1
gist: "Desktop Artifacts + Memory via the daemon's forwarded artifact.*/me.memory.*, refused under Local only; artifact shown only in a child window granted nothing; memory as ## Topic entries"
---

Issue #62 and #55, as the maintainer decided them on #765 on 2026-10-26: "The console is the
administrators' panel. What is a person's own — their artifacts, what is shared with them,
their memory — is seen and edited in the desktop app and the terminal." Decisions 948 and 950
gave the plane artifacts and the console a gallery; 943, 947 and 951 gave each person a memory
document, its history in the console's editor and its blame. The desktop app had "Publish…"
and the person's memory edited in place in a session's Instructions pane, and nothing else of
either. This records how the app shows and changes them, built to the maintainer's two
designs (the Afterglow mocks of the gallery and of the memory view).

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

## The gallery

To the maintainer's design: "// THE REPERTOIRE", a search, audience chips with a dot per how
far each reaches and a count (All, Everyone, Your teams, Shared with you, Only you), cards in
a grid grouped Today, This week and Earlier, each a striped placeholder with its kind and
size, *NEW TO YOU*, the title, who and when, an audience pill and the kind; and an aside for
the chosen one: kind, version and size, Open and Copy link, who can see it, where it came from
(by, the session, opened in the app, the profile), its versions (each opened, and for its
owner or an edit link's holder rolled back to, and for its owner pinned), the owner's live
links with a revoke, and "Publish a new version" (the existing "Publish…" with that artifact
chosen). A card is the title and the kind, never the page. *Copy link* is a view link made now
for the owner (`artifact.share`) and the address for anybody else. *Change who can see it*
opens the console's page for it, since moving visibility is not forwarded.

Everyone is `organisation`; Your teams is `team:<name>` (Decision 953) and `profile:<name>`;
Shared with you is `scope: "shared"`, a link's; Only you is `private`. Until a plane answers
`scope` per row the app reads it off the row (`scopeOf`) and asks `artifact.list {shared:
true}` for the links' ids; that shim goes once every plane says it. *NEW TO YOU* is a version
this device has not opened, kept in its storage alone: no new plane state.

## Memory as entries

To the maintainer's design and decision of 2026-10-26: a level's document is entries, one per
`## Topic` section (any text before the first heading is an entry with no topic); on a topic
the closest level's entry replaces the lower ones, the person's own over a team's over the
organisation's. *In effect for you*, for one of the person's teams, lists the winner on each
topic with what it REPLACES struck through. Each level has a tab (◉ ◎ ○, a count, *· READ* on
those the person may not change here, "LOWEST ‹ CLOSEST"); the person's own has *Add a memory*,
Edit and Forget (confirmed inline), the clash warnings (a topic already there; a lower level's
it will replace) and the SAVES TO line, and saves the whole document over the version read
(`me.memory.put`); a `conflict` shows the other version's text and offers to reload it. Its
*Versions* drawer has every version, any two side by side, a rollback, who wrote each line
(`me.memory {blame}`), `me.memory.status`'s current or behind and what each session running
here read. A `config.changed` for memory (a save elsewhere, an agent's `remember`) reads it
again. The entries are parsed and the in-effect list computed in the client
(`packages/client/src/entries.ts`) until the plane answers entries itself; then that shim goes.

The organisation's and the teams' levels are *READ* here for everybody for now: changing them
is `admin.memory.*`, which the daemon does not forward. The Instructions pane no longer edits
the person's memory in place; it lists it as a layer and opens *Memory* (this narrows Decision
943's "the desktop app's Instructions pane, edited in place" to the Memory view).

## Proof

- `apps/troupe_plane/test/troupe/plane/own_memory_history_test.exs`: every version, any two
  side by side, `not_found`; a rollback as the next version audited with `rolled_back_to` and
  its note and no text, an agent's entry's lines keeping their session and agent, `conflict`
  over a replaced version; a service principal refused. Failed on the chunk's tip
  (`e544a82f`): `method_not_found`.
- `apps/troupe_gateway/test/troupe/gateway/artifacts_test.exs`: the six forwarded, signed out
  `unavailable` with nothing sent, signed in each reaching the plane with exactly its
  arguments, refusals keeping `not_found` and `forbidden`. `plane_memory_test.exs`:
  `me.memory`'s `documents`; history and rollback through the daemon, the copy asked again,
  `conflict` kept. `local_only_test.exs`: all eight refused under Local only. Failed on the tip
  with `method_not_found`.
- `clients/gui/apps/desktop/test/artifacts-gallery.test.tsx`: the chips' counts, the filters
  and the search; no frame, picture or request of the artifacts host in the app; Open handing
  the ticket to the shell's window with the artifact's id; *NEW TO YOU* until opened; the
  owner's view link, version, pin, rollback and revoke; Local only asking nothing.
  `own-memory.test.tsx`: in effect with REPLACES; READ marks; add, edit and forget saving the
  whole text over the version; a conflict with the other version and a reload; the drawer's
  side by side, rollback, blame and standing; an agent's entry read again; Local only asking
  nothing. `instructions-view.test.tsx`: the pane opening *Memory*.
- `clients/gui/apps/desktop/src-tauri/src/artifact_window.rs`'s tests: the addresses refused
  and accepted, the window kept on its origin, the command registered and the capability naming
  the main window alone.
