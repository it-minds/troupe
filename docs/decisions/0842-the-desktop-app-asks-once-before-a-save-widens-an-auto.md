---
number: 842
title: The desktop app edits an agent's file as text, leaving every line its form did not change, asks once before a save that lets a tool run without asking that the replaced file did not, and switches a window among the agents its session could run
date: 2026-10-10
status: accepted
issue: 503
paths:
  - clients/gui/packages/client/src/agents.ts
  - clients/gui/apps/desktop/src/views/Agents.tsx
  - clients/gui/apps/desktop/src/views/AgentEditor.tsx
  - clients/gui/apps/desktop/src/views/AgentSwitch.tsx
symbols:
  - widenedAutos
  - withFields
gist: "Form keeps untouched lines; ask once when a save adds/widens an auto vs the replaced file (a copy counts all); switch offers agents, never plane profiles"
---

Issue #503 in the desktop app (the daemon's side is Decision 841). Three choices the
issue and 841 leave to the client.

- **The file's text is what is edited, and the daemon is its only judge.** The form reads
  the frontmatter keys it knows (`description`, `mode`, `model`, `tools`, `permissions`,
  `max_turns`, `budget_share`, `skills`) out of the text and writes a change back where
  the key was (`withFields`), every other line as the file had it: a key it does not know
  (onboarding's `imported_from`, `override`), a comment, the order. A key written in a way
  the form does not read (a folded scalar) turns the form off and leaves the text to the
  file tab, rather than rewrite what it could not read. Not chosen: building the text from
  `agents.get`'s parsed fields, which drops what the form does not know at the first save.
  Nothing is checked in the client: Check and Save ask the daemon (`agents.validate`,
  `agents.put`), and each finding is shown at the field it names, on the tab that has it.
- **Asked once, against the file being replaced.** Before a save the editor shows what the
  agent may do, every `auto` named, and the save is asked about once when it lets a tool
  run without asking that did not before: an `auto` added, or an `ask` or `deny` made
  `auto` (`widenedAutos`). The comparison is with the file the save replaces, the
  definition the editor was opened from when it has the same name and layer; anything
  else is a new file and every `auto` in it counts, so copying an agent with an `auto` into
  your own layer is asked about, since there it applies in every workspace and no trust is
  asked (Decision 825 gates only a repository's). A save that keeps the autos it had is
  not asked about again. A repository's save is asked about too, worded for the trust it
  waits on. Not chosen: asking on every save (a question that is always there is not
  read), or only for the user layer (a repository's `auto` applies to everyone once
  trusted).
- **The switch offers agents.** A window's head shows its agent and a switch among the
  primary agents its session could run: `agents.list` for a session on this computer, with
  each one's layer, and the agents section of the session's own `commands.list` for a
  session on the platform, its bundle's. The plane's profiles were offered there before,
  and a plane profile is not an agent: `profile.switch` names the agent, and since 841 an
  unknown name is refused. A refusal is said beside the switch; a switch that took is the
  transcript's to say, from `profile_switched` with its layer and the tools gained and
  lost. The agent shown is the transcript's (`session_created`, whose `profile` a pod
  writes as the agent it runs, `Troupe.Session` taking the plane's `agent` or the default,
  then each `profile_switched`), and until that arrives a daemon row's `profile`, never a
  plane row's, which names the plane's profile.
- **Proof:** `clients/gui/apps/desktop/test/agents-manager.test.tsx` against the fake
  daemon (the list's facts and running windows, a built-in copied in one press, an unknown
  tool refused at its field with nothing written, a mended edit that leaves the other lines
  as they were, the question asked once and not again, a copy deleted with its layer named,
  a bundle's agent not editable, another client's save followed, an older daemon said, the
  switch and its transcript line, `/agents` from the palette, a session on the platform
  offered its own agents and switched on its pod, a refused switch);
  `clients/gui/packages/client/test/agents.test.ts` (the form's round trip, `widenedAutos`,
  the methods over the socket). On the chunk's tip the first failed: there was no Agents
  screen and nothing to edit.
