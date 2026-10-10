---
number: 156
title: "`/agents` is a manager over the daemon's agents.* methods: the list says each agent's layer, model, tools, read-only badge, turns and windows; an edit is the person's own editor on a temporary copy, checked at once and kept when refused; every save names what runs without asking and asks again when it adds an auto; Tab in a window chooses its agent; the palette tells a command, an agent and a file's command apart"
date: 2026-10-10
status: accepted
issue: 503
paths:
  - clients/tui/lib/troupe/ui/tui/agents.ex
  - clients/tui/lib/troupe/ui/tui/agent_chooser.ex
  - clients/tui/lib/troupe/editor.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/client/remote.ex
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/test/troupe/agents_manager_test.exs
  - clients/tui/test/troupe/agents_palette_test.exs
  - clients/tui/test/troupe/editor_test.exs
symbols:
  - Troupe.UI.TUI.Agents
  - Troupe.UI.TUI.Agents.widened/2
  - Troupe.UI.TUI.AgentChooser
  - Troupe.Editor.edit/2
  - Troupe.Client.agents/3
  - Troupe.Client.edit_file/2
gist: "/agents writes only via agents.*; edits kept when refused; a save names its autos and re-asks when one is added or leaves trust; Tab picks a window's agent"
---

Issue #503, the terminal's half (section 1's manager, section 2's switch, section 3's
palette), on root Decision 841's methods. On the chunk's tip `/agents` was a notice line,
`agents: build, plan, …, worktree` (`worktree` is a command, D107); nothing in the TUI could
read an agent's instruction, change one, or say which agent a window ran after a switch;
Tab in a window stepped blind to the next name in that same list, `worktree` included,
which the daemon now refuses; and the palette drew `/plan`, `/merge` and a repository's
`/review` as the same kind of row.

- **The manager.** `/agents` opens a page (`Troupe.UI.TUI.Agents`), a list beside the
  selected agent: from `agents.list`, each row's name, its layer (built-in, bundle, mine,
  repository), its model, how many tools it holds, `read-only`, `max N turns` and the
  windows on this screen that run it (from the model, so a switch shows at once); the
  files that did not parse are listed after, with why. The detail is `agents.get` with the
  session (permissions, tools, the file, what it hides, why it is not editable) and the
  first lines of its instruction; Enter reads the instruction whole, scrolled.
- **Editing is the person's editor, the writing is the daemon's.** `e` writes the file's
  text (`agents.get`'s `text`) to a temporary file and opens `VISUAL`, then `EDITOR`
  (Notepad on Windows, `vi` elsewhere without either) on it (`Troupe.Editor`, through
  `Troupe.Client.edit_file/2`, as the clipboard goes through the client). What comes back
  is checked with `agents.validate` at once. Refused, the errors are on the page, each with
  its field, and the text is kept: the next `e` opens the kept text, not the file, and `z`
  lets it go. Unchanged, nothing is saved. Accepted, the save asks where: `r` the
  repository's `.troupe/agents/`, `m` mine (`<config>/agents/`), Enter where it already is;
  Esc keeps the edit. A built-in is edited the same way, since what is saved is a copy that
  then answers to its name. The TUI never writes an agent file itself.
  Not chosen: a form for the frontmatter in the terminal (the desktop app's way; a
  terminal person has an editor), and opening the real file (a half-written file would be
  read by every session meanwhile, and the daemon's check would come after the damage).
- **What the agent may do, before it is saved.** The save shows the permissions the text
  sets, every `auto` first and by name. A save that adds an `auto` the name did not have
  (compared with what answers to the name now, any layer), or that moves one from the
  repository's layer, where an `auto` waits for the workspace to be trusted (root Decision
  825), into the person's, where nothing holds it back (X26's note), asks once more, `y` or
  back, and says which of the two it is. A save that adds none goes at once.
- **Copy, new, delete.** `c` copies the selected agent into the repository under its own
  name in one key (the common case: a built-in made the repository's), and the
  repository's own into mine; it is a save like any other, so the same question guards an
  `auto`. `n` asks for a name and opens the editor on a template (a read-only primary
  agent, which passes the check as it is). `x` deletes the copy in the layer it is in,
  naming that layer first, and says what answers to the name after (`agents.delete`'s
  `layer`); a built-in is not deleted, and says how it is changed instead.
- **Read-only, and why.** A bundle's agent says the console changes it
  (`editable_reason`), for `e`, `c` and `x` alike. On a pod the remote client adds
  `read_only` to `agents.list`, the sentence the worker refuses a write with, and never
  sends `agents.put` or `agents.delete`: the list says "read-only here", and every key that
  would write says the sentence.
- **The terminal goes to the editor.** On Linux and macOS the editor is started by
  `/bin/sh` with `:nouse_stdio`, so it has the TUI's terminal as its standard input and
  output; the shell first turns off mouse reporting and bracketed paste and leaves the
  alternate screen, and after it returns to it and turns them on again (mouse only when
  the screen had it). The TUI is waiting meanwhile, so nothing else reads the terminal.
  The renderer remembers the last frame and draws only what differs, while the screen it
  gets back is blank, so one blank frame is drawn first and the next is drawn whole. On
  Windows the editor is a program with a window of its own (Notepad, `code --wait`); one
  that wants the console is not supported there. A frame saying "editing … close the
  editor to come back" is drawn before the editor opens. This is the one process the TUI
  starts outside `Troupe.OS.Process` beside the file watcher (Decision 19): the reaper
  takes the child's standard input and output for its own pipe, and an editor needs the
  terminal; the person's editor on the person's file is left open if the TUI goes.
- **Each window says its agent, and Tab chooses it.** The tile title is `1 build-1 (plan)`
  and the pane's `build-1 (plan)`: the window keeps the name it started with, and the
  agent in brackets follows `session_created`, `agent_started` and `profile_switched`
  (translated to `:agent_named`), so a session started without naming one says `build`,
  not `root`. Tab in a window with nothing typed (Decision 22's Tab, no longer a blind
  cycle) opens a chooser over it (`Troupe.UI.TUI.AgentChooser`): the primary agents from
  `agents.list`, the one in use marked, each with its layer and badges, and the highlighted
  one's description, permissions and instruction beside them. Enter sends `profile.switch`
  for that window's session; the window keeps its conversation and the daemon's
  `profile_switched` is a line in its transcript with the layer and the tools it gained and
  lost. The chooser takes `agents.list` rows and hands back a name, so command mode's
  agent choice (#502, TUI Decision 155) can open the same popup.
- **The palette's three kinds.** Each row has a kind column: `command` (Troupe's own,
  muted), `agent` (accent), `repository` or `yours` (a file's command). An agent's row
  carries its layer, its model (`default` for the session's), `read-only`, and `worktree`
  or `checkout` (what `agents.list` says a session on it would get), ahead of its
  description; its detail says it is an agent, not a command, and where it is managed. An
  agent the daemon says cannot run here (a model the provider does not serve) is greyed
  with the reason, as any row that cannot run now. The rows are `agents.list`'s, read with
  the command table and again whenever `agents.changed` arrives, so a save in the desktop
  app is a row here at once.
- **The palette's rows the audit found wrong (D107).** Opened over a window, a command the
  palette takes to finish typing (one that wants an argument, or taken with Tab or Space)
  goes into that window's box, marked as a command for it, and Enter runs it against the
  window: `/upload <path>` from a window, `/copy` taken with Tab. A new query's cursor lands
  on the exact name, else the first name or alias it begins, so `wor` and Tab give
  `/worktree`. A command a file defines that takes arguments (its `argument-hint`) is put
  on the line by Enter rather than run with `$ARGUMENTS` empty.
- **Proof.** `agents_manager_test.exs`: the list with its badges and windows, and no
  `worktree` (failing on the tip, where `/agents` was a notice); the whole instruction;
  `c` copying `plan` into the repository and `x` taking it away with the built-in named
  after, a built-in refused; an edit with an unknown tool refused at once and kept, the next
  `e` opening the kept text, the fix saved; an added `auto` asked once in the repository,
  a no writing nothing, and a copy into mine asked again for the same `auto`; `n` from the
  template into mine and its palette row; an unchanged edit saving nothing; a bundle's
  agent refused with its reason; on a pod (the suite's `FakeRemote`) read-only, saying
  why, nothing sent. `agents_palette_test.exs`: the three kinds and an agent's badges; an
  agent that cannot run greyed with why; `root (build)` and `build-1 (build)`, Tab's
  chooser with the instruction beside it, the switch to `plan` in the header and the
  transcript; and the three D107 rows. `editor_test.exs`: `VISUAL` over `EDITOR`, split as a
  shell splits it, a missing editor said, and a scripted editor run, waited for and its
  exit status read.
