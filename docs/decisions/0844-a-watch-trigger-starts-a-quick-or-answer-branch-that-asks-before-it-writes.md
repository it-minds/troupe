---
number: 844
title: "A saved AI! or AI? comment starts a quick or answer branch of the watching session, in its checkout, never a turn of its own agent; the branch asks before every write unless watch_auto_approve is on; watch state is on the protocol"
date: 2026-10-10
status: accepted
issue: 502
paths:
  - apps/troupe_core/lib/troupe/watch.ex
  - apps/troupe_core/lib/troupe/watch/branch.ex
  - apps/troupe_core/lib/troupe/session/watcher.ex
symbols:
  - Troupe.Watch.Branch.start/2
  - Troupe.Watch.Branch.hold_auto/1
  - Troupe.Session.Watcher
  - Troupe.set_watch/3
  - Troupe.watch_state/1
  - Troupe.Client.adopt_branch/4
gist: "AI! -> quick, AI? -> answer, as a branch in the checkout, never the root; its writes ask unless watch_auto_approve; watch.get + watch_changed + watch_triggered"
---

## Where a trigger goes

- **A branch, never the root.** Each debounced scan that finds `AI!` or `AI?` comments
  starts one session whose `parent` is the watching session (`Troupe.Watch.Branch`), on
  `quick` when any comment is a change and on `answer` when all are questions: the agents
  TUI Decision 67 sent them to.
- **In the checkout.** The branch works in the watching session's workspace, not a fresh
  worktree: the comment, and usually the code it is about, are in files there that need
  not be committed, and a small local change is wanted where the person is looking, not on
  a branch to merge.
- **Under the plan permission set for `AI?`.** The trigger is the branch's first input, as
  a `watch` input, so an all-question trigger runs its turn with `turn_mode: :question`.
  That mode now keeps the agent's own definition — model, prompt, turns — and narrows it
  to the tools `plan` also has, with `plan`'s `deny` entries over its own.
- **No `watch.change_command` / `watch.question_command`.** Decision 67 had them because
  "quick and cheap" is a judgement about the repository. That judgement is now made by
  redefining `quick` or `answer` in `.troupe/agents/` (or the person's own `agents/`),
  which the definitions ladder already gives (Decisions 822, 826). Two settings naming
  another agent would be a second way to say the same thing, and would make an `AI!` and
  `/quick` two paths again, which #502 asks to be one.

## What a trigger may do unasked

Anything that writes a file can write an `AI!` comment: a pull, a generator, a formatter,
another tool, a dependency's post-install step. With watch on, that is a change turn the
person did not ask for. So the branch a trigger starts asks before every write, edit,
shell command and MCP server's tool, whatever `auto_approve` says and whatever the agent's
own `permissions` and a server's `permission: auto` say. It runs with `auto_approve:
false` and is started with `hold_auto`: every definition it runs under has its `auto`
entries taken out (`Branch.hold_auto/1`, in `Session.build_opts/1`), and every MCP server
it starts has its `permission: auto` set back to `ask` (`Troupe.Session.MCP`), the way
Decisions 825 and 830 hold back a workspace's until it is trusted.

`watch_auto_approve` (boolean, default `false`, trusted scope, so a project's file sets it
only in a trusted workspace, as `auto_approve`) turns that off: the branch then runs
`auto_approve: true`, and its agents' and servers' `auto` entries apply.

`watch` itself has trusted scope too: a repository's own `.troupe/config.yaml` turns watch
on only in a workspace the person trusts, so a clone cannot make every comment in it start
work. The person's own file, `--watch`, a client's `session.create` config and `watch.set`
are not affected.

## Where watch runs

A pod's session never watches, whatever its config says: watching is for files on the
person's own machine, and a branch it started there would be a session no plane placed.
