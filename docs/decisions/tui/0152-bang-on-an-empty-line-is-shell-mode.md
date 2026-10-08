---
number: 152
title: "`!` on an empty command line is shell mode: Enter runs the line through `shell.run` where the session runs, `!!` keeps it from the agent, Esc or Ctrl-C kills it while it runs, and it is drawn as the person's command, never sent to the agent as text"
date: 2026-10-08
status: accepted
issue: 486
paths:
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/test/troupe/shell_mode_test.exs
  - clients/tui/test/troupe/remote_shell_test.exs
gist: "A line starting with ! runs via shell.run (!! = kept from agent), never input.send; Esc/Ctrl-C kill this screen's run; drawn as a ! block from user_shell"
---

Issue #486, root Decision 813. The command box sent every line that did not start with
`/` to `input.send`, so `!git status` reached the agent as words.

- **The `!` stays in the line.** Shell mode is a line that starts with `!`, not a mode of
  its own: typed on an empty line or pasted, it is shell mode, and backspace over it on
  an otherwise empty line leaves, as `/` and the palette do. The box drops its `/`
  prompt for the `!` and its title says, in one line, what such a command does not have:
  no stdin and no `cd` carried over, and that `!!` keeps it from the agent. Not chosen: a
  separate mode flag, which a paste would have to set and a backspace clear.
- **`run_command/2`'s first clause.** `!cmd` goes to `Client.shell_run/3` and `!!cmd`
  with `agent?` false, through the session's own connection, so a daemon session runs it
  in the daemon and a plane's on its pod; nothing typed on the command line after a `!`
  is ever input. A bare `!` or `!!` says what to type; a second command while one runs
  says that one is still running. The harness's refusal is the notice: its sentence, as
  it is. A window's own input box is left as it was: its line goes to that window's
  agent, or answers its question, which may start with anything.
- **Esc and Ctrl-C kill this screen's run** (`shell.cancel`) while it runs, and Ctrl-C then
  arms nothing; Esc leaves what is typed. Only the run this screen started is killed: its
  id is the `shell.run` answer, kept until its `user_shell` arrives, so a command another
  client runs is left alone.
- **A block of its own.** `shell_started`, `shell_output` and `user_shell` become one
  `{:shell, …}` transcript entry by run id: `! <command>`, then the output, the last 20
  rows of it unless output is expanded, and how it ended (`exit 1`, `killed`, `timed out
  after 120.0 s and was killed`), with `on <profile>` for a session on a plane and `kept
  from the agent` for `!!`. A replay has only the `user_shell` and draws the same block.
  The `user_input` from `shell`, what the agent was given, is not drawn.
- **Not done:** up-arrow history (the TUI has no prompt history to keep shell lines apart
  in), and telling `vim` or `ssh` apart from other commands before they run.
- **Proof:** `test/troupe/shell_mode_test.exs` (`!cmd` runs in the workspace and is drawn
  with its exit and output, with no input in the window or the journal; `!` and backspace;
  a pasted line; Esc kills a running one; `!!`; a forbidding policy's sentence; a bare
  `!!`), failing on the chunk's tip where the line went to the agent;
  `test/troupe/remote_shell_test.exs` (on a plane's session the command goes to the pod as
  `shell.run` and its block says `on code`); `remote_translate_test.exs` (the three events
  fold into one block, a replay draws the same, the note is not drawn).
