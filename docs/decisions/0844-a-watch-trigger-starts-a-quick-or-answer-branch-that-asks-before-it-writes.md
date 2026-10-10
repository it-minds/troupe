---
number: 844
title: "A saved AI! or AI? comment starts a quick or answer branch of the watching session, in its checkout, never a turn of its own agent; the branch asks before every write unless watch_auto_approve is on; watch state is on the protocol"
date: 2026-10-10
status: accepted
issue: 502
paths:
  - PROTOCOL.md
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_core/lib/troupe/watch.ex
  - apps/troupe_core/lib/troupe/watch/branch.ex
  - apps/troupe_core/lib/troupe/session/watcher.ex
  - apps/troupe_core/lib/troupe/session.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/config/schema.ex
  - apps/troupe_core/test/troupe/watch/watch_branch_test.exs
  - apps/troupe_core/test/troupe/watch/watch_session_test.exs
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/test/troupe/gateway/watch_test.exs
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/test/troupe/watch_client_test.exs
symbols:
  - Troupe.Watch.Branch.start/2
  - Troupe.Watch.Branch.hold_auto/1
  - Troupe.Session.Watcher
  - Troupe.set_watch/3
  - Troupe.watch_state/1
  - Troupe.Client.adopt_branch/4
gist: "AI! -> quick, AI? -> answer, as a branch in the checkout, never the root; its writes ask unless watch_auto_approve; watch.get + watch_changed + watch_triggered"
---

Issue #502's `/watch` paragraph and D106, which the command audit
([command-audit.md](../developer/command-audit.md)) found: since the daemon split, a
trigger went to the session's own agent (`Session.Watcher`'s `agent_path`) with the
session's permissions, so an `AI!` and `/quick` were two paths, the work landed in the
session's own window whichever was activated, nothing on the screen said a trigger was
taken, and no client could ask whether a session watched. On the tip, a core test of an
`AI!` saw the root agent take the `watch` input and its edit run unasked under the test's
`auto_approve`.

## Where a trigger goes

- **A branch, never the root.** Each debounced scan that finds `AI!` or `AI?` comments
  starts one session whose `parent` is the watching session (`Troupe.Watch.Branch`), on
  `quick` when any comment is a change and on `answer` when all are questions: the agents
  TUI Decision 67 sent them to. The watching session's agent is told nothing.
- **In the checkout.** The branch works in the watching session's workspace, not a fresh
  worktree: the comment, and usually the code it is about, are in files there that need
  not be committed, and a small local change is wanted where the person is looking, not
  on a branch to merge. It starts with what the watching session was started with (its
  config overrides, its scripted model in a test), and with `watch: false`: it works in the
  files the watcher sees and must not watch them itself.
- **Under the plan permission set for `AI?`.** The trigger is the branch's first input, as a
  `watch` input, so an all-question trigger runs its turn with `turn_mode: :question`. That
  mode now keeps the agent's own definition — model, prompt, turns — and narrows it to the
  tools `plan` also has, with `plan`'s `deny` entries over its own. Before, it swapped in
  `plan` whole, which on an `answer` branch would have meant `plan`'s default model and
  delegation for a one-line question, the cost Decision 67 was made to stop.
- **One branch per marker at a time.** A marker (file and comment) whose branch has not
  ended its turn is not sent again: an editor saves again while the branch's write waits
  for the person, and that is the same request. The watcher follows each branch's events
  as one of the session's own followers and forgets its markers at its `turn_ended`, or
  when its session goes.
- **Said in the log.** The watching session writes `watch_triggered` (`agent`, `mode`,
  `markers` as `{file, line, comment}`, and `session_id`, or `error` when no branch could
  start). Durable, because it is part of what happened in the session and a client that
  was not attached opens the branch from it.
- **No `watch.change_command` / `watch.question_command`.** Decision 67 had them because
  "quick and cheap" is a judgement about the repository. That judgement is now made by
  redefining `quick` or `answer` in `.troupe/agents/` (or the person's own `agents/`),
  which the definitions ladder already gives (Decisions 822, 826). Two settings naming
  another agent would be a second way to say the same thing, and would make an `AI!` and
  `/quick` two paths again, which #502 asks to be one.

## What a trigger may do unasked

Anything that writes a file can write an `AI!` comment: a pull, a generator, a formatter,
another tool, a dependency's post-install step. With watch on, that is a change turn the
person did not ask for. So the branch a trigger starts asks before every write, edit and
shell command, whatever `auto_approve` says and whatever the agent's own `permissions`
say: it runs with `auto_approve: false`, and every definition it runs under has its `auto`
entries taken out (`Branch.hold_auto/1`, the way Decision 825 holds back a workspace's
until it is trusted), so each such tool asks by its own default.

`watch_auto_approve` (boolean, default `false`, trusted scope, so a project's file sets it
only in a trusted workspace, as `auto_approve`) turns that off: the branch then runs
`auto_approve: true` and its agents' `auto` entries apply. It is its own key so that
turning `auto_approve` on for the work a person types does not also hand it to whatever
writes a comment.

Not covered here: an MCP server's own `permission: auto` (Decision 830) still applies in a
trusted workspace. The built-in `quick` and `answer` name their tools and name no server's,
so it applies only to a redefined one that lists a server's tools.

## Where watch runs

A pod's session never watches, whatever its config says: watching is for files on the
person's own machine, and a branch it started there would be a session no plane placed.
`Session.Watcher` starts no backend there and refuses `set_enabled(true)` (`:not_local`;
`watch.set` answers `forbidden`, "watch mode runs where the files are").

## Watch state on the protocol

- **`watch.get {workspace}`** (`observe`, the daemon's) answers `{"enabled", "backend",
  "session_id"}`: whether the workspace is watched, by `native` or `poll`, and by which
  session (`backend: "off"` and a null `session_id` when none).
- **`watch_changed {enabled, backend}`**, ephemeral, on the session whose watch went on or
  off or changed backend (a native backend that died falls back to polling).
- **`watch.set` takes `session_id`**, the session that watches. Without it, the workspace's
  session that is no branch (a trigger's branch is in the same checkout, and before this
  the first active session in the listing was taken, which could be the branch). A second
  session may not take watch from the one that has it (`conflict`, as before); the one that
  has it asking again is answered as it stands; off turns off whichever session watches,
  where it used to turn off the first session listed.

## Clients

The terminal UI opens a `watch_triggered`'s branch as it opens one `/quick` started
(`Troupe.Client.adopt_branch/4`: the journal records the window, the branch's worker
publishes under its name), once per branch, and the line under the screen says
`watch: calc.ex:1 "make this 42" started quick-1`; the session's own transcript says the
same with the agent's name. Its status line reads `watch.get` when the screen opens and
follows `watch_changed`, and `/watch` toggles from what the daemon says, so a watch the
desktop app turned on shows here and is turned off by the next `/watch`. A `watch_notice`
(polling, or watch could not start) is a line under the screen too. The desktop app needs
no change for this: it shows a branch session of its workspace as it does any other.

## Proof

`Troupe.Watch.WatchBranchTest` (an `AI!` starts `quick` in the checkout and its edit asks
though the session auto-approves; an `AI?` starts `answer` and its write attempt is refused
under the plan permission set though `watch_auto_approve` is on; `watch_auto_approve` lets
the edit run; a trusted workspace's `quick` with `edit_file: auto` still asks; a marker is
not sent again while its branch works, and is once it has ended),
`Troupe.Watch.WatchSessionTest` (`watch_changed`, `watch_state`, a branch in the checkout
never chosen to watch, a pod's session refusing), `Troupe.Gateway.WatchTest` (`watch.get`,
`watch.set` with `session_id`, the conflict, `forbidden` on a pod) and
`Troupe.WatchClientTest` in the terminal UI (the branch's window, the line, the asked
write, the status line following another client's watch).
