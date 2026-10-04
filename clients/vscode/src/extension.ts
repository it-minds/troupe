// Troupe: Open, from the command palette, the status bar, its key, an editor's title bar or
// the activity bar's Troupe: the terminal client in a VS Code terminal, by default a tab in
// the editor area to tile beside the files, rooted at the folder the work is in. Beside it
// in the side bar, what Troupe's settings are for that folder, as Troupe itself says. The
// extension is a door to the TUI and nothing more: it sends nothing anywhere and keeps no
// data of its own.
//
// What it decides with (the folder, the program, the line for the shell, the sentence when
// Troupe is missing, the rows of the settings) is in the modules beside this one, without
// VS Code, where the unit tests reach it. This and settingsView.ts are what VS Code calls.

import * as os from "node:os";
import * as vscode from "vscode";
import { findTroupe, type Missing } from "./binary.js";
import { chooseFolder } from "./folder.js";
import { INSTALL_URL, machineName, missingMessage } from "./host.js";
import { SettingsView } from "./settingsView.js";
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

// What `open` works with: the terminals, the side bar's list to tell when they change, and
// the icon their tabs carry.
interface Door {
  tracked: Map<string, Tracked>;
  list: Folders;
  icon: { light: vscode.Uri; dark: vscode.Uri };
}

export function activate(context: vscode.ExtensionContext): void {
  const tracked = new Map<string, Tracked>();
  const list = new Folders(tracked);
  const media = (file: string) => vscode.Uri.joinPath(context.extensionUri, "media", file);
  const door: Door = { tracked, list, icon: { light: media("troupe-light.svg"), dark: media("troupe.svg") } };

  // The activity bar's Troupe opens Troupe as it shows its list: the button is the door, and
  // the list is for another folder of the workspace. Where opening would mean a question,
  // the list is the question.
  const view = vscode.window.createTreeView("troupe.folders", { treeDataProvider: list });

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

  const settings = new SettingsView(() => working(door), locate, (found) => missingMessage(found, here()));
  const follow = () => settings.view.visible && settings.follow();

  context.subscriptions.push(
    status,
    view,
    list,
    settings,
    view.onDidChangeVisibility(({ visible }) => {
      if (visible) void open(door, { quiet: true });
    }),
    settings.view.onDidChangeVisibility(follow),
    vscode.window.onDidChangeActiveTextEditor(follow),
    vscode.window.onDidChangeActiveTerminal(follow),
    vscode.workspace.onDidSaveTextDocument((document) => settings.saved(document.uri)),
    vscode.workspace.onDidChangeWorkspaceFolders(() => (showStatus(), list.changed(), follow())),
    // From a row of the list, the folder's URI; from an editor's title bar, the file's;
    // from anywhere else, nothing.
    vscode.commands.registerCommand("troupe.open", (folder?: unknown) =>
      open(door, folder instanceof vscode.Uri ? { folder } : {}),
    ),
    vscode.commands.registerCommand("troupe.refreshSettings", () => settings.refresh()),
    vscode.window.onDidCloseTerminal((terminal) => {
      for (const [key, t] of tracked) if (t.terminal === terminal) tracked.delete(key);
      list.changed();
    }),
    vscode.window.onDidStartTerminalShellExecution((e) => busy(e.terminal, true)),
    vscode.window.onDidEndTerminalShellExecution((e) => busy(e.terminal, false)),
  );
}

export function deactivate(): void {}

// `folder`: the one asked for. `quiet`: opened by showing the side bar, which says itself
// that there is no folder, and whose list is the question when there are several.
async function open(door: Door, how: { folder?: vscode.Uri; quiet?: boolean }): Promise<Opened> {
  const { tracked } = door;
  const folders = vscode.workspace.workspaceFolders ?? [];
  const document = vscode.window.activeTextEditor?.document.uri;
  const active = vscode.window.activeTerminal;

  const choice = chooseFolder({
    given: how.folder && vscode.workspace.getWorkspaceFolder(how.folder),
    editor: document && vscode.workspace.getWorkspaceFolder(document),
    terminal: [...tracked.values()].find((t) => t.terminal === active)?.folder,
    folders,
  });

  if ("none" in choice) {
    if (how.quiet) return { noFolder: true };
    void vscode.window
      .showInformationMessage("Troupe opens in a folder: open one first.", "Open Folder…")
      .then((pick) => pick && vscode.commands.executeCommand("workbench.action.files.openFolder"));
    return { noFolder: true };
  }

  if ("ask" in choice && how.quiet) return { cancelled: true };

  const folder =
    "folder" in choice
      ? choice.folder
      : await vscode.window.showWorkspaceFolderPick({ placeHolder: "Open Troupe in which folder?" });
  if (folder === undefined) return { cancelled: true };

  const name = `Troupe: ${folder.name}`;
  const key = folder.uri.toString();
  const existing = tracked.get(key) ?? adopt(door, folder, name);

  if (existing?.busy) {
    existing.terminal.show();
    return { opened: folder.uri.fsPath, terminal: name, reused: true };
  }

  const config = vscode.workspace.getConfiguration("troupe");
  const found = locate();

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

  const where = { name, cwd: folder.uri, iconPath: door.icon, location: location(config.get<string>("openIn", "editor")) };

  // A shell this does not know how to quote for runs `troupe` as the terminal's program.
  const terminal =
    shell === undefined
      ? vscode.window.createTerminal({ ...where, shellPath: found.path, shellArgs: args })
      : vscode.window.createTerminal(where);

  if (shell !== undefined) terminal.sendText(commandLine(shell, found.path, args));
  terminal.show();
  tracked.set(key, { folder, terminal, busy: true });
  door.list.changed();

  return { opened: folder.uri.fsPath, terminal: name, reused: false };
}

// The folder being worked in, for the side bar's Settings: the active editor's, then the
// Troupe terminal's in front, then the first. Never a question: the view follows the work.
function working(door: Door) {
  const document = vscode.window.activeTextEditor?.document.uri;
  const active = vscode.window.activeTerminal;

  return (
    (document && vscode.workspace.getWorkspaceFolder(document)) ??
    [...door.tracked.values()].find((t) => t.terminal === active)?.folder ??
    vscode.workspace.workspaceFolders?.[0]
  );
}

// The `troupe` program on the machine the terminal runs on.
function locate() {
  const config = vscode.workspace.getConfiguration("troupe");
  return findTroupe(config.get<string>("path", ""), {
    platform: process.platform,
    env: process.env,
    home: os.homedir(),
  });
}

function here() {
  return machineName(vscode.env.remoteName, process.env, os.hostname());
}

// `troupe.openIn`: a tab in the editor area, in the group in front or beside it, which
// splits and tiles as a file's tab does; or the terminal panel.
function location(openIn: string): vscode.TerminalLocation | vscode.TerminalEditorLocationOptions {
  if (openIn === "panel") return vscode.TerminalLocation.Panel;
  return { viewColumn: openIn === "beside" ? vscode.ViewColumn.Beside : vscode.ViewColumn.Active };
}

// A terminal of ours from before the window reloaded: VS Code keeps it, and its process,
// across the reload, and this map does not survive one. Whether anything runs in it is not
// known, so it is only shown.
function adopt(door: Door, folder: vscode.WorkspaceFolder, name: string) {
  const terminal = vscode.window.terminals.find((t) => t.name === name);
  if (terminal === undefined) return undefined;

  const t = { folder, terminal, busy: true };
  door.tracked.set(folder.uri.toString(), t);
  door.list.changed();
  return t;
}

// The side bar's list: the workspace's folders, each opening Troupe there, those with a
// Troupe terminal saying so.
class Folders implements vscode.TreeDataProvider<vscode.WorkspaceFolder> {
  private readonly emitter = new vscode.EventEmitter<void>();
  readonly onDidChangeTreeData = this.emitter.event;

  constructor(private readonly tracked: Map<string, Tracked>) {}

  changed() {
    this.emitter.fire();
  }

  dispose() {
    this.emitter.dispose();
  }

  getChildren() {
    return [...(vscode.workspace.workspaceFolders ?? [])];
  }

  getTreeItem(folder: vscode.WorkspaceFolder) {
    const open = this.tracked.has(folder.uri.toString());
    const item = new vscode.TreeItem(folder.name);

    item.iconPath = new vscode.ThemeIcon(open ? "terminal" : "folder");
    if (open) item.description = "open";
    item.tooltip = folder.uri.fsPath;
    item.command = { command: "troupe.open", title: "Open Troupe here", arguments: [folder.uri] };
    return item;
  }
}

// The sentence, with the link beside it, and the sentence again for the caller.
function tell(missing: Missing) {
  const message = missingMessage(missing, here());
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
