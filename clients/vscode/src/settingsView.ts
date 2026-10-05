// The side bar's Settings view: the rows settings.ts makes of what `troupe config --explain
// --json` prints for the folder being worked in, and models.ts's group of what `troupe
// models --json` prints for it. It asks again when that folder changes, when a file the
// answer was read from is saved, and on Refresh; never while hidden. Only the Models
// group's own button adds `--refresh`, which asks every provider what it serves.

import { execFile } from "node:child_process";
import * as vscode from "vscode";
import type { Found } from "./binary.js";
import { modelsFailed, modelsGroup, modelsPending, parseModels } from "./models.js";
import { invocation, type Invocation } from "./run.js";
import { failure, parseExplain, rows, type Row } from "./settings.js";

/** What `troupe.refreshSettings` shows. `executeCommand` returns it, which is what the tests read. */
export type Shown = { folder: string; rows: Row[] } | { noFolder: true };

// `troupe models` may ask each provider first (30 seconds each at most), the settings only
// read files.
const SETTINGS_TIMEOUT = 30_000;
const MODELS_TIMEOUT = 120_000;

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

  /** The Models group's button: the same, with every provider asked again. */
  refreshModels(): Promise<Shown> {
    return this.show(this.current(), true);
  }

  private async show(folder: vscode.WorkspaceFolder | undefined, refresh = false): Promise<Shown> {
    const asked = ++this.asked;
    this.folder = folder;

    if (folder === undefined) {
      this.view.description = "";
      this.set([]);
      return { noFolder: true };
    }

    this.view.description = folder.name;
    this.set([{ label: "Asking Troupe…", icon: "loading~spin" }]);

    const answer = await this.ask(folder, refresh, (rows) => asked === this.asked && this.set(rows));
    if (asked === this.asked) this.set(answer);
    return { folder: folder.uri.fsPath, rows: answer };
  }

  // The settings first, shown while the models are asked for: those can wait on a provider.
  // When the settings could not be read, the models are asked all the same: a config that
  // does not load is what `troupe models` says it is on its standard error.
  private async ask(folder: vscode.WorkspaceFolder, refresh: boolean, meanwhile: (rows: Row[]) => void): Promise<Row[]> {
    const found = this.locate();
    if ("missing" in found) return [{ label: this.missing(found), icon: "error" }];

    const where = folder.uri.fsPath;
    const troupe = (args: string[], timeout: number) =>
      run(invocation(found.path, args, process.platform, process.env["ComSpec"]), where, timeout);

    let settings: (models: Row) => Row[];
    try {
      const explain = parseExplain(await troupe(["config", "--explain", "--json", "--workspace", where], SETTINGS_TIMEOUT));
      this.files = new Set(explain.files.map((f) => normal(f.path)));
      settings = (models) => rows(explain, models);
    } catch (error) {
      const failed = failure("Troupe could not say what its settings are", message(error));
      settings = (models) => [failed, models];
    }
    meanwhile(settings(modelsPending()));

    const args = ["models", "--json", "--workspace", where, ...(refresh ? ["--refresh"] : [])];
    try {
      return settings(modelsGroup(parseModels(await troupe(args, MODELS_TIMEOUT)), new Date()));
    } catch (error) {
      const hint = "`troupe models --json` is in Troupe 0.8.3 and later; an older `troupe` does not know it.";
      return settings(modelsFailed(failure("Troupe could not list its models", message(error), hint)));
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
    if (row.context !== undefined) item.contextValue = row.context;
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

function run(how: Invocation, cwd: string, timeout: number): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(
      how.file,
      how.args,
      { cwd, timeout, maxBuffer: 16 * 1024 * 1024, windowsHide: true, windowsVerbatimArguments: how.verbatim },
      (error, stdout, stderr) => {
        if (error === null) return resolve(String(stdout));
        if (error.killed) return reject(new Error(`troupe did not answer within ${timeout / 1000} seconds`));
        reject(new Error(String(stderr).trim() || error.message));
      },
    );
  });
}

function message(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

// A path as the file system compares it: Troupe writes `C:\…/troupe/config.yaml` and VS
// Code `c:\…\config.yaml` for one file.
function normal(p: string) {
  const fsPath = vscode.Uri.file(p).fsPath;
  return process.platform === "win32" ? fsPath.toLowerCase() : fsPath;
}
