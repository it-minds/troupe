---
number: 166
title: /agents opens the one agent picker at the manager's density (subagents and files not read too, each row its mode, facts and what it stands in for) and /new opens it to start a session on the agent chosen; from any of them n makes a new agent from the one selected, and what the manager's page does to an agent comes back to the picker on what was saved, so Enter starts on it
date: 2026-10-23
status: accepted
issue: 594
paths:
  - clients/tui/lib/troupe/ui/tui/agent_chooser.ex
  - clients/tui/lib/troupe/ui/tui/agents.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - apps/troupe_core/lib/troupe/commands.ex
  - clients/tui/test/troupe/agent_picker_test.exs
  - clients/tui/test/troupe/agents_manager_test.exs
  - clients/tui/test/troupe/agents_mend_test.exs
  - clients/tui/test/troupe/new_session_test.exs
  - clients/tui/README.md
symbols:
  - Troupe.UI.TUI.AgentChooser.key/3
  - Troupe.UI.TUI.AgentChooser.reload/4
  - Troupe.UI.TUI.Agents.new_from/3
gist: "/agents = picker at manager density; /new = picker then a session on it; n copies the selected agent; a save returns to the picker on it; subagents never start"
---

Issue #594's terminal rest, on TUI Decision 164's picker and root Decision 920's list.
Amends TUI Decision 156 (`/agents` is no longer a page of its own) and 151 (`/new` asks for
its agent first). On the chunk's tip `/agents` opened the manager's page, a list beside
the picker with its own rows and words, and `/new` made a session on the default agent
with no choice; a new agent started from a blank template, and a save left the person on
the page with nothing to start.

- **`/agents` is the picker at the manager's density.** The same popup Ctrl-N and Tab open
  (`AgentChooser`), listing the subagents too (`agents.list` with `subagents: true`) and,
  after the agents, the files found and not read, each with why. Each row is the name, the
  agent in use marked, the four origin words, its mode, the facts the manager's list had
  (model, tool count, read-only, cap on turns), what it stands in for and the windows that
  run it; beside it the fields the manager's page showed (`Agents.fields/2`), why it cannot
  be changed here, and its instruction. It takes the room the page had, not the picker's.
  Enter reads the agent whole, as `/agents`' Enter did; `b`, `s` and `e` are the picker's,
  and `c`, `x`, `v` and `r` the manager's own.
- **The manager's page is the step an action needs, then the picker again.** `e`, `c`,
  `x`, `v` and `n` open `/agents`' page on the agent for that one thing (the editor, the
  save question, the delete question, the whole instruction), and its end comes back: Esc
  with the selection kept, and a save or a delete with the listing read again, the cursor
  on what was saved and the picker's line saying what Enter (or `b`) now does to it. A save
  refused (the daemon's check, a file another client saved) stays on the page with the
  edit kept, as before; only a save that wrote leaves it. So making an agent and using it
  are one flow, the issue's save → start.
- **`n` makes a new agent from the one selected**, in every picker: its file, whichever
  layer it is in (Troupe's own, the organisation's, a person's or the repository's), opened
  in the editor under the name typed, and saved like any new agent into the layer the
  person picks; unchanged, it is still saved, since a copy of an agent that works is what
  was asked for. The answer to the issue's question on templates: the shipped agents are
  the templates, copy-only, and no separate set is kept. Refused on a pod, where nothing is
  written, with the listing's sentence. `/agents`' page's own blank template stays where
  the page is.
- **`/new` takes its agent from the picker.** `/new` and `/new --private` open it (title
  "a new session on"), and Enter, or `b`, makes the session with that agent as its profile;
  the new screen's first line starts that agent in the checkout, as a Ctrl-N choice does.
  Not for `--branch`, which keeps the agent of what it forks, `--remote PROFILE`, which names
  the plane's, or a pod's session on screen, whose listing is the pod's and not what a
  session here could run.
- **A subagent is never started or switched to** from a picker: an agent hands work to
  one. The refusal says so, and that `n` makes a primary from it.

Proof: `agent_picker_test.exs` ("/new opens the picker, and Enter starts a session on the
agent chosen"; "/new's n makes an agent from a built-in, and Enter starts a session on it
once saved"; Tab's `e` coming back to the picker with the selection kept), failing on the
tip where `/new` made the session at once and the picker had no `n`;
`agents_manager_test.exs` and `agents_mend_test.exs` drive `/agents` through the picker: its
rows in the four words with each fact, the whole instruction, copy and delete coming back,
`n` from a built-in saved and then started with `b`, an unchanged copy saved, a subagent
refused a start, a file not read mended through it, a conflict that keeps the edit on the
page, and a pod's picker read-only with its sentence for `e`, `c`, `x` and `n`.
`new_session_test.exs` passes through the picker for `/new` and `/new --private`.
