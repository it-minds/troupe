---
number: 852
title: agents.list lists the subagents when asked, a save names the hash of the file it replaces and is refused over one that changed, a file that does not parse is opened to mend through agents.get, and the desktop app's palette, watch box and transcript show what the daemon and the log say
date: 2026-10-11
status: accepted
issue: 565
supersedes: [841]
paths:
  - PROTOCOL.md
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_gateway/lib/troupe/gateway/agents.ex
  - apps/troupe_core/lib/troupe/agent/local.ex
  - apps/troupe_core/lib/troupe/agent/definitions.ex
  - apps/troupe_core/lib/troupe/onboard.ex
  - apps/troupe_gateway/test/troupe/gateway/agents_mend_test.exs
  - clients/tui/lib/troupe/ui/tui/agents.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/headless/printer.ex
  - clients/tui/test/troupe/agents_mend_test.exs
  - clients/gui/packages/client/src/agents.ts
  - clients/gui/packages/client/src/daemon.ts
  - clients/gui/packages/client/src/transcript.ts
  - clients/gui/apps/desktop/src/views/Agents.tsx
  - clients/gui/apps/desktop/src/views/AgentEditor.tsx
  - clients/gui/apps/desktop/src/views/CommandPalette.tsx
  - clients/gui/apps/desktop/src/views/LocalControls.tsx
  - clients/gui/apps/desktop/src/views/Session.tsx
  - clients/gui/apps/desktop/test/palette-agents-watch.test.tsx
symbols:
  - Troupe.Agent.Local.broken/3
  - Troupe.Agent.Local.hash/1
  - Troupe.Onboard.put_file/5
  - Troupe.UI.TUI.Agents.heard/2
  - agentConflict
  - ifHashOf
gist: "agents.list subagents:true (rows say mode); agents.get hash + broken; agents.put if_hash, conflict when changed; palette kinds; watch box is watch.get + watch_changed"
---

Issue #565 and the agents and watch items D107, D112 and D114 left after #503 and #502.
On the chunk's tip: `explore`, `general`, `implementer` and `reviewer` were in no listing,
so neither agents manager could show or edit them, though `agents.get` answered them by
name; two clients editing one agent saved over each other with nothing said; a file that
did not parse was listed with why and could not be opened anywhere; the desktop app's watch
box showed its own record of what it last set; a headless run printed nothing for a watch
trigger; the desktop palette drew `/goal`, `/build` and a repository's `/review` alike; and
a subagent's brief was a turn by "You" in one paragraph.

## Subagents: a parameter, not every row

`agents.list` takes `subagents: true` and then lists the subagents after the primaries;
every row now says its `mode`. Not chosen: listing every agent with its `mode` to everyone.
Every picker of what a session runs reads `agents.list` (the desktop app's agent switch and
start screen, the terminal's Tab chooser and palette rows, a remote client's), and
`session.create` and `profile.switch` refuse a subagent (Decision 841), so a client older
than the change would offer agents the daemon then refuses. The parameter leaves every
existing caller's answer as it was; the two managers ask for it and group by `mode`. Both
managers read, copy, edit and delete a subagent as any other agent: `agents.get` already
answered one by name, which is what the delegation gate (#554) links to.

## Two clients editing one agent

`agents.get` gives `hash`, `"sha256:<hex>"` of `text` (the form `fs.read` and `fs_changed`
use), and `agents.put` takes it back as `if_hash`. The writer compares it with the file at
the target in the same VM-wide transaction it writes in (`Troupe.Onboard.put_file/5`), so
nothing can land between the check and the rename. A file that holds anything else, or is
gone, is not written: the answer is `conflict` with a sentence and the hash of what is
there now.

- **When a client sends it.** Only when it saves an edit back into the file it was opened
  from: the same name and layer, the rule Decision 842 uses for "the file being replaced".
  A copy into the other layer or a new agent sends none, since what it would replace there
  is not a file it read; there the last write still wins, as Decision 841 left it.
- **What a client does with the refusal.** Both keep the edit and say the daemon's
  sentence, and take the hash it carries as the edit's new base, so the next save, made
  knowingly, replaces the other change. Not chosen: merging (a definition is short, and
  both texts are in front of the person), or refusing until the edit is reopened from the
  file (which throws the person's text away or leaves them to copy it out).
- **Said as it happens.** Both editors watch `agents.changed` for the agent they have open:
  the terminal's kept edit or open save question (`Troupe.UI.TUI.Agents.heard/2`), the
  desktop app's editor. Their own save is not news: the terminal's has returned before the
  notification is read, and the desktop app ignores one while its own save is in flight.

This replaces the one line of Decision 841 that said a conflict between two clients is the
last write's; the rest of 841 stands.

## A file that does not parse, opened to mend

`agents.get` answers `broken`, `{scope, layer, path, text, hash, reason}`, for the person's
or the workspace's file of that name that was found and does not parse, the one that would
answer once mended (`Troupe.Agent.Local.broken/3`). It is beside what answers to the name
(a broken `.troupe/agents/plan.md` leaves the built-in `plan` answering), and when nothing
answers the answer is `{name, broken}` alone rather than `not_found`. Not chosen: a method
of its own (a fourth read, a permission row and a remote path for one field), or the text
in every `agents.list` row of `skipped` (the list is read on every change, and almost every
skipped file is one no client may open). Only a file at the place `agents.put` writes
counts: one linked out of the workspace is never read (Decision 829), and a main
checkout's draft in a worktree is not offered as if saving here would mend it. The loader
keeps the layer a parse failure was read from (`source` on its `skipped` entry) for this.
The terminal's `e` on a file not read opens it, the save question's Enter puts it back
where it is with its hash; the desktop app's "Mend" opens it in the editor the same way.
Every `auto` in the mended text is asked about, since nothing of the broken file was read.

## The desktop app shows what the daemon and the log say

- **The palette's three kinds** (#565), as TUI Decision 156 draws them: a kind column,
  `command`, `agent`, `repository` or `yours`; an agent's row carries its layer, its model
  (`default` for the session's), `read-only`, and `worktree` or `checkout`, from
  `agents.list` for a session on this computer, asked for when the palette opens without
  holding it back. A session on the platform has its `commands.list` alone, as the agent
  switch does (Decision 842). The desktop app starts no branch, so every agent row says
  why it cannot run here, and the daemon's own reason (a model the provider does not
  serve) comes first; its detail says it is an agent, not a command, and where it is
  changed.
- **The watch box** reads `watch.get` when the controls open and follows the session's
  `watch_changed`, so the terminal's `/watch` is the box's state at once; a watch another
  session of the workspace holds says which (Decision 844).
- **A subagent's brief** is the child's first message, from the agent that delegated it:
  a `brief` entry laid out as its parts under their names (Decision 847's `partsOf`), never
  a turn of the person's. The child logs that message from its own process while the parent
  logs `delegation_started` after starting it, so the two arrive in either order and the
  fold matches them by the child's path and the brief's text whichever comes first.

A headless run prints `watch_triggered` as the screen's line under it
(`Model.watch_line/1`): the branch is a session of its own that the run does not follow.

## Proof

Each failed on the chunk's tip.

- `Troupe.Gateway.AgentsMendTest` (three tests over the daemon's socket): the subagents
  listed only when asked, every row's `mode`, primaries first, a subagent copied into the
  repository; a save over a file another save changed refused with the sentence and the
  file as the other left it, then replaced with the hash the refusal gave, and one taken
  away refused; a broken project file opened through `agents.get`, mended and listed, a
  broken copy beside the built-in that answers, and a person's own broken file.
- `Troupe.AgentsMendTest` in the terminal UI: the subagents on `/agents` with their mode and
  `explore` copied; another client's save while the editor is open said, the save refused
  with the daemon's sentence and the edit kept, the next save replacing it; a broken file
  opened by `e` and saved back where it is; and a headless run's watch line.
- `clients/gui/apps/desktop/test/palette-agents-watch.test.tsx`: the four kinds with an
  agent's badges and an agent that cannot run saying the daemon's reason; the subagents
  listed and one copied and edited, its save naming the hash; another client's save said
  in the open editor, the save refused and the next replacing it; a broken file mended; the
  watch box following another client's `watch.set`; a brief written before its delegation
  shown as a brief. `clients/gui/packages/client/test/transcript.test.ts` folds the brief in
  both orders, and `agents.test.ts` the methods over the fake daemon.
