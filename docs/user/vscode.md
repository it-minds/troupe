# Troupe in VS Code

The VS Code extension opens the [terminal client](../../clients/tui/README.md) in a VS
Code terminal rooted at the folder you are working in: by default a tab in the editor area,
which you split and tile beside your files as you would a file's. It is a door to the TUI
and nothing more: the sessions, the approvals and the settings are the TUI's, and the TUI
is the same program it is in any other terminal. Its side bar shows the folder's settings
as Troupe resolves them.

## Installing it

The extension is not on the Visual Studio Marketplace or Open VSX yet. Every release and
pre-release attaches it as `troupe.vsix`, covered by the release's `SHA256SUMS`, and the
installers install it with `--vscode` (`-VSCode` on Windows): they download it with the
rest, check it, and hand it to VS Code's own `code --install-extension`. Asked which
clients to install, they ask about it too where VS Code is. Each release's notes open with
one line that installs the daemon, the TUI and the extension from that release:

```
curl -fsSLO https://github.com/it-minds/troupe/releases/download/<tag>/install.sh && sh install.sh --tui --vscode
```

```
irm https://github.com/it-minds/troupe/releases/download/<tag>/install.ps1 -OutFile install.ps1; if ($?) { powershell -ExecutionPolicy Bypass -File .\install.ps1 -Tui -VSCode }
```

The installer is downloaded whole and then run, never piped into a shell, and it shows its
plan and asks before it changes anything (Decision 682). The `if ($?)` is not decoration:
PowerShell runs the next statement on a line after `irm` fails, which would run an older
`install.ps1` left in the directory. `code` is found on the `PATH`, then where VS Code's
setups put it; `TROUPE_VSCODE_CLI` names another. A VS Code window open already may need
**Developer: Reload Window**. `--uninstall` (`-Uninstall`) removes the extension as well.

The `.vsix` by itself installs with **Extensions: Install from VSIX…** in the command
palette, or `code --install-extension troupe.vsix`. CI also builds one on every pull
request that changes the extension, as the run's `troupe-vscode` artifact.

To build it yourself, with Node and pnpm (the versions in `.tool-versions` and
`clients/vscode/package.json`):

```
cd clients/vscode
pnpm install
pnpm package        # writes troupe.vsix
```

`troupe` itself has to be installed where the terminal runs
([quick start](../quick-start.md#1-install)); the extension does not install it.

## Opening Troupe

Each of these opens Troupe:

- **The Troupe mask in an editor's title bar**, at the top right of the editor group,
  beside the other tools' icons there: Troupe at that file's folder. It is not on a
  Troupe terminal's own tab, nor in a window with no folder open.
- **The Troupe mask in the activity bar**: Troupe at the folder you are working in, as the
  [side bar](#the-troupe-side-bar) opens.
- **Troupe: Open** in the command palette, or the **Troupe** item in the status bar.
- <kbd>Shift</kbd>+<kbd>Alt</kbd>+<kbd>T</kbd> on Windows,
  <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Alt</kbd>+<kbd>T</kbd> on Linux,
  <kbd>Cmd</kbd>+<kbd>Shift</kbd>+<kbd>Alt</kbd>+<kbd>T</kbd> on macOS. Windows has no
  Ctrl+Alt key of its own: Ctrl+Alt is AltGr there, and on a layout that gives the key a
  character with AltGr (US-International's Þ, for one), VS Code types the character. The
  left <kbd>Alt</kbd> it is, then; on such a layout the right one is AltGr. With a terminal
  in front, the key goes to the terminal, as any key does.

It opens a terminal named `Troupe: <folder>` whose working directory is the folder, and
types one line into it:

```
troupe --workspace <folder>
```

`--workspace` roots the TUI's session at the folder whichever directory `troupe` starts
in, so the line says where the work is even when the shell's start-up files change
directory. `troupe --workspace DIR` does the same from any terminal.

- **Where it opens.** A tab in the editor group in front, with Troupe's mask on it. It
  drags to another group, splits and tiles as a file's tab does. The `troupe.openIn`
  setting makes it `beside`, a group beside the one in front (opening one when there is
  none), or `panel`, the terminal panel below the editors. A terminal already open stays
  where it is.
- **Which folder.** From an editor's title bar or a row of the side bar's list, that
  file's or that folder's. Otherwise the folder of the file in the active editor; in a
  workspace of several folders that is the one being worked on. With no editor open, the
  folder of the Troupe terminal in front, then the only folder there is. With several
  folders and nothing to go by, the command palette and the key ask which, once, and the
  activity bar leaves the choice to the side bar's list. With no folder open it says to
  open one.
- **One terminal per folder.** Pressing it again shows that folder's terminal rather than
  opening a second one.
- **Quitting the TUI closes its terminal**, and so its tab. The line ends with `exit` when
  `troupe` ends with status 0. When it fails to start, the terminal stays open with the
  reason above the shell's prompt, and the next press runs it again there; that takes VS
  Code's shell integration, which tells the extension when the line has finished
  (PowerShell, bash, zsh and fish have it). Without it, a press shows the terminal and you
  run the line again yourself.
- **The line is typed for the terminal's shell**: PowerShell, Command Prompt, bash, zsh,
  sh or fish, with the program's full path and the folder quoted for that shell. A shell
  it does not know how to quote for (nushell, or WSL's own shell as the default profile on
  Windows) gets a terminal that runs `troupe` directly instead, which closes when `troupe`
  exits, whatever its status.

## The Troupe side bar

The Troupe mask in the activity bar opens Troupe, as above, and a side bar of two views.

**Folders** lists the workspace's folders, those with a Troupe terminal marked *open*. A
click on one opens Troupe there, or shows its terminal. In a workspace of several folders
with no file open, this list is where you choose.

**Settings** is what Troupe says its settings are for the folder you are working in (the
active editor's, then the Troupe terminal's in front, then the first), from
`troupe config --explain --json` run on the machine the terminal runs on. The extension
reads no config file itself, so what the view shows is what a session there would get,
layers merged and untrusted keys left out as Troupe decides
([configuration.md](configuration.md)).

- **Model**: the provider, the endpoint, whether a key is set, the default, cheap and
  expensive models, and the named providers. Each says which layer set it: `default`,
  `user`, `project`, `local` or the environment.
- **Changed from the defaults**: every other key a file or the environment sets.
- **Files**: the user file, the project's `.troupe/config.yaml` and the local
  `.troupe/config.local.yaml`. A click opens one; one that is not there opens as a new file,
  which saving makes. Under them, whether the workspace is
  [trusted](configuration.md#trusted-workspaces): until it is, its own files cannot set the
  provider, endpoints and keys, approvals, MCP servers or paths.
- **Problems**, when there are any: the files' warnings and refusals. A click opens the
  file at the line.
- **All settings**, folded: every key and the layer it came from.

Hover a row for the value each layer gave it, and why a repository's value was ignored. A
click on a row opens the file that set it. The view asks again when the folder you are
working in changes, when one of those files is saved in VS Code, and on **Refresh** in its
title bar; never while it is hidden. **A key is never shown**, masked or not: the view says
only whether one is set.

The models there are to choose from, with their windows and prices, are not in the view
yet: they wait on a JSON form of `troupe models` (#387).

## Finding `troupe`

In this order:

1. The `troupe.path` setting, when it is set: a path (`~/` is your home directory), or a
   name looked up on the `PATH`.
2. The first `troupe` on the `PATH`.
3. Where the installer puts it: `%LOCALAPPDATA%\Programs\troupe\troupe.exe` on Windows,
   `~/.local/bin/troupe` on Linux and macOS. A VS Code started before the installer
   changed the `PATH` does not see the change until it is restarted; this finds it anyway.

On Windows only a `.exe`, `.cmd` or `.bat` is run, and `troupe.exe` is preferred. A file
named `troupe` with no extension is never run: Windows cannot run one, and handing it to
the shell opens it in whatever program is associated with it, which is how an editor once
opened instead of Troupe (#231). Relative entries on the `PATH` are skipped.

When none is found, one sentence says so, with a **How to install** button that opens the
install instructions, and no terminal is opened. The Settings view says the same sentence.

## Settings

| Setting | Default | |
|---|---|---|
| `troupe.path` | empty | The `troupe` program to run: a path, or a name looked up on the `PATH`. |
| `troupe.args` | `[]` | More arguments for `troupe`: `["--no-mouse"]` lets the terminal's own selection work, `["--watch"]` starts in watch mode. |
| `troupe.openIn` | `editor` | Where the terminal opens: `editor`, a tab in the editor group in front; `beside`, a group beside it; `panel`, the terminal panel. |

All three are user and remote settings only (`machine` scope). A repository's
`.vscode/settings.json` is not yours to trust, and it cannot choose the program the
terminal runs, nor add `--auto-approve` or `--full-send` to it.

## Remote development

In a WSL, SSH, dev container or Codespaces window, the integrated terminal runs on the
remote host. So does the extension (it is a workspace extension), and VS Code offers to
install it there; it then looks for `troupe` on that host, the TUI it opens works on
that host's files, and the Settings view is that host's configuration. When `troupe` is
missing there, the message names the host as VS Code's remote indicator does:

> Troupe isn't installed in WSL: Ubuntu (no troupe on the PATH, nor where the installer
> puts it).

Install it on that host with `install.sh` and press **Troupe: Open** again.

## What it does not do

**It collects nothing and sends nothing anywhere**: no telemetry, no network request of
its own. It reads its three settings, looks for `troupe` on the disk, types one line into
a terminal, and runs `troupe config --explain --json` on the same machine for the
Settings view, which reads the config files and sends nothing.

Not yet, and tracked in #378: commands for `troupe resume`, `troupe run`, `troupe doctor`
and `troupe config`; explorer and editor menu items that open Troupe with a file's path in
the prompt; opening Troupe when a folder opens; choosing the terminal profile; changing a
setting, or trusting the workspace, from the Settings view; and a version check against
the TUI. The panel that would show a session inside VS Code over the daemon's Agent Client
Protocol is a later version.

## How it is built and tested

`clients/vscode` is a pnpm project of its own, TypeScript compiled with `tsc`, with no
runtime dependencies: the `.vsix` is its own code, its two icons, `package.json`, the
README, LICENSE and NOTICE. Its build and test tools are under the repository's licence
policy like every other package ([third-party-licences.md](../third-party-licences.md)).

- `pnpm test`: unit tests for the folder choice, the search for `troupe` (on Linux and
  Windows file systems, the extensionless file included), the message, the line for each
  shell, the Settings view's rows (never a key, a repository's ignored value and why, the
  files and the trust), and the manifest (no Windows key on Ctrl+Alt, every icon in the
  package). The line is also put through each shell the machine has (sh, bash, zsh, dash,
  fish, Windows PowerShell, PowerShell 7, cmd.exe), with a folder name full of quotes,
  `$`, `&` and backticks, and has to arrive as the arguments it was meant to be; so is the
  call a `.cmd` gets through cmd.exe for the Settings view.
- `pnpm test:vscode`: the extension inside a real VS Code, against a fake `troupe` that
  writes down the directory and arguments it was started with and then waits, quits or
  fails as it is told, and answers `config --explain --json` with settings of its own, on a
  workspace of four folders: the editor tab, `beside` and `panel`, the editor title bar's
  file, the side bar's list and the activity bar, and the Settings view. It is downloaded,
  or `TROUPE_VSCODE_EXECUTABLE` names one, and runs with its own user data and extensions
  directories under `.vscode-test/`, so nobody's own profile is read or changed. On Linux
  without a display, run it under `xvfb-run -a`.
- CI runs both on Linux and Windows, and macOS in a full run, then builds the `.vsix`
  ([ci.md](../developer/ci.md)).
