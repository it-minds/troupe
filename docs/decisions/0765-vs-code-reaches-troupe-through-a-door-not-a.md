---
number: 765
title: "VS Code reaches Troupe through a door, not a second client: the extension in `clients/vscode` has one command that opens anything, `Troupe: Open`, which types `troupe --workspace <folder>` into a terminal it opens at that folder, by default a tab in the editor area, one terminal per folder; its side bar shows the folder's settings as `troupe config --explain --json` reports them; and every release attaches it as `troupe.vsix`, which the installers' `--vscode` installs, on no marketplace yet"
date: 2026-10-04
status: accepted
issue: 378
paths:
  - .github/dependabot.yml
  - .github/workflows/release.yml
  - scripts/version.exs
gist: "VS Code reaches Troupe through a door, not a second client: the extension in `clients/vscode` has one command that opens anything, `Troupe: Open`…"
---

Issue #378's v1, its first slice; the TUI
is the product (#378), and the panel over the daemon's ACP is v2.
- **Where it lives and how it ships.** A pnpm project of its own, not a package of the
  GUI's workspace, which shares a protocol client the extension has no use for.
  TypeScript compiled by `tsc`, no runtime dependencies, so the `.vsix` that
  `vsce package --no-dependencies` makes is its own code with LICENSE and NOTICE,
  copied in at packaging as every release artifact carries them. `dev-check.yml` and
  `ci.yml` keep the `.vsix` as the run's artifact. The Marketplace
  or Open VSX, a version check against the TUI, and telemetry are not in it, as decided
  on the issue; the README says there is no telemetry. Its id is
  `objective-mj.troupe`, under the desktop app's identifier (710), and its version is
  VERSION without the pre-release part, kept by `scripts/version.exs`, because
  `vsce publish` refuses a pre-release version as WiX does (the desktop app's reason).
  Dependabot moves its tools monthly; `@types/vscode`, the API `engines.vscode`
  promises (1.93, for shell integration's events), and `@types/node`'s major, the
  Node that version runs, move by hand with that line.
- **A line typed into the person's shell, not the TUI as the terminal's program.**
  VS Code disposes a terminal whose program exits, and with it the one line a failed
  start prints (`troupe: could not start: …`, #231); and the person's shell carries
  their profile and environment. The line is the program's absolute path, quoted for
  the shell `vscode.env.shell` names (PowerShell, cmd.exe, the POSIX family, fish),
  then `exit` when the status is 0, so quitting the TUI closes its terminal and a
  failure leaves it open with the reason. A shell whose quoting is not known here
  (nushell, or WSL's launcher as the default profile on Windows, whose Linux shell
  cannot run a Windows path) gets `troupe` as the terminal's program instead.
- **`--workspace` and the `cwd` both.** `troupe --workspace DIR` was already parsed for
  every mode and roots the TUI's session at DIR whichever directory it starts in; it
  was documented only for `troupe run`. `clients/tui/lib/troupe/cli.ex` is unchanged
  and the TUI needs no decision of its own: a test pins it and the TUI's README shows
  it. The extension passes it as well as setting the terminal's `cwd`, so a shell whose
  start-up files change directory does not move the work.
- **Which folder.** The active editor's; with none, the Troupe terminal in front, so a
  second press from it finds it again without asking; then the only folder; with
  several and nothing to go by, a question, once. **One terminal per folder**: a press
  shows it again while something runs in it, and runs the line again in it once shell
  integration says the line ended (a failed start). Without shell integration it is
  only shown. A terminal from before a window reload, which VS Code keeps with its
  process, is found by its name and only shown.
- **A tab in the editor area, by default.** A terminal in the panel cannot be tiled
  with the files, and the TUI is what is being worked in, so it opens where files open:
  `createTerminal`'s `location`, a tab in the editor group in front, with Troupe's mask
  as its icon. `troupe.openIn` (`editor`, `beside`, `panel`) keeps the panel for whoever
  wants it; it is `machine` scoped like the other two, so one rule covers every setting
  read, though where a terminal opens is no risk.
- **Four ways in to the one command.** The mask in an editor's title bar
  (`editor/title`, `navigation`, beside other tools' icons there), which hands the
  command the file's URI, so the file's folder. The mask in the activity bar: a view
  container whose Folders view opens Troupe when it is shown, since VS Code has no
  activity-bar item that only runs a command; its list of folders is where a workspace
  of several chooses, so that way in never asks. The command palette and the status
  bar. And the key: <kbd>Shift</kbd>+<kbd>Alt</kbd>+<kbd>T</kbd> on Windows,
  <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Alt</kbd>+<kbd>T</kbd> on Linux and
  <kbd>Cmd</kbd>+<kbd>Shift</kbd>+<kbd>Alt</kbd>+<kbd>T</kbd> on macOS. On Windows
  Ctrl+Alt is AltGr, and unless `keyboard.mapAltGrToCtrlAlt` is on, VS Code types the
  character a layout gives AltGr+Shift+T (Þ on US-International) instead of running a
  Ctrl+Alt key; Shift+Alt+T has no default binding in VS Code 1.140. A unit test keeps
  every Windows key off Ctrl+Alt.
- **The settings shown are Troupe's answer, not the extension's reading.** The side
  bar's Settings view runs `troupe config --explain --json --workspace <folder>` where
  the terminal runs (half a second here) and shows its rows: the model (provider,
  endpoint, whether a key is set, the three models, the named providers), what else
  differs from the defaults and which layer set it, the three files and whether the
  workspace is trusted, the warnings and refusals, and every key, folded. Merging the
  layers and deciding which of a repository's keys apply stay Troupe's, so the view
  cannot disagree with a session. It asks only while shown: when the folder worked in
  changes, when a file the answer named is saved, and on Refresh. A key is shown as set
  or not set, never even masked; a unit test fails on `sk-` anywhere in the rows. A
  `.cmd` `troupe` (the suite's fake, or a person's own wrapper) runs through
  `cmd.exe /d /s /c` with the line quoted as the terminal's is, since Node runs no batch
  file without a shell. The models to choose from, with windows and prices, wait on
  `troupe models --json` (#387).
- **A release attaches it, and one line installs it to try.** `release.yml` and
  `prerelease.yml` build the `.vsix` as `dev-check.yml` does and attach it as
  `troupe.vsix`, in the release's `SHA256SUMS` with the rest. `install.sh --vscode` and
  `install.ps1 -VSCode` download it with the rest, check it, and hand it to VS Code's
  own `code --install-extension --force`: `code` on the `PATH`, then where VS Code's
  setups put it, or `TROUPE_VSCODE_CLI`. Without one, `--vscode` stops before the plan.
  Asked which clients to install, they ask about the extension only where `code` is,
  yes by default where the TUI is being installed on a fresh machine; `code` is run
  only then, never for the summary, since a first `code` in WSL sets up VS Code's
  server. A failed `--install-extension` is a warning, the rest being installed, and
  `--uninstall` removes the extension too. Each release's notes open with one line per
  system that installs the daemon, the TUI and the extension from that release:
  `curl -fsSLO …/install.sh && sh install.sh --tui --vscode`, and `irm …/install.ps1
  -OutFile install.ps1; if ($?) { powershell -ExecutionPolicy Bypass -File
  .\install.ps1 -Tui -VSCode }`. That is Decision 682's download, then run, on one
  line, not a pipe into a shell: the file is whole before it runs, stays to be read,
  and still shows its plan and asks. The `if ($?)` is needed: in Windows PowerShell
  5.1 and PowerShell 7 alike, the statement after a failed `irm` on the same line
  runs, which would run an older `install.ps1` left in the directory.
- **Finding `troupe`**, where the terminal runs: `troupe.path`, then the `PATH`, then
  where the installers put it, which a window older than the installer's change to the
  `PATH` would otherwise miss. On Windows only a `.exe`, `.cmd` or `.bat`, `.exe`
  first, and never a file without an extension, which Windows hands to whatever opens
  it (#231); a relative `PATH` entry is never searched. The extension is a workspace
  extension, so in a WSL, SSH or container window it runs, and looks, on the remote
  host, and a missing `troupe` is one sentence that names that host as VS Code's
  remote indicator does, with a link to the install instructions and no terminal.
- **Both settings are `machine` scoped.** A repository's `.vscode/settings.json` could
  otherwise choose the program the terminal runs, or add `--auto-approve` to it. With
  nothing read from the workspace, the extension runs in untrusted workspaces too;
  Troupe's own trust (`troupe config trust`) is what governs the repository's files.
- **Six build tools under licences the policy does not allow**, all brought by
  `@vscode/vsce`: Microsoft's own licence for `@vscode/vsce-sign`, which vsce loads to
  package anything, and Artistic-2.0 for `istextorbinary` and four of its
  dependencies, through vsce's secret scan. They are recorded in
  `scripts/licences.exs` as reviewed exceptions, for approval on the pull request:
  none ships, and none is changed. Refused, the alternative is a packager of our own;
  a `.vsix` is a zip of the extension with two XML files.
- **Not in this slice**, and #378 stays open for them: commands for `troupe resume`,
  `troupe run`, `troupe doctor` and `troupe config` (which need a decision on "the
  same terminal" while a TUI runs in it), explorer and editor items that put a path in
  the TUI's prompt (which needs a way into the prompt from outside), opening on folder
  open, the terminal profile setting, and changing a setting or trusting the workspace
  from the Settings view, which writes the person's own files.
- **Proof:** the TUI's `cli_test` ("--workspace roots the TUI at DIR"), which passes on
  the chunk's tip, so this confirms rather than fixes, and stays as the pin. The
  extension's unit tests (the folder, the search on Linux and Windows file systems with
  the #231 file, the sentence, the line for each shell), which also put the line
  through every shell the machine has with a folder name of quotes, `$`, `&` and
  backticks: Windows PowerShell 5.1, PowerShell 7 and cmd.exe here, and sh, bash and
  dash in WSL. Its suite inside VS Code 1.140 on Windows, with its own user data and
  extensions directories, against a fake `troupe` on a workspace of four folders: the
  active editor's folder, `--workspace` and the `cwd`; a second press reusing the
  terminal; the other root from its own editor; no editor, so the terminal in front;
  a clean quit closing the terminal; a failed start keeping it and running again on
  the next press; a missing `troupe` as the sentence and no terminal; and an
  extensionless `troupe` beside the `.cmd` never opened. With the editor area and the
  side bar, 33 unit tests (2 skipped: sh and fish on Windows) and 14 of 14 in VS Code:
  the tab in the editor group in front by default, `beside` in group two, `panel` with
  no tab; a folder handed to the command, as the list and the title bar hand it; the
  activity bar opening Troupe at the editor's folder and, shown again, only showing
  it; and the Settings view's rows from the fake's `config --explain --json`, with no
  key in them and the call not counted as a start. CI runs both on Linux and
  Windows, macOS in a full run. And installed: the `.vsix` put into a scratch VS Code
  profile, whose terminals had scratch homes, found the installed `troupe.exe` on the
  `PATH` and ran it through PowerShell 7 at the folder, the TUI's session recorded with
  that folder as its workspace and a second press reusing its terminal; and the
  installed `troupe.exe --workspace DIR`, typed into a terminal in another directory,
  rooted its session at DIR and none at the directory it started in. Then into a
  person's own VS Code 1.140 on a US-International layout, used by hand: the key, the
  tab, the title bar's and the activity bar's masks; and the Settings rows made from
  that machine's real `troupe config --explain --json`, which showed its gateway, its
  models and the workspace untrusted, and no key. The installers against a local
  mirror of v0.8.0-beta with this `troupe.vsix` and a `SHA256SUMS` over both, every
  Troupe directory a scratch one: `install.ps1 -VSCode -Yes` under Windows PowerShell
  5.1 with a recording `code.cmd` that writes to stderr, and under PowerShell 7 with
  the real `code.cmd`, which installed it; without any `code`, refused before the plan
  with nothing made. `install.sh --vscode -y` under dash in WSL with a scratch `HOME`
  and a recording `code`: installed, then `--uninstall -y` removed the extension;
  through a pseudo-terminal, the question about it after the other two, `[y/N]` with
  the TUI declined; without `code`, refused before the plan. The release notes'
  heredocs rendered with sample values, `$?` and `.\install.ps1` as written. Not run:
  `-VSCode` asked interactively on Windows, and `release.yml`'s new steps, which run
  at the next release.
