# Troupe for VS Code

Opens Troupe's terminal client, `troupe`, in a VS Code terminal rooted at the workspace
folder you are working in: by default a tab in the editor area, to split and tile beside
your files. The terminal client is the product; this extension is a door to it, so that
reaching Troupe from VS Code is one click or one key rather than a terminal opened by hand
and a `cd`, and asking it about a file is two clicks. Beside it, the Troupe side bar shows
that folder's settings as Troupe itself resolves them, and the models there are to choose
from.

## Troupe: Open

Any of these opens a terminal named `Troupe: <folder>` and runs
`troupe --workspace <folder>` in it, with the terminal's working directory set to the same
folder:

- the Troupe mask in an editor's title bar, at the top right of the editor group, which
  opens it at that file's folder;
- the Troupe mask in the activity bar, which opens it as the side bar shows;
- **Troupe: Open** in the command palette, or the **Troupe** item in the status bar;
- <kbd>Shift</kbd>+<kbd>Alt</kbd>+<kbd>T</kbd> on Windows,
  <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Alt</kbd>+<kbd>T</kbd> on Linux,
  <kbd>Cmd</kbd>+<kbd>Shift</kbd>+<kbd>Alt</kbd>+<kbd>T</kbd> on macOS.

How it behaves:

- **Where it opens.** A tab in the editor group in front, which drags, splits and tiles as
  a file's tab does. `troupe.openIn` makes it `beside` (a group beside the one in front)
  or `panel` (the terminal panel).
- **Which folder.** The file's, from an editor's title bar or a row of the side bar's
  list; otherwise the folder of the file in the active editor. With no editor, the folder
  of the Troupe terminal in front, then the only folder; in a workspace of several folders
  with nothing to go by, it asks which.
- **One terminal per folder.** Pressing it again shows that folder's terminal instead of
  opening a second. Quitting the TUI closes its terminal. When the TUI fails to start, the
  terminal stays open with the reason in it, and the next press starts it again where the
  shell reports what it runs (VS Code's shell integration).
- **Finding `troupe`.** The `troupe.path` setting when it is set, otherwise the first
  `troupe` on the `PATH`, otherwise where the installer puts it
  (`%LOCALAPPDATA%\Programs\troupe\troupe.exe` on Windows, `~/.local/bin/troupe`
  elsewhere), which a VS Code started before the installer ran does not see on its `PATH`.
  On Windows only a `.exe`, `.cmd` or `.bat` is run, never a file without an extension.
- **When it is not there**, one sentence says so and which machine it looked on, with a
  link to the install instructions, and no terminal is opened.

## Troupe's other commands

From the command palette, each typed into the same folder's terminal, `Troupe: <folder>`:

| Command | Types |
|---|---|
| **Troupe: Resume Last Session Here** | `troupe resume --workspace <folder>` |
| **Troupe: Run a Task…** | asks for the task, then `troupe run --workspace <folder> -- "<task>"` |
| **Troupe: Doctor** | `troupe doctor --workspace <folder>` |
| **Troupe: Open Settings** | `troupe config --workspace <folder>` |

The folder is chosen as for **Troupe: Open**. The task is quoted for the terminal's
shell, quotes and all. Doctor's and Open Settings' terminal stays open when they finish,
for the report to be read; the others close it when the TUI quits, as Open does. When
something already runs in the folder's terminal, the TUI most likely, a command shows it
and types nothing into it, and says so.

## Ask Troupe about a file

Right-click a file in the explorer, in an editor, or on its tab: **Ask Troupe About This
File** opens Troupe at the file's folder with the file's path in its prompt, not yet sent,
for you to type the question after it:

```
troupe --workspace <folder> --prompt "@src/app.ts "
```

A folder in the explorer has **Ask Troupe About This Folder** (`@src/`). From the command
palette, the file is the one in the active editor. When Troupe already runs in that
folder's terminal, it is shown, and the message says what to type into it.

## Troupe in the terminal's profile menu

**Troupe** is a terminal profile: in the menu beside the terminal panel's **+**, and in
**Terminal: Create New Terminal (With Profile)**. It opens a new terminal whose program is
`troupe --workspace <folder>`, with `troupe.args`, at the folder **Troupe: Open** would
choose. No shell runs under it: quitting the TUI closes the terminal, and so does a TUI
that fails to start, so **Troupe: Open**, whose shell keeps the reason, is where to see
why. Each pick is a new terminal, even where the folder has Troupe open already.

## Opening Troupe with the folder

With `troupe.openOnFolderOpen` on, Troupe opens as **Troupe: Open** would when VS Code
opens a folder or a workspace. It does not open a second time when the window reloads with
Troupe's terminal still there (Troupe: Open shows that one too), and not in a workspace you
have not trusted (VS Code's
Restricted Mode) until you trust it. It is off unless you turn it on.

## The Troupe side bar

The mask in the activity bar opens Troupe at the folder you are working in, and shows two
views:

- **Folders**: the workspace's folders, those with a Troupe terminal marked open. A click
  opens Troupe there, or shows its terminal. In a workspace of several folders with no
  file open, this list is where you choose.
- **Settings**: what `troupe config --explain --json` says of the folder you are working
  in, following the active editor. The model (provider, endpoint, whether a key is set,
  the default, cheap and expensive models), what is changed from Troupe's defaults and by
  which layer, the config files (a click opens one, or starts it when it is not there),
  whether the workspace is trusted, the file's warnings, and every setting. Hover a row for
  each layer that had a say. It asks again when one of those files is saved, and on
  **Refresh**. A key is never shown, masked or not: only whether one is set. A config
  that does not load is shown as its errors, each opening its file at its line.
- **Models**, in the Settings view under the model in use: what `troupe models --json`
  lists for the folder. Each model with its window and price and where they came from,
  the default, cheap and expensive ones starred, and one its provider does not serve
  marked as such, with no window. The button on the group asks the providers again
  (`troupe models --refresh`); otherwise `troupe models` asks them only when its list is
  stale. When it cannot list them, the group says why in one line.

## Settings

| Setting | |
|---|---|
| `troupe.path` | The `troupe` program to run: a path, or a name looked up on the `PATH`. Empty by default. |
| `troupe.args` | More arguments for `troupe`, such as `["--no-mouse"]`, so the terminal's own selection works, or `["--watch"]`. |
| `troupe.openIn` | Where the terminal opens: `editor` (default), `beside` or `panel`. |
| `troupe.openOnFolderOpen` | Open Troupe when VS Code opens a folder: `false` (default) or `true`. |

All four are user or remote settings only. A repository's `.vscode/settings.json` cannot
choose the program the terminal runs, add `--auto-approve` to it, nor start Troupe as it is
opened.

## Remote development

In a WSL, SSH, dev container or Codespaces window the terminal runs on the remote host, so
the extension runs there too, and `troupe` has to be installed there: install the extension
in the remote window when VS Code offers to. The Troupe profile and opening with the folder
use that host's `troupe` as well. When it is missing, the message names the host, "Troupe
isn't installed in WSL: Ubuntu", for example.

## Installing

The extension is not on a marketplace yet. Every Troupe release attaches it as
`troupe.vsix`, and Troupe's installer installs it with `--vscode` (`-VSCode` on Windows),
`troupe` with it:

```
curl -fsSLO https://github.com/it-minds/troupe/releases/latest/download/install.sh && sh install.sh --tui --vscode
```

The `.vsix` by itself installs with **Extensions: Install from VSIX…** or
`code --install-extension troupe.vsix`.

## No telemetry

The extension collects nothing and sends nothing anywhere. It reads its four settings,
looks for `troupe` on the disk, types a `troupe` command line into a terminal or starts
`troupe` as one's program, keeps the process id of each folder's Troupe terminal in VS
Code's storage for the workspace, to know it after a window reload, and runs
`troupe config --explain --json` and `troupe models --json` on the same machine for the
Settings view. What Troupe itself sends, and to whom (`troupe models` asks your providers
what they serve), is in its own documentation.

More, and how it is built and tested:
[docs/user/vscode.md](https://github.com/it-minds/troupe/blob/main/docs/user/vscode.md).
Apache-2.0, as the rest of [Troupe](https://github.com/it-minds/troupe).
