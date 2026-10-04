// The side bar's Settings view: the rows settings.ts makes of what `troupe config --explain
// --json` prints for the folder being worked in. It asks again when that folder changes,
// when a file the answer was read from is saved, and on Refresh; never while hidden.

import { execFile } from "node:child_process";
import * as vscode from "vscode";
import type { Found } from "./binary.js";
import { invocation, type Invocation } from "./run.js";
import { parseExplain, rows, type Row } from "./settings.js";

/** What `troupe.refreshSettings` shows. `executeCommand` returns it, which is what the tests read. */
export type Shown = { folder: string; rows: Row[] } | { noFolder: true };

export class SettingsView implements vscode.TreeDataProvider<Row>, vscode.Disposable {
  readonly view: vscode.TreeView<Row>;
  private readonly emitter = new vscode.EventEmitter<void>();
  readonly onDidChangeTreeData = this.emitter.event;

  private shown: Row[] = [];
  private folder: vscode.WorkspaceFolder | undefined;
  private files = new Set<string>();
  // The latest question; an answer to an older one, for a folder left since, is dropped.
  private asked = 0;

  constructor(
    private readonly current: () => vscode.WorkspaceFolder | undefined,
    private readonly locate: () => Found,
    private readonly missing: (found: Exclude<Found, { path: string }>) => string,
  ) {
    this.view = vscode.window.createTreeView("troupe.settings", { treeDataProvider: this, showCollapseAll: true });
  }

  dispose() {
    this.view.dispose();
    this.emitter.dispose();
  }

  /** The folder being worked in, asked about when it is not the one shown. */
  follow() {
    const folder = this.current();
    if (folder?.uri.toString() !== this.folder?.uri.toString() || this.shown.length === 0) void this.show(folder);
  }

  /** A file the answer came from was saved: ask again. */
  saved(uri: vscode.Uri) {
    if (this.view.visible && this.files.has(normal(uri.fsPath))) void this.show(this.folder);
  }

  refresh(): Promise<Shown> {
    return this.show(this.current());
  }

  private async show(folder: vscode.WorkspaceFolder | undefined): Promise<Shown> {
    const asked = ++this.asked;
    this.folder = folder;

    if (folder === undefined) {
      this.view.description = "";
      this.set([]);
      return { noFolder: true };
    }

    this.view.description = folder.name;
    this.set([{ label: "Asking Troupe…", icon: "loading~spin" }]);

    const answer = await this.ask(folder);
    if (asked === this.asked) this.set(answer);
    return { folder: folder.uri.fsPath, rows: answer };
  }

  private async ask(folder: vscode.WorkspaceFolder): Promise<Row[]> {
    const found = this.locate();
    if ("missing" in found) return [{ label: this.missing(found), icon: "error" }];

    const args = ["config", "--explain", "--json", "--workspace", folder.uri.fsPath];
    try {
      const explain = parseExplain(await run(invocation(found.path, args, process.platform, process.env["ComSpec"]), folder.uri.fsPath));
      this.files = new Set(explain.files.map((f) => normal(f.path)));
      return rows(explain);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return [
        {
          label: "Troupe could not say what its settings are",
          description: message.split(/\r?\n/)[0] ?? "",
          tooltip: "```\n" + message + "\n```",
          icon: "error",
        },
      ];
    }
  }

  private set(shown: Row[]) {
    this.shown = shown;
    this.emitter.fire();
  }

  getChildren(row?: Row) {
    return row ? (row.children ?? []) : this.shown;
  }

  getTreeItem(row: Row) {
    const state = row.children
      ? row.expanded
        ? vscode.TreeItemCollapsibleState.Expanded
        : vscode.TreeItemCollapsibleState.Collapsed
      : vscode.TreeItemCollapsibleState.None;
    const item = new vscode.TreeItem(row.label, state);

    if (row.description !== undefined) item.description = row.description;
    if (row.tooltip !== undefined) item.tooltip = new vscode.MarkdownString(row.tooltip);
    if (row.icon !== undefined) item.iconPath = new vscode.ThemeIcon(row.icon);
    if (row.open !== undefined) item.command = opener(row.open);
    return item;
  }
}

// A file that is there opens at its line; one that is not opens as a new file at its path,
// which saving makes.
function opener(open: NonNullable<Row["open"]>): vscode.Command {
  const uri = vscode.Uri.file(open.path);
  if (!open.exists) return { command: "vscode.open", title: "Open", arguments: [uri.with({ scheme: "untitled" })] };

  const at = open.line === undefined ? {} : { selection: new vscode.Range(open.line - 1, 0, open.line - 1, 0) };
  return { command: "vscode.open", title: "Open", arguments: [uri, at] };
}

function run(how: Invocation, cwd: string): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(
      how.file,
      how.args,
      { cwd, timeout: 30_000, maxBuffer: 16 * 1024 * 1024, windowsHide: true, windowsVerbatimArguments: how.verbatim },
      (error, stdout, stderr) => (error ? reject(new Error(String(stderr).trim() || error.message)) : resolve(String(stdout))),
    );
  });
}

// A path as the file system compares it: Troupe writes `C:\…/troupe/config.yaml` and VS
// Code `c:\…\config.yaml` for one file.
function normal(p: string) {
  const fsPath = vscode.Uri.file(p).fsPath;
  return process.platform === "win32" ? fsPath.toLowerCase() : fsPath;
}
