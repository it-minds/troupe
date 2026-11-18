---
number: 996
title: "`/dismiss`, `/merge`, `/discard`, `/observer` and `/worktree` are `availability` `tui`, which the desktop app leaves out; a `tui` row keeps what the terminal client needs for it in `availabilities`, chosen by `for_client/2` as a client's own words are; and `/hq` has the desktop's words"
date: 2026-11-15
status: accepted
issue: 929
paths:
  - apps/troupe_core/lib/troupe/commands.ex
  - clients/gui/packages/client/src/types.ts
  - clients/gui/apps/desktop/src/views/CommandPalette.tsx
symbols:
  - Troupe.Commands.for_client/2
gist: "branch, window and agent-tree commands are tui rows; availabilities holds the terminal's own need; /hq says the desktop's sessions list"
---

Issue #929. After #921 the desktop palette still listed `/dismiss`, `/merge`, `/discard`,
`/observer` and `/worktree` greyed, each with a reason, and `/dismiss` named windows the
desktop app has not got. None of them has anything there to act on: the desktop starts no
branches, so it has no worktree of one to merge or throw away and no window to let go of,
and it has no agent tree. `/hq`'s detail said it names a plane by URL, which the desktop's
`/hq` (the sessions list) does not read. This amends Decision 984 in two places.

- **The five are `tui`.** Decision 984's "not chosen" kept `/merge` and `/observer`
  greyed so a person learns them from the list, and because a later desktop might run
  them. That holds for a command a client could run in some session; these name things
  the desktop app has not got, which DESIGN.md §8 asks to be left out, as `/quit` is. When
  a desktop app runs one, its row changes back in this table. An installed desktop build
  that filters `tui` rows hides them from the day the harness ships.
- **The terminal client keeps its own need.** `availability` is one value, and `tui`
  alone would make the terminal client treat `/merge` as `always`, so it would stop
  greying it on a pod's session. A `tui` row that needs more there carries
  `availabilities`, a map from a client's name to its own `availability`
  (`/merge`, `/discard` and `/worktree` `{"tui": "local"}`, `/dismiss` `{"tui":
  "window"}`), present only on such rows. `Troupe.Commands.for_client/2` replaces the
  row's `availability` with the client's own as it does `summary` and `detail`, so the
  terminal client's palette, `troupe --help` and `mix troupe.cli.reference` read what they
  read before and `docs/user/cli-reference.md` does not change. The desktop app applies
  its own (`desktop`) the same way before it leaves `tui` rows out. A row from a harness
  before the map has none and reads as it did. `/observer` needs nothing more and has
  none.
- **`/hq` on the desktop.** A `desktop` summary and detail: the sessions list, the
  plane's sessions by team and profile beside this computer's own, with no plane named by
  URL. Its usage and example are the table's still (984 chose no `usages` map; the desktop
  drops only a `window` argument).
- **Not chosen.** A `clients` list beside `availability`, which 984 turned down for the
  reason it gives; a compound value (`tui+local`), which every client would have to parse
  and an older desktop would show as an unknown requirement rather than hide.

**Proof.** `Troupe.CommandsTest` ("the commands of branches, windows and the agent tree
are the terminal client's, with its own needs kept"; the `/hq` lines of "each client reads
its own words"); `clients/gui/apps/desktop/test/command-palette.test.tsx` ("leaves out the
terminal client's branch rows, and judges a row by this app's own availability"). Each
failed before the change.
