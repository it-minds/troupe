# Troupe for VS Code

Opens Troupe's terminal client, `troupe`, in a VS Code terminal rooted at the workspace
folder you are working in: by default a tab in the editor area, to split and tile beside
your files. The terminal client is the product; this extension is a door to it, so that
reaching Troupe from VS Code is one click or one key rather than a terminal opened by hand
and a `cd`. Beside it, the Troupe side bar shows that folder's settings as Troupe itself
resolves them.

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
  **Refresh**. A key is never shown, masked or not: only whether one is set.

## Settings

| Setting | |
|---|---|
| `troupe.path` | The `troupe` program to run: a path, or a name looked up on the `PATH`. Empty by default. |
| `troupe.args` | More arguments for `troupe`, such as `["--no-mouse"]`, so the terminal's own selection works, or `["--watch"]`. |
| `troupe.openIn` | Where the terminal opens: `editor` (default), `beside` or `panel`. |

All three are user or remote settings only. A repository's `.vscode/settings.json` cannot
choose the program the terminal runs, nor add `--auto-approve` to it.

## Remote development

In a WSL, SSH, dev container or Codespaces window the terminal runs on the remote host, so
the extension runs there too, and `troupe` has to be installed there: install the extension
in the remote window when VS Code offers to. When it is missing, the message names the
host, "Troupe isn't installed in WSL: Ubuntu", for example.

## Installing

The extension is not on a marketplace yet. CI builds it on every change as a `.vsix`;
install that with **Extensions: Install from VSIX…** or
`code --install-extension troupe.vsix`.

## No telemetry

The extension collects nothing and sends nothing anywhere. It reads its three settings,
looks for `troupe` on the disk, types one line into a terminal, and runs
`troupe config --explain --json` on the same machine for the Settings view. What Troupe
itself sends, and to whom, is in its own documentation.

More, and how it is built and tested:
[docs/user/vscode.md](https://github.com/it-minds/troupe/blob/main/docs/user/vscode.md).
Apache-2.0, as the rest of [Troupe](https://github.com/it-minds/troupe).
