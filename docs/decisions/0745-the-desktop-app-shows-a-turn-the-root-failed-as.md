---
number: 745
title: The desktop app shows a turn the root failed as a failure, and follows a daemon that restarted to where it is now
date: 2026-10-01
status: accepted
paths:
  - clients/gui/apps/desktop/test/team-failed.test.tsx
gist: The desktop app shows a turn the root failed as a failure, and follows a daemon that restarted to where it is now
---

Defects D42 (the desktop app's part) and D41, following
727 and the redial of PR #263.
- **A failed turn is a failure wherever the app says how a session is.** `turn_ended`
  with `agent_failed` folds into the transcript as a note in the error colour, "the
  agent kept crashing and the session stopped: <detail>", and the session's status
  reads Failed, the detail on hover, until the next input starts a turn. A turn that
  ends any other way is still a rest and says nothing. A notification says "The turn
  failed: <detail>", in a loop too, since the loop stops with the session. A turn
  `tool_failures` ended is still shown only as the failure guard's question answered
  `stop`.
- **The daemon's listing says it, read from the log.** A session stops on a failed
  turn, so nothing live is left to report it, and an app that was not watching had a
  dormant row like a sleeping session's. `session.list` rows carry `failed`: `{reason,
  detail}` from the root's last `turn_ended` when that is `agent_failed` and no input
  has come since, otherwise null, read from the log as `interrupted` is. A field and
  not a new `status`, which every other reader of the status would meet unannounced.
  The launcher's row and the list's say Failed, and the notification for a session
  nobody is reading says the turn failed rather than that one finished. A plane's rows
  carry no reason, so a team session's row is as it was.
- **A redial reads where the daemon is.** A daemon that restarts serves a new port with
  a new token (`loopback.ex`), and the client dialled the old pair until a person
  pressed Find. `DaemonClient` takes `locate`, which it asks before dialling after a
  dropped socket or a failed dial, and dials what it answers; views open across it
  subscribe again from their cursors, as #263 made them. The desktop shell's
  `readDaemon` reads `daemon.json` with the command `findDaemon` reads it with, and
  starts nothing: starting is Find's, which a person asks for, and a daemon somebody
  stopped stays stopped. A browser build has nothing to read and dials where it was
  told.
- **Connected again when a dial works.** `useDaemon` said "not answering" when the
  socket closed and nothing said otherwise after; the client's `onOpen` does, with the
  address it reached, which This computer shows.
- D41's last item, whether Windows raises `Activated` in the running app for a click
  in the notification centre, is still unverified.
- **Proof:** the desktop app's `failed-turn` and `daemon-restart` tests and the
  client's `stage2`, `transcript` and `fleet` tests, against the fake daemon, which now
  restarts on a new port with a new token and lists `failed` as the daemon does;
  `crash_loop_test.exs` (listed, and cleared by the next turn) and the gateway's
  `daemon_test.exs` (over the socket).
