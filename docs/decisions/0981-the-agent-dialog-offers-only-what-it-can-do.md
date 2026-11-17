---
number: 981
title: The desktop app's agent dialog offers only what it can do - the agent running now is marked as running, not offered as a switch; Edit is offered only for an agent whose file is this computer's to change, and otherwise the daemon's reason is said in its place; on the platform the dialog says in one line where the agents come from and offers no edit; a refusal is said on a line kept for it; and the platform's read-only sentence names no pod and sends nobody to the console
date: 2026-11-14
status: accepted
issue: 896
paths:
  - clients/gui/apps/desktop/src/views/AgentPicker.tsx
  - clients/gui/apps/desktop/src/views/AgentSwitch.tsx
  - clients/gui/apps/desktop/src/views/Agents.tsx
  - clients/gui/apps/desktop/src/styles.css
  - apps/troupe_core/lib/troupe/agent/local.ex
  - clients/tui/lib/troupe/client/remote.ex
symbols:
  - AgentPicker
  - AgentSwitch
  - Troupe.Agent.Local.on_a_pod/0
gist: "Agent dialog: current agent marked, not a Switch; Edit only for this computer's editable files, else the reason; platform says where agents come from; refusal line reserved; no pod, no console in the sentence"
---

Decision 920 put three actions on every row of the agent picker, and had Switch and Edit
refused with why where they could not be done: Switch for the agent running now, Edit for
a built-in, a bundle's agent and every agent on a pod. Walked against the fake plane
(troupe #896), that meant a platform session's dialog offered "Switch to build" for the
agent it ran, answering "This session runs build already.", and "Edit build's file",
answering "On a pod the agents come from the profile's bundle and are read-only here:
change them in the console": a word the reader does not use, no full stop, and a page a
member does not have, for a built-in no console changes. The dialog grew by a line when
either refusal appeared. DESIGN.md §8 says to remove what cannot be done rather than offer
it.

## Decision

This narrows Decision 920 for the desktop app's picker; its rows and its Start are as
they were.

- **The agent running now is marked, not offered.** Its row's actions read "<agent> runs
  now" where Switch would be.
- **Edit is offered only where it can open a file.** In a session on this computer, an
  agent the daemon says is not editable (`editable: false`) shows `editable_reason`, as a
  sentence, in place of the button. On the platform, and on somebody's laptop, no agent's
  file is this computer's, and there is no Edit at all; a platform session's dialog says
  once "The agents on <profile> come from its bundle." and nothing about the console,
  whoever reads it.
- **A refusal has a line kept for it**, one line high whether or not anything is said, so
  the dialog does not move when one is.
- **The platform's read-only sentence** (`Troupe.Agent.Local.on_a_pod/0`, the TUI's
  remote client, and the fakes) reads "On the platform the agents come from the profile's
  bundle and are read-only here." Other paths still reach it (a write refused on a pod,
  the TUI's manager), so it is kept, without "pod" and with its full stop. The agents
  manager adds a full stop to a reason only where it has none.

Not changed: the TUI's chooser, which already shows a read-only list for a pod session;
a built-in's reason on this computer, which still names `agents.put`.

## Proof

`agent-picker.test.tsx` (a bundle's agent shows its reason and no Edit; the running agent
is marked and has no Switch; the refusal line is there before anything is said and is a
line high), `agents-manager.test.tsx` (on the platform the dialog says where the agents
come from, offers no Edit and does not name the console), and the TUI's
`agents_manager_test.exs` on the new sentence. Each failed on the tip.
