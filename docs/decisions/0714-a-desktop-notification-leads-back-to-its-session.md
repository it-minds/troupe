---
number: 714
title: A desktop notification leads back to its session, the launcher marks what was missed, and a first run's plane is signed in to without being asked for again
date: 2026-09-27
status: accepted
issue: 119
paths:
  - clients/gui/apps/desktop/src-tauri/src/notify.rs
gist: A desktop notification leads back to its session, the launcher marks what was missed, and a first run's plane is signed in to without being asked…
---

Issues #119 and #76, following 708, 705 and 709, with D26's GUI half.
- **The click where it is reported, the window coming back where it is not.** A
  browser's `Notification` reports a click: it brings the window forward and opens
  the session. `tauri-plugin-notification` does not on a desktop, in 2.4 or 2.5: it
  shows the toast through notify-rust in a task of its own and drops the handle
  whose `wait_for_response` would hear the click, and its `onAction` listens on a
  channel only the phone plugins feed. So in the shell, the window coming to the
  front within 15 seconds of a notification said while it was not is taken as the
  answer to it, however it came forward, and opens the session the last one was
  about. Windows itself can report the click, through the toast's own `Activated`
  event, but only for a toast the shell shows itself rather than the plugin, which
  it now does (730).
- **The launcher's recent rows carry the list's marker**, "2 new" with the sentence
  behind it, from one component the two screens share.
- **The plane's address is asked once.** A first run that chose a plane and was
  given its address ends on the sign-in screen signing in to it: the field is
  filled, and the provider's page or its code comes next, unless the store already
  holds a sign-in for it. An address kept from an earlier sign-in only fills the
  field, since signing out is not a request to be signed in again.
- **Signing back in is a start.** After signing out, the next sign-in in the same
  run lands on the launcher, or on the list for a person who chose it (709).
- **A session is finished when its root agent is.** A subagent's `agent_done`, and
  one a restore ended `interrupted`, is its own agent's state and a note in the
  transcript, not "Finished" in the session's head (D26).
- **A dropped socket reopens a team session in `read` mode.** `SessionAttachment`
  opens in the mode it is asked for, reconnects in `read` as PROTOCOL.md §6 says,
  and follows a pod's `not_found` for an activating command in `activate`. Since
  707 a subscribed session is never put to sleep, and the reconnection's backoff
  (about 19 seconds) ends well inside the two-minute unwatched clock, so a session
  no longer falls asleep on its own while a view is attached; what reconnecting in
  `activate` still did was place again, at once, a session that a drain or a
  replaced pod had left asleep. A session on this computer never went through the
  plane and wakes for nothing a subscription does.
- **A local view is listened to before it subscribes.** `DaemonClient.open` takes
  the caller's listener and attaches it before `subscribe` is sent, and `close`
  takes it off again. A replay can arrive in the same read as the subscription's
  answer, before `open` resolves; a screen that listened once it had the view saw
  no history in Node, and in a browser only because each message is a task of its
  own.
- **Proof:** the desktop app's `notify` (a click, the window back soon after, and
  too late), `launcher` (the marker, and gone once read), `signin` (a first run's
  plane signed in to with nothing pressed, a kept address that waits, and sign-out
  and back to the launcher or the list) and `history` (a seeded session's replay)
  tests; the client's fold, `move` and `stage2` tests; the command palette's with
  `/loop` in the fakes' table; and the renamed desktop build installed from its
  setup, on the pull request.
