---
number: 808
title: "The VS Code extension types `troupe resume`, `troupe run`, `troupe doctor` and `troupe config` into the folder's one terminal, never into one something runs in, and \"Ask Troupe About This File\" opens the TUI there with `--prompt \"@path \"`; a task's quotes are escaped for Windows PowerShell 5.1 and cmd.exe as each hands them on"
date: 2026-10-07
status: accepted
issue: 378
paths:
  - clients/vscode/src/extension.ts
  - clients/vscode/src/lines.ts
  - clients/vscode/src/shell.ts
  - clients/vscode/package.json
symbols:
  - typed
  - mention
  - commandLine
  - cmdWord
  - shellOf
gist: "Commands go into the folder's one terminal, never a busy one; Doctor/config keep it (no exit); Ask is --prompt '@path '; 5.1 and cmd escape a task's quotes"
---

- **The folder's one terminal.** Every command chooses the folder as Troupe: Open does
  (765) and types into `Troupe: <folder>`: opened as Open opens it when there is none, and
  typed into when it is idle, which shell integration's end event says (a report ended, a
  TUI failed to start or was quit from with an error). When something runs in it, Open
  shows it, as before; every other command shows it, types nothing, and says so in one
  sentence. What runs there is most likely the TUI, and a line typed now would be keys on
  whatever page it shows. Not chosen: a second terminal for the folder (two sessions where
  765 keeps one terminal a folder), the keys typed into the running TUI anyway (a page
  reads them as its own keys, and on Windows the console turns an escape sequence, a
  bracketed paste's, into keys too), and the clipboard (written without being asked).
  Without shell integration a terminal that has had a line stays busy, as 765 has it.
- **What each types.** Resume `troupe resume --workspace F`, Run `troupe run --workspace F
  -- TASK`, Doctor `troupe doctor --workspace F`, Open Settings `troupe config --workspace
  F`, Ask `troupe --workspace F --prompt TEXT` (`lines.ts`, `typed`). `--workspace` on
  each, as 765 has Open's. `troupe.args` goes on the four that open the TUI and not on the
  two reports. Those four end with `exit` after a clean quit (765); Doctor's and Open
  Settings' do not, since their output is what was asked for and `exit` on a 0 would close
  it away. The task follows `--`, so one that starts with a dash is the task and not a
  switch, which the TUI's `OptionParser` and the installed `troupe.exe` both honour. The
  task comes from a key's `args`, else an input box asked once the folder is known, its
  terminal free and `troupe` found, so neither a busy terminal nor a missing `troupe` is
  found out after a task was typed; an empty task is nothing.
- **Ask about a file.** Two commands, so a menu says what it acts on: "Ask Troupe About
  This File" and "Ask Troupe About This Folder", without the Troupe category, so a menu
  item names Troupe once and the palette does not say it twice. The explorer's menu has
  one or the other (`explorerResourceIsFolder`); an editor's text and its tab have the
  file's, for a file on a disk here or on the remote host (`resourceScheme` `file` or
  `vscode-remote`, so not a Troupe terminal's tab, a settings editor or an untitled file).
  In the palette the file's asks about the active editor's file, and the folder's is
  hidden, having none. The folder is the workspace folder the target is in; a file in
  none, or no file, is a sentence and no terminal. The prompt is `mention`'s: `@` and the
  path from the folder, with forward slashes, a folder's with one at the end and the
  folder itself `./`, then a space for the question; the TUI's own `@` completion writes
  the same. A path with whitespace, a quote or a backslash goes in double quotes, those
  two escaped, so where it ends is not a guess. The TUI is opened with it in its input,
  the cursor after it, nothing sent (TUI Decision 150).
- **A task is quoted for what each shell hands on.** A path never held a double quote or a
  line break; a task does. Windows PowerShell 5.1 puts an argument with a space between
  double quotes and escapes nothing inside, so `Fix the "login" bug` reached the program
  as `Fix the login bug`. PowerShell 7 escapes for a `.exe` itself, and on Linux and macOS
  always. So `shellOf` tells them apart by the program, `powershell` and `pwsh`, and only
  5.1's arguments are given pre-escaped as the C runtime reads them (a quote, the
  backslashes before one, the ones before the quote it adds). A `.cmd` `troupe` under
  PowerShell 7 gets what a batch file gets: its quotes are not reliably carried. cmd.exe's
  own idea of quoting ends at a quote the program reads as escaped (`\"`), so an `&` after
  it was cmd's to run: a word with a `"` or a `%` is quoted for the program and then has a
  `^` before each character cmd acts on, which cmd takes off, so `^"` leaves its quoting
  alone and `^%` stops a `%NAME%` being expanded, for the Settings view's call through
  `cmd.exe /d /s /c` too. A line break ends cmd's line wherever it is and nothing quotes
  one, so a space stands for it there; in PowerShell, the POSIX shells and fish, a line
  break inside the quotes is the shell's continuation and is carried as written.
- **Remote hosts** as 765: the extension runs and looks for `troupe` where the terminal
  runs, and the lines are the same there.
