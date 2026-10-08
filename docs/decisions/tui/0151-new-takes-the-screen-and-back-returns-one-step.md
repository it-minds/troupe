---
number: 151
title: "`/new` puts a new session on the screen in the window's own process and the one it left carries on; `/back` returns to the session focused before, one step either way, as `cd -` does"
date: 2026-10-08
status: accepted
issue: 484
paths:
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/client/remote.ex
  - clients/tui/test/troupe/new_session_test.exs
  - clients/tui/test/troupe/command_palette_test.exs
  - clients/tui/test/support/fake_remote.ex
symbols:
  - Troupe.Client.fork_session/1
  - Troupe.Client.get_session/2
gist: /new and /back swap the session the one window shows (adopt), never a second window; back is one session id, set by every switch
---

Issue #484, root Decision 812. The TUI shows one session at a time, and switching was
already one function: `adopt/2` unsubscribes, subscribes and rebuilds the screen from the
other log (Decision 65). `/new` and `/back` are two more ways into it, not a second window
or a tab bar.

- **`/new`.** `--private` and no flag create a session in the directory on screen with
  `worktree: "never"`, as `troupe` and `troupe --private` do; with a plane's session on
  screen, in the directory the window was opened in (`home`), which is also what the
  picker now lists then, where it listed nothing. `--remote PROFILE` creates one on the
  plane this machine is signed in to (`Client.default_plane/0`), as HQ's wizard does, with
  its defaults. `--branch` is `Client.fork_session/1`: the daemon's `session.fork` for a
  session on this machine, the plane's for a pod's. Anything else is the usage line. The
  new session takes the screen with the command line focused and empty: what is typed
  first is its opening message, which is the "optional goal or opening message" the issue
  asked for, given by the input that is already there.
- **The session left carries on.** `adopt/2` lets go of a session nobody typed into, as it
  always did (Decision 65's scratch session), and keeps every other attached and
  running. The picker lists the session `/back` would return to even when it did nothing,
  so the session `/new` left is always in it.
- **`/back` is one step.** `back` is the session focused before this one, set by every
  switch (`/new`, `/resume`, the picker, HQ), and going back makes this one the way back:
  `/back` twice is where you were. No stack: `/sessions` lists the rest, and a stack is a
  second list to keep in step with the first. A local session is read again first
  (`Client.get_session/2`, `session.get`) and refused as the picker refuses it (root
  Decision 812), then opened if the daemon had let go of it; a plane's session is still
  attached, and is put back on the screen.
- **A bare `new` or `back`** at the start of a line runs the built-in, as every built-in's
  name does on the command line today; `command_palette_test.exs` leaves `new` out of its
  walk over every built-in, as it leaves `worktree`, since it starts a session.
- **Proof:** `new_session_test.exs`: `/new` takes the screen, the first keeps running and
  both are in the picker, `/back` returns and `/back` again comes back (failed on the tip:
  `/new` did nothing); `/new --branch` shows the conversation so far, its log opens with
  `session_forked`, it has no parent, and its first model request carries the parent's
  reply while the parent never hears the line typed in the fork; `/new --private` is
  listed private; `/new --remote code` and `/new --branch` on it against `FakeRemote`
  (which now answers `session.fork`), and `/sessions <id>` home from there; `/back` to a
  session erased meanwhile is refused with the sentence and the screen stays. Not tried
  against a plane.
