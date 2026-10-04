# Troupe in VS Code

The VS Code extension opens the [terminal client](../../clients/tui/README.md) in VS
Code's integrated terminal, rooted at the folder you are working in. It is a door to the
TUI and nothing more: the sessions, the approvals and the settings are the TUI's, and the
TUI is the same program it is in any other terminal.

## Installing it

The extension is not on the Visual Studio Marketplace or Open VSX yet. CI builds it on
every pull request that changes it, as the run's `troupe-vscode` artifact, which holds
`troupe.vsix`. Install that with **Extensions: Install from VSIX…** in the command palette,
or:

```
code --install-extension troupe.vsix
```

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

**Troupe: Open** in the command palette, the **Troupe** item in the status bar, or
<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Alt</kbd>+<kbd>T</kbd>
(<kbd>Cmd</kbd>+<kbd>Shift</kbd>+<kbd>Alt</kbd>+<kbd>T</kbd> on macOS). It opens a terminal
named `Troupe: <folder>` whose working directory is the folder, and types one line into it:

```
troupe --workspace <folder>
```

`--workspace` roots the TUI's session at the folder whichever directory `troupe` starts
in, so the line says where the work is even when the shell's start-up files change
directory. `troupe --workspace DIR` does the same from any terminal.

- **Which folder.** The folder of the file in the active editor; in a workspace of several
  folders that is the one being worked on. With no editor open, the folder of the Troupe
  terminal in front, then the only folder there is. With several folders and nothing to go
  by, it asks which, once. With no folder open it says to open one.
- **One terminal per folder.** Pressing it again shows that folder's terminal rather than
  opening a second one.
- **Quitting the TUI closes its terminal.** The line ends with `exit` when `troupe` ends
  with status 0. When it fails to start, the terminal stays open with the reason above the
  shell's prompt, and the next press runs it again there; that takes VS Code's shell
  integration, which tells the extension when the line has finished (PowerShell, bash,
  zsh and fish have it). Without it, a press shows the terminal and you run the line again
  yourself.
- **The line is typed for the terminal's shell**: PowerShell, Command Prompt, bash, zsh,
  sh or fish, with the program's full path and the folder quoted for that shell. A shell
  it does not know how to quote for (nushell, or WSL's own shell as the default profile on
  Windows) gets a terminal that runs `troupe` directly instead, which closes when `troupe`
  exits, whatever its status.

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
install instructions, and no terminal is opened.

## Settings

| Setting | Default | |
|---|---|---|
| `troupe.path` | empty | The `troupe` program to run: a path, or a name looked up on the `PATH`. |
| `troupe.args` | `[]` | More arguments for `troupe`: `["--no-mouse"]` lets the terminal's own selection work, `["--watch"]` starts in watch mode. |

Both are user and remote settings only (`machine` scope). A repository's
`.vscode/settings.json` is not yours to trust, and it cannot choose the program the
terminal runs, nor add `--auto-approve` or `--full-send` to it.

## Remote development

In a WSL, SSH, dev container or Codespaces window, the integrated terminal runs on the
remote host. So does the extension (it is a workspace extension), and VS Code offers to
install it there; it then looks for `troupe` on that host, and the TUI it opens works on
that host's files. When `troupe` is missing there, the message names the host as VS
Code's remote indicator does:

> Troupe isn't installed in WSL: Ubuntu (no troupe on the PATH, nor where the installer
> puts it).

Install it on that host with `install.sh` and press **Troupe: Open** again.

## What it does not do

**It collects nothing and sends nothing anywhere**: no telemetry, no network request of
its own. It reads its two settings, looks for `troupe` on the disk, and types one line
into a terminal.

Not yet, and tracked in #378: commands for `troupe resume`, `troupe run`, `troupe doctor`
and `troupe config`; explorer and editor menu items that open Troupe with a file's path in
the prompt; opening Troupe when a folder opens; choosing the terminal profile; and a
version check against the TUI. The panel that would show a session inside VS Code over
the daemon's Agent Client Protocol is a later version.

## How it is built and tested

`clients/vscode` is a pnpm project of its own, TypeScript compiled with `tsc`, with no
runtime dependencies: the `.vsix` is its own code, `package.json`, the README, LICENSE and
NOTICE. Its build and test tools are under the repository's licence policy like every
other package ([third-party-licences.md](../third-party-licences.md)).

- `pnpm test`: unit tests for the folder choice, the search for `troupe` (on Linux and
  Windows file systems, the extensionless file included), the message and the line for
  each shell. The line is also put through each shell the machine has (sh, bash, zsh,
  dash, fish, Windows PowerShell, PowerShell 7, cmd.exe), with a folder name full of
  quotes, `$`, `&` and backticks, and has to arrive as the arguments it was meant to be.
- `pnpm test:vscode`: the extension inside a real VS Code, against a fake `troupe` that
  writes down the directory and arguments it was started with and then waits, quits or
  fails as it is told, on a workspace of four folders. It is downloaded, or
  `TROUPE_VSCODE_EXECUTABLE` names one, and runs with its own user data and extensions
  directories under `.vscode-test/`, so nobody's own profile is read or changed. On Linux
  without a display, run it under `xvfb-run -a`.
- CI runs both on Linux and Windows, and macOS in a full run, then builds the `.vsix`
  ([ci.md](../developer/ci.md)).
