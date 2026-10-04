// Troupe: Open, from the command palette, the status bar or its key: the terminal client
// in VS Code's terminal, rooted at the folder the work is in. The extension is a door to
// the TUI and nothing more: it sends nothing anywhere and keeps no data of its own.
//
// What it decides with (the folder, the program, the line for the shell, the sentence when
// Troupe is missing) is in the modules beside this one, without VS Code, where the unit
// tests reach it. This is what VS Code calls.

import * as os from "node:os";
import * as vscode from "vscode";
import { findTroupe, type Missing } from "./binary.js";
import { chooseFolder } from "./folder.js";
import { INSTALL_URL, machineName, missingMessage } from "./host.js";
import { commandLine, shellOf } from "./shell.js";

/** What `troupe.open` did. `executeCommand` returns it, which is what the tests read. */
export type Opened =
  | { opened: string; terminal: string; reused: boolean }
  | { missing: string }
  | { noFolder: true }
  | { cancelled: true };

// One terminal per folder. `busy` is whether something runs in it: set when the line is
// sent, and kept by shell integration's start and end events where the shell has them.
// Without them it stays true, and a press only shows the terminal again.
interface Tracked {
  folder: vscode.WorkspaceFolder;
  terminal: vscode.Terminal;
  busy: boolean;
}

export function activate(context: vscode.ExtensionContext): void {
  const tracked = new Map<string, Tracked>();

  const status = vscode.window.createStatusBarItem("troupe.open", vscode.StatusBarAlignment.Left);
  status.name = "Troupe";
  status.text = "$(terminal) Troupe";
  status.tooltip = "Open Troupe in this folder's terminal";
  status.command = "troupe.open";
  const showStatus = () => (vscode.workspace.workspaceFolders?.length ? status.show() : status.hide());
  showStatus();

  const busy = (terminal: vscode.Terminal, value: boolean) => {
    for (const t of tracked.values()) if (t.terminal === terminal) t.busy = value;
  };

  context.subscriptions.push(
    status,
    vscode.workspace.onDidChangeWorkspaceFolders(showStatus),
    vscode.commands.registerCommand("troupe.open", () => open(tracked)),
    vscode.window.onDidCloseTerminal((terminal) => {
      for (const [key, t] of tracked) if (t.terminal === terminal) tracked.delete(key);
    }),
    vscode.window.onDidStartTerminalShellExecution((e) => busy(e.terminal, true)),
    vscode.window.onDidEndTerminalShellExecution((e) => busy(e.terminal, false)),
  );
}

export function deactivate(): void {}

async function open(tracked: Map<string, Tracked>): Promise<Opened> {
  const folders = vscode.workspace.workspaceFolders ?? [];
  const document = vscode.window.activeTextEditor?.document.uri;
  const active = vscode.window.activeTerminal;

  const choice = chooseFolder({
    editor: document && vscode.workspace.getWorkspaceFolder(document),
    terminal: [...tracked.values()].find((t) => t.terminal === active)?.folder,
    folders,
  });

  if ("none" in choice) {
    void vscode.window
      .showInformationMessage("Troupe opens in a folder: open one first.", "Open Folder…")
      .then((pick) => pick && vscode.commands.executeCommand("workbench.action.files.openFolder"));
    return { noFolder: true };
  }

  const folder =
    "folder" in choice
      ? choice.folder
      : await vscode.window.showWorkspaceFolderPick({ placeHolder: "Open Troupe in which folder?" });
  if (folder === undefined) return { cancelled: true };

  const name = `Troupe: ${folder.name}`;
  const key = folder.uri.toString();
  const existing = tracked.get(key) ?? adopt(tracked, folder, name);

  if (existing?.busy) {
    existing.terminal.show();
    return { opened: folder.uri.fsPath, terminal: name, reused: true };
  }

  const config = vscode.workspace.getConfiguration("troupe");
  const found = findTroupe(config.get<string>("path", ""), {
    platform: process.platform,
    env: process.env,
    home: os.homedir(),
  });

  if ("missing" in found) return { missing: tell(found) };

  const args = ["--workspace", folder.uri.fsPath, ...words(config.get<unknown>("args"))];
  const shell = shellOf(vscode.env.shell, process.platform);

  // An idle shell: the TUI quit with an error, or was quit from, and the terminal stayed.
  if (existing !== undefined && shell !== undefined) {
    existing.terminal.sendText(commandLine(shell, found.path, args));
    existing.busy = true;
    existing.terminal.show();
    return { opened: folder.uri.fsPath, terminal: name, reused: true };
  }

  // A shell this does not know how to quote for runs `troupe` as the terminal's program.
  const terminal =
    shell === undefined
      ? vscode.window.createTerminal({ name, cwd: folder.uri, shellPath: found.path, shellArgs: args })
      : vscode.window.createTerminal({ name, cwd: folder.uri });

  if (shell !== undefined) terminal.sendText(commandLine(shell, found.path, args));
  terminal.show();
  tracked.set(key, { folder, terminal, busy: true });

  return { opened: folder.uri.fsPath, terminal: name, reused: false };
}

// A terminal of ours from before the window reloaded: VS Code keeps it, and its process,
// across the reload, and this map does not survive one. Whether anything runs in it is not
// known, so it is only shown.
function adopt(tracked: Map<string, Tracked>, folder: vscode.WorkspaceFolder, name: string) {
  const terminal = vscode.window.terminals.find((t) => t.name === name);
  if (terminal === undefined) return undefined;

  const t = { folder, terminal, busy: true };
  tracked.set(folder.uri.toString(), t);
  return t;
}

// The sentence, with the link beside it, and the sentence again for the caller.
function tell(missing: Missing) {
  const message = missingMessage(missing, machineName(vscode.env.remoteName, process.env, os.hostname()));
  const actions = missing.missing === "setting" ? ["How to install", "Open Settings"] : ["How to install"];

  void vscode.window.showErrorMessage(message, ...actions).then((pick) => {
    if (pick === "How to install") void vscode.env.openExternal(vscode.Uri.parse(INSTALL_URL));
    if (pick === "Open Settings") void vscode.commands.executeCommand("workbench.action.openSettings", "troupe.path");
  });

  return message;
}

function words(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((v): v is string => typeof v === "string") : [];
}
