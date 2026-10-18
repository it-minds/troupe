---
number: 164
title: Ctrl-N in command mode and Tab in a window open one agent picker over the session's own agents.list, whose rows say where each agent comes from in four words; from it b starts a branch (then w or c), s switches the window it was opened over (a pod's own), e opens the agent's file in /agents' editor, Enter does what it was opened for, and what the session cannot do is refused there with why
date: 2026-10-18
status: accepted
issue: 594
paths:
  - clients/tui/lib/troupe/ui/tui/agent_chooser.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/client/remote.ex
  - clients/tui/test/troupe/agent_picker_test.exs
  - clients/tui/test/troupe/command_mode_test.exs
  - clients/tui/test/troupe/agents_palette_test.exs
  - clients/tui/test/support/fake_remote.ex
symbols:
  - Troupe.UI.TUI.AgentChooser
  - Troupe.UI.TUI.AgentChooser.key/3
  - Troupe.UI.TUI.AgentChooser.origin/1
gist: "Ctrl-N and Tab open one picker (session's agents.list): b starts (w/c), s switches, e edits via /agents, Enter = what it opened for; refusals said in it"
---

Issue #594's terminal slice, on root Decision 920's list. Amends TUI Decision 155 (Ctrl-N's
chooser is no longer command mode's own page) and 156 (Tab's chooser is the same picker,
and does more than switch). On the chunk's tip Ctrl-N opened a page of names and
descriptions (`Client.profiles/2`) that could only start a branch, and refused outright on a
pod; Tab's popup (`AgentChooser`) could only switch; editing was `/agents` alone; and
neither said where an agent came from in a person's words.

- **One picker.** `Troupe.UI.TUI.AgentChooser` is the popup both keys open, over what they
  were opened from: command mode for Ctrl-N, the window for Tab. Its rows are the daemon's
  `agents.list` named by the session (root Decision 920), so on a pod they are the bundle's
  (the remote client sends `session_id`, which the pod's guard admits). Each row is the
  name, the agent in use marked `●`, its origin in the four words (`Shipped`, `Your
  organisation's`, `Yours`, `This repository's`; a daemon before them is read by `layer`)
  and the badges the palette shows; beside it the description, where it comes from with a
  bundle's profile, what it stands in for, what it may do, why it cannot run here when it
  cannot, and its instruction, read through `agents.get` as the cursor reaches it.
- **Three actions, the same keys wherever it was opened.** `b` starts a branch on the agent;
  where it works is the next step, `w` a worktree of its own, `c` the checkout, Enter the one
  marked, as Ctrl-N's second step was; what was typed before Ctrl-N is the task and starts
  at once, and without one the choice waits on the command line, as before. `s` switches the
  window it was opened over (`profile.switch`, the conversation kept); on a pod Ctrl-N's `s`
  switches the session's own agent, its one window. `e` opens `/agents` on the agent and its
  editor at once (TUI Decision 156's edit: the person's editor on a temporary copy, checked
  when it comes back, a built-in saved as a copy where the person says). **Enter does what
  it was opened for**: a start from Ctrl-N, a switch from Tab, so neither key's habit
  changed. Not chosen: Enter always starting, as the issue sketched, which would have
  turned every Tab-then-Enter switch into a new branch.
- **Refused there, with why**, before the daemon is asked, on the picker's own line: an
  agent the daemon says cannot run here, for a start and a switch; a start on a pod ("a
  remote session runs one profile; create another session from HQ"); `s` in command mode on
  this computer, which has no window to switch; and `e` on a bundle's agent
  (`editable_reason`) or on anything on a pod (the listing's `read_only`, the sentence the
  worker refuses a write with).
- **Not here**: `/agents` and `/new` opening the picker, the manager density, copy and new
  from a template in the picker, and save → start (the issue's other slices).

Proof: `test/troupe/agent_picker_test.exs` (Ctrl-N's rows with their origins, a
repository's agent standing in for a shipped one, `s` refused in command mode, an agent
that cannot run refused with why; Tab's `e` opening the agent's file in the editor through
`/agents`, `b` then `c` leaving the choice on the command line, and `s` switching the
window), failing on the tip where Ctrl-N's page had no rows of origins and Tab's popup had
no `e`, `b` or `s`. `command_mode_test.exs` keeps Ctrl-N's start with its instruction on
screen and its worktree step, and on a pod now opens the picker on the bundle's agent with
its profile, refuses a start and an edit with their sentences, and switches the session's
agent with `s`. `agents_palette_test.exs` keeps Tab's switch, its row in the four words.
