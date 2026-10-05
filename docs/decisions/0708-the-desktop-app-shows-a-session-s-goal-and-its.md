---
number: 708
title: The desktop app shows a session's goal and its loop in the session's head, marks what happened while nobody was reading, and says it with the operating system's notification
date: 2026-09-27
status: accepted
issue: 59
paths:
  - clients/gui
gist: The desktop app shows a session's goal and its loop in the session's head, marks what happened while nobody was reading, and says it with the…
---

Issues #59 (the GUI's part) and #119 (its "tell the person" box).
The harness had `/goal`, `/loop` and `unseen`, and the terminal client showed the
first two; the desktop app dropped `goal_*` and `loop_*` on the floor, printed a
loop's own input as the person's words, and read no `unseen`.
- **What the events say, in the head.** The fold keeps the goal from `goal_set`
  until `goal_cleared` and the latest loop from `loop_started` to `loop_stopped`,
  so the head follows any client's change as it happens. The goal sits under the
  title on one line, whole on hover and on a click; the loop sits beside the status,
  "iteration 2/5", with a stop that works mid-iteration. A loop's turn is a note,
  "loop iteration 2/5", not the words the loop gave the model, as in the terminal
  client. `session.loop.get` is asked once per attachment for the one case the log
  cannot say yet: a session that stopped mid-loop writes `interrupted` only when it
  wakes. A refusal is said in words, not as `conflict (-32006)`.
- **`unseen` is read at the door.** Opening a session subscribes to it, which is
  what clears it, so the line at the top ("while you were away: 2 turns finished,
  1 question waiting since 14:02") is the row as the list last showed it, kept for
  the visit until it is seen or answered. A request is `waiting` while the row still
  has one of its kind open and `asked` once it ended. The list marks a row with how
  many things, and the row the person opens loses its mark at once.
- **Notifications are the OS's, through the notification plugin.** A Tauri build of
  this app on Windows, at its own origin, answers `Notification.requestPermission()`
  with `denied` and never prompts, and `new Notification()` fires `error`: WebView2
  refuses the permission unless the host answers its `PermissionRequested`, and wry
  answers only the clipboard's. So `tauri-plugin-notification`, pinned to 2.4
  because 2.5 wants tauri 2.12, is reached through the shell contract, and a browser
  uses its own. The capability grants three verbs: whether it is allowed, ask, show.
- **When, and once.** News comes two ways and each is the only one for its case: a
  session nobody reads is told by its row's counts going up, whether or not the
  window is in front, since nothing on screen shows it; a session this window reads
  has an empty `unseen`, so its own events speak, after the replay and only while
  the window is not in front, and a loop's turns stay quiet until the loop ends.
  Counts are remembered per session and a request by its call id, which a waking
  session asks again under. Permission is asked once, on the person's first
  gesture, a refusal is kept, and a preference beside the appearance turns it off.
- **Not in this slice.** A plane's rows carry no `unseen`, so a team session tells
  only while it is open; clicking a notification does not open its session, which
  the plugin cannot report on a desktop; and the launcher's rows carry no marker.
  (Both are 714.)
- **Proof:** the desktop app's `goal-loop`, `away` and `notify` tests against the
  fake daemon, which now keeps the loop in its log and `unseen` beside it; the
  client's fold and row tests; the probe and the renamed installed build on the pull
  request.
