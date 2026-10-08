---
number: 816
title: "`troupe.openOnFolderOpen`, off by default and a user or remote setting, opens Troupe as Troupe: Open does when a trusted window opens a folder, and not again after a reload, whose terminal is known by the process id the extension keeps for it; and \"Troupe\" is a terminal profile whose program is the TUI, a new terminal at Open's folder each time it is picked"
date: 2026-10-08
status: accepted
issue: 378
supersedes:
  - 765
paths:
  - clients/vscode/src/startup.ts
  - clients/vscode/src/extension.ts
  - clients/vscode/src/folder.ts
  - clients/vscode/package.json
  - clients/vscode/test/vscode/startup.ts
symbols:
  - whenFolderOpens
  - restore
  - remember
  - profile
  - atStart
  - fromBefore
  - terminalName
gist: "openOnFolderOpen: off, machine, trusted only, not after a reload (terminal known by kept pid, not name); Troupe profile: the TUI as process, new each pick"
---

Issue #378's v1, the two items Decisions 765 and 808 left: opening Troupe when a folder
opens, and the terminal profile. With them v1 is done; v2, the panel over the daemon's ACP,
is an issue of its own.

- **The setting.** `troupe.openOnFolderOpen`, a boolean, false by default. `machine`
  scoped like the other three (765), so a repository's `.vscode/settings.json` cannot start
  Troupe for whoever opens it; VS Code keeps its own `task.allowAutomaticTasks` out of a
  workspace's settings for the same reason. No "ask" value: an answer per folder would be a
  second setting kept where the person cannot see or edit it, and a question each time a new
  folder opens is what off by default spares everyone. It is one switch, beside the others.
- **When.** The extension activates on `onStartupFinished`, as it did for its status bar:
  after the window has opened its folder and restored its editors and terminals, so the
  folder is the editor's and a terminal kept across a reload is there to be found, and the
  window's start waits for nothing of ours. Not `workspaceContains:` (a search of the folder
  for a pattern, for a setting that is about any folder), nor `*` (activation during the
  start, which VS Code discourages). Opening a folder starts a new extension host, so every
  folder opened gets its turn; a folder added to an open workspace does not open Troupe.
- **Which folder, and where.** As Troupe: Open (765): the active editor's, else the only
  folder, and with several and nothing to go by, the question, once. Where `troupe.openIn`
  says. With no `troupe`, the sentence, at every start: what turning it on with nothing
  installed earns.
- **Trust.** Nothing in a workspace that is not trusted. Restricted Mode is the person
  saying they have not decided about this folder, and a program started because it was
  opened is what it holds back. 765 runs the extension in untrusted workspaces because it
  reads nothing from them; that holds for what a person presses, not for a start nobody
  pressed. Trusting the workspace, at VS Code's question as it opens (which can come after
  the extension has started) or later from the banner, opens Troupe then
  (`onDidGrantWorkspaceTrust`), as if the folder had just opened.
- **Not again after a reload, and the terminal known by its process.** 765 has a terminal
  from before a window reload found by its name. In VS Code 1.140 on Windows it is not: a
  reload gives the terminal back with its process and the TUI in it, but under its shell's
  name (`pwsh`), with none of Troupe's options, name or icon; only `processId` is the same.
  So the extension keeps each folder's terminal's process id in the workspace's storage
  (`workspaceState`, `troupe.terminals`), written when it makes or adopts the terminal and
  dropped when the terminal closes. As it starts, a terminal whose process is the one kept
  for a folder is that folder's, taken as busy and only shown (765), and one still named
  `Troupe: <folder>` is too (`fromBefore`). That replaces 765's "found by its name" in part,
  the name staying as the second way. Troupe: Open uses the same, so after a reload it shows
  the folder's terminal rather than opening a second, which it did before this. What is
  kept is process ids, on the machine, in VS Code's storage for the workspace: the README's
  "collects nothing and sends nothing" holds, and it and the user guide say what is kept.
  After VS Code is closed and opened again, it revives the terminal as a new shell with a
  new process, which is no folder's: the TUI ended with the window, and Troupe opens afresh.
  Not chosen: `isTransient` terminals (none kept across a reload, so a reload would end the
  TUI), and looking for a `troupe` process under each terminal (per platform, and a
  person's own `troupe` in a terminal of theirs would count).
- **"Troupe" as a terminal profile.** `contributes.terminal.profiles`, `troupe.tui`, titled
  Troupe, with the mask; VS Code derives its `onTerminalProfile:troupe.tui` activation from
  the contribution. The provider returns a `TerminalProfile`:
  - **The TUI as the terminal's program**, not a shell with a line typed into it: a profile
    is what VS Code starts in a new terminal, and its provider returns options, with no
    terminal to type into. The cost is 765's reason for Open's line: a TUI that fails to
    start takes its terminal, and its reason, with it, and VS Code says only the exit code.
    Open keeps the shell for that, and the user guide says to use it.
  - **`troupe` as Open finds it** (765: never a file without an extension on Windows) and
    started as the Settings view starts it (`invocation` in run.ts): a `.exe`, or a program
    on POSIX, with its arguments as a list; a `.cmd` or `.bat` through
    `cmd.exe /d /s /c` with the line quoted by `cmdWord` (808), given as `shellArgs` in one
    string, which VS Code hands Windows as the command line. Its arguments are Open's:
    `--workspace <folder>` and `troupe.args`.
  - **At Open's folder** (`chooseFolder`). The provider is not told which folder VS Code
    asked for itself: **Create New Terminal (With Profile)** asks one first in a window of
    several folders and hands an extension's profile nothing, so there, with no editor, the
    question comes twice. The **+** menu, the one people use, asks nothing first.
  - **A new terminal each time.** Not the folder's one terminal of 765 and 808: the menu
    asks for a new terminal, as it does for a shell; a provider can only make one or fail;
    and VS Code, once the provider returns, makes the last terminal of the panel the active
    one, so showing another from inside it would hand the focus elsewhere. It is named
    `Troupe: <folder>`, and it is the folder's when the folder has no terminal of Troupe's
    (Open and the other commands then use it, as busy); otherwise it is a second Troupe that
    they leave alone.
  - **Where the menu was**: VS Code's choice. `troupe.openIn` is Open's.
  - **Nothing to make** (no folder, the question dismissed, no `troupe`): Open's sentence
    with its buttons, and VS Code is handed an error with an empty message. It shows a
    profile's error as a notification, and none for an empty one, so the sentence is said
    once.
- **"Which terminal profile to use"**, among the issue's settings. The shell Troupe: Open
  types into is VS Code's default profile, chosen with **Terminal: Select Default Profile**;
  an extension setting naming another would have to resolve VS Code's detected profiles
  (`"source": "Git Bash"`), which the API does not expose. Troupe being a profile itself is
  the other reading, and this is it.
- **Remote windows**, as 765: the extension runs where the terminal does, so the profile's
  program is that host's `troupe`, found there, and the setting is a remote setting too.
- **Not in this**: v2. The shell VS Code revives in place of Troupe's terminal after a
  restart, which it did before this, stays a plain shell. A failed start from the profile
  keeping its reason would need a shell under the TUI again.
- **Proof:** the extension's unit tests, failing on the chunk's tip: the manifest has the
  setting (boolean, false, `machine`) and the profile (`troupe.tui`, Troupe, its provider
  registered under that id, its icons in the package); and `startup.test.ts`: off, no
  folder, not trusted, open already; a folder's terminal the one whose process was kept,
  whatever its name, none for a process gone, and a name only when it is the folder's. The
  suite inside VS Code 1.140 on Windows, 34 of 34: the profile as the **+** menu calls it
  (a terminal made from the contributed profile, no folder of VS Code's), with `troupe`
  (the fake's `.cmd`, through `cmd.exe`) as the terminal's program at the editor's folder
  of four; a second pick a second terminal, Open then showing the first; its terminal gone
  when `troupe` exits; none without `troupe`. Then two windows on one folder with the
  setting on: Troupe opens once, at the folder; and with a terminal named for the folder
  there before the extension starts, nothing more. A test run ends when its window reloads,
  and `runTests` starts VS Code with workspace trust off, so the rest was checked by hand,
  against the
  installed `troupe` 0.9.0-beta with the `.vsix` in a scratch VS Code profile whose
  terminals had scratch homes: the window on a folder, setting on, started
  `troupe.exe --workspace <folder>` once, and its session was recorded with that folder;
  the profile, as the menu makes it, gave a terminal whose own process was
  `troupe.exe --workspace <folder>`; a real window reload (from a scratch copy of the
  extension) kept the TUI and gave the terminal back as `pwsh`, known by its process: one
  `troupe`, and Troupe: Open after it reused that terminal, where the build before this
  started a second `troupe`; closed and opened again, one new `troupe`; and in a folder VS
  Code did not trust, nothing. Folders inside this repository's checkout came up trusted in
  a fresh profile; one outside it did not. Not run: a remote window, trusting a workspace
  after it opened, and a screenshot of the **+** menu.
