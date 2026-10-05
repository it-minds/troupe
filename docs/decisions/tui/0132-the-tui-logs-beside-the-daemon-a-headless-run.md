---
number: 132
title: The TUI logs beside the daemon, a headless run waits for a line queued mid-turn, and the session picker lists what the daemon has
date: 2026-09-29
status: accepted
paths:
  - apps/troupe_core/lib/troupe/paths.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/codec.ex
  - clients/tui/test/troupe/branch_client_test.exs
  - clients/tui/test/troupe/memory_client_test.exs
  - clients/tui/test/troupe/unit_test.exs
  - clients/tui/test/troupe/window_attention_test.exs
  - config/runtime.exs
gist: The TUI logs beside the daemon, a headless run waits for a line queued mid-turn, and the session picker lists what the daemon has
---

Amends 15, 65 and 129; defects
D26 and D36, and two the #246 hotfix found.
- **The log.** `config/runtime.exs` read `TROUPE_STATE_DIR` (Decision 15), which
  nothing has set since the daemon owns the state directory, and otherwise wrote to
  `~/.local/state/troupe` on every platform: `%USERPROFILE%\.local\state\troupe` on
  Windows, far from the daemon's `daemon.log` in `%LOCALAPPDATA%\troupe`. The
  binary's log is `troupe.log` in `Troupe.Paths.state_dir/0` now, resolved as the
  daemon resolves it (`TROUPE_STATE_HOME`, else `$XDG_STATE_HOME/troupe` or
  `%LOCALAPPDATA%\troupe`). The variables of Decision 15 are the daemon's
  `TROUPE_STATE_HOME` and `TROUPE_CONFIG_HOME`.
- **A branch's first lines on a rebuilt screen.** The client records a branch's
  `branch_spawned` once `session.create` has answered, and the daemon has stamped the
  branch's first events (`session created as librarian`, its prompt) by then.
  `Client.events/1` sorted the two journals by time alone, so those came ahead of
  their window, and a screen rebuilt from the journal dropped them. Nothing of a
  branch sorts ahead of its window's opening now, which also mends the journals
  already written, where stamping `branch_spawned` earlier would mend new ones only.
- **A line queued mid-turn, in a headless run (D26).** Another client's line sent
  while the target works is written as `input_queued` and taken as the next turn the
  moment this one ends. The run ended at that rest and never printed the reply; it
  ends at the first rest with nothing queued now. An agent that ended short drops
  what it is sent, so its rest still ends the run, and a queued line not taken
  within a minute (an agent that crashed takes its mailbox with it) ends it too.
- **The picker (D36).** Decision 65 hid a session without branches, as the scratch
  session `troupe` opens is; the daemon client gave every row none, so the picker
  listed the session on screen and nothing else, and its branches column was always
  empty. A row carries its branches from the daemon's listing now, over every
  session since a branch in a worktree is listed under the worktree, with what the
  daemon says of each (`waiting` as needing you, `done` or `interrupted` once it
  sleeps). The picker lists the sessions that spoke to a model or started a branch
  (since Decision 101 a plain line is work of the session's own), the session on
  screen, and no branch, which is a window of its parent's.
- **Dead readers (D36).** The printer's `branch_state`, `branch_failed` and
  `finished`, the model's `finished`, `delegation_started` and `delegation_completed`,
  and the view's own count of what is pending, which Decision 129 made the model's,
  are gone. A subagent's durable `agent_done` marks it ended, and a cancel ends the
  subagents under the cancelled agent and clears what they were doing. `Troupe.Codec`
  reads an event back as it was published: `to` and `dimension` as atoms, `reason`
  as the harness's string, where it gave `to` as a string and `reason` as an atom.
- **Proof:** `unit_test.exs` (the release's log), `branch_client_test.exs` ("a
  branch's first events are read back inside its window", "the session picker lists
  the sessions that did something"), `memory_client_test.exs` ("a screen opened after
  the librarian started"), `cli_test.exs` (a queued line: waited for, dropped by an
  agent that ended short, never taken) and `window_attention_test.exs` (the codec, a
  finished and a cancelled subagent), all but the dropped line failing on the chunk's
  tip, and the installed build, on the pull request.
