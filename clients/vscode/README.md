# Troupe for VS Code

Opens Troupe's terminal client, `troupe`, in a VS Code terminal rooted at the workspace
folder you are working in: by default a tab in the editor area, to split and tile beside
your files. The terminal client is the product; this extension is a door to it, so that
reaching Troupe from VS Code is one click or one key rather than a terminal opened by hand
and a `cd`, and asking it about a file is two clicks. Beside it, the Troupe side bar shows
that folder's settings as Troupe itself resolves them, and the models there are to choose
from.

What it does, its commands and settings, installing it and what it never sends:
[Troupe in VS Code](https://github.com/it-minds/troupe/blob/main/docs/user/vscode.md).

## Building it

`clients/vscode` is a pnpm project of its own, TypeScript compiled with `tsc`, with no
runtime dependencies: the `.vsix` is its own code, its two icons, `package.json`, this
README, LICENSE and NOTICE. Its build and test tools are under the repository's licence
policy like every other package
([third-party-licences.md](../../docs/third-party-licences.md)). With Node and pnpm (the
versions in `.tool-versions` and `package.json`):

```
cd clients/vscode
pnpm install
pnpm package        # writes troupe.vsix
```

CI also builds one on every pull request that changes the extension, as the run's
`troupe-vscode` artifact.

## Testing it

- `pnpm test`: unit tests for everything that needs no VS Code: the folder choice,
  the search for `troupe` (the extensionless file included), the line each command types
  and the path "Ask Troupe" writes, the Settings view's rows and its Models group (never a
  key), opening with the folder, and the manifest (no Windows key on Ctrl+Alt, every icon
  in the package). The line is also put through each shell the machine has (sh, bash,
  zsh, dash, fish, Windows PowerShell, PowerShell 7, cmd.exe), with a folder name full of
  quotes, `$`, `&` and backticks and a task with double quotes, a line break, `%PATH%` and
  backslashes, and has to arrive as the arguments it was meant to be; so does the call a
  `.cmd` gets through cmd.exe for the Settings view.
- `pnpm test:vscode`: the extension inside a real VS Code, on a workspace of four folders,
  against a fake `troupe` that writes down how it was started, then waits, quits or fails
  as told, and answers `config --explain --json` and `models --json` with its own: every
  way of opening Troupe, the side bar, the four commands, "Ask Troupe", the profile, and
  `troupe.openOnFolderOpen` in two more windows on one folder. A run ends when its window
  reloads and runs with workspace trust off, so a real reload and the untrusted case were
  checked by hand (Decision 816). VS Code is downloaded, or `TROUPE_VSCODE_EXECUTABLE`
  names one, and runs with its own user data and extensions under `.vscode-test/`, so
  nobody's profile is read or changed. On Linux without a display, run it under
  `xvfb-run -a`.
- CI runs both on Linux and Windows, and macOS in a full run, then builds the `.vsix`
  ([ci.md](../../docs/developer/ci.md)).

Apache-2.0, as the rest of [Troupe](https://github.com/it-minds/troupe).
