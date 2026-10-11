---
number: 158
title: A branch's worker registers again, as it starts, what its journal says the branch still asks, budget questions included; `/new --branch` forks the activated branch or says which it needs; a conflicted merge says it was aborted; a window that goes leaves the focus; a branch's row names its model, a dismissed one is titled by its first prompt, and a subagent by its own agent
date: 2026-10-11
status: accepted
issue: 502
paths:
  - clients/tui/lib/troupe/remote/worker.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/test/troupe/command_seams_test.exs
symbols:
  - Troupe.Client.Daemon.dismissed_branches/1
  - Troupe.Client.dismissed_branches/1
gist: "A restarted branch worker re-registers its open asks from its journal; /new --branch never forks command mode's empty log; focus leaves a window that went"
---

D113 in `docs/developer/defects.md`, with what D105 and D107 left in command mode (#502).
Command mode (TUI Decision 155) and the branch commands over the daemon (root Decision
843) left these seams; each choice below is the one the slot did not settle.

- **An approval asked before a branch's worker restarted.** The parent's screen answers a
  branch's approval through `Client.Daemon.call_target/2`, which finds the branch by a
  `{:call, parent, call_id}` registration the branch's worker made as the request went by.
  It died with the worker: a crash and the supervisor's restart, or the session left and
  opened again (`reopen_branches/1`), and the new worker resumes its subscription past the
  request, so `y` went to the parent's own session and the branch waited for ever.
  *Re-registered, not routed by the event's session:* a worker that starts as a branch
  (`as:` set) reads its journal once and registers every call still asked, an ask with no
  answer after it. The answer stays one lookup, the cost falls where the journal is
  already read whole (opening a session rebuilds the screen from every branch's journal),
  and no screen or approval box changes. Routing by the event would have meant carrying
  the branch's own session id on the event the parent's screen gets and through the
  approval box, which another slot owns, or reading every branch's journal at each answer.
  The budget question (`budget_ask_started`) was never registered at all, so a branch's
  went to the parent's session even without a restart: it is one of the asks now.
- **`/new --branch` in command mode** forks the branch whose window is activated (typed in
  its box, or the palette's `/new` taken into it), its own session through `session.fork`
  (root Decision 812); the session itself from its own window, on a pod, or when its own
  agent has work and is listed (a `troupe run`). With no window activated and the work in
  the branches it forks nothing and says which window to open (`open its window (1
  build-1) and type it there`), or that no branch has started. *Not chosen:* a `--branch
  <window>` argument, which would change the command table's row and its generated help
  for what the window's own box already does.
- **A merge that conflicted** was aborted by the daemon and the checkout left as it was
  (Decision 647), so "resolve in your checkout" sent the person to resolve nothing. The
  notice says the merge was aborted and the checkout is as it was, to merge the branch by
  hand, then `/discard` the window; the window and its worktree stay. The window's own
  line says the same.
- **A window that goes while it is activated** (`/merge`, `/discard`, `/dismiss` picked
  from the palette over it, a cancel at rest) returns the screen to the command line when
  its `window_dismissed` arrives, rather than leaving a focus that names it until the next
  key.
- **A branch's row names the model it runs**, as its own agent's replies name it
  (`llm_response`'s `model`, resolved: `quick`'s is the cheap one), in the row's muted
  figures before its tokens and cost; nothing before its first reply. *Not chosen:* the
  agent file's alias from `agents.list` (`cheap`), which the screen does not hold in
  command mode and which is not the model.
- **A dismissed branch's picker row** is titled `build-1, dismissed: <first line of its
  prompt>`, its first input when it was opened with none, rather than the daemon's title
  for its session, which is the worktree it worked in.
- **A subagent is labelled with its own agent** in the window's side panel and the
  observer (`explore#1 (explore)`, not the window's `build`): `agent_named`, which a
  subagent's `agent_started` brings, names that agent; the window's own agent's name
  follows it too, as its header already did.
- **`read_branch`'s input** is drawn in words: `the branches`, the branch's id, `subagent
  <path>`, and `, with its diff`, rather than its JSON.

Proof: `clients/tui/test/troupe/command_seams_test.exs`, each failing on the chunk's tip
(f74b3c6) first: the approval answered after the branch's worker was killed and started
again reaches the branch and its file is written (on the tip the answer went to the
parent and `approval_answered` never came); a branch's budget question answered from the
parent's screen (on the tip, never answered); `/new --branch` on the command line says
there is nothing to fork, then names `1 build-1`, and from `build-1`'s box forks the
branch, whose reply is in the fork's log (on the tip it forked the empty session at once);
the conflicted merge's notice and line; the focus after the palette's `/merge`,
`/discard` and `/dismiss`; `quick-1`'s row naming `fake-small` and `build-1`'s
`fake-model`; the two dismissed rows titled by prompt and by first input (on the tip, the
worktree's path); and the side panel's `explore#1 (explore)` with `read_branch`'s `s-7,
with its diff` and `the branches` (on the tip `explore#1 (build)` and the JSON).
