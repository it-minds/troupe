// Runs inside the VS Code that run.ts starts, on its workspace of four roots, against the
// fake `troupe` it wrote. Each test presses Troupe: Open as a person would, by the command,
// and reads what happened from the command's answer, the window's terminals and the
// fake's log: where it was started, and with what arguments.

import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import type { Opened } from "../../src/extension.js";
import type { Shown } from "../../src/settingsView.js";

const work = process.env["TROUPE_TEST_WORK"] ?? "";
const log = path.join(work, "bin", "calls.log");
const folder = (name: string) => path.join(work, name);

const tests: [string, () => Promise<void>][] = [];
const it = (name: string, fn: () => Promise<void>) => tests.push([name, fn]);

export async function run(): Promise<void> {
  const failed: string[] = [];

  for (const [name, fn] of tests) {
    try {
      await fn();
      console.log(`ok - ${name}`);
    } catch (error) {
      failed.push(name);
      console.error(`not ok - ${name}\n${error instanceof Error ? error.stack : String(error)}`);
    }
  }

  for (const terminal of vscode.window.terminals) terminal.dispose();
  if (failed.length > 0) throw new Error(`${failed.length} of ${tests.length} failed: ${failed.join("; ")}`);
}

it("Troupe: Open is a command, and the extension starts with the window", async () => {
  const extension = vscode.extensions.getExtension("objective-mj.troupe");
  assert.ok(extension, "the extension is loaded");
  await extension.activate();
  assert.ok((await vscode.commands.getCommands(true)).includes("troupe.open"));
});

it("opens the TUI at the active editor's folder, with --workspace, in a terminal named for it", async () => {
  mode("stay");
  await edit("beta");

  const opened = await open();
  assert.deepEqual(opened, { opened: vscode.Uri.file(folder("beta")).fsPath, terminal: "Troupe: beta", reused: false });

  const [call] = await calls(1);
  assert.ok(call);
  samePath(call.cwd, folder("beta"));
  assert.equal(call.args[0], "--workspace");
  samePath(call.args[1] ?? "", folder("beta"));
  assert.equal(call.args.length, 2);

  // By default a tab in the editor area, in the group of the file it was opened from.
  const tab = terminalTab("Troupe: beta");
  assert.ok(tab, "beta's terminal is a tab in the editor area");
  assert.equal(tab.group.viewColumn, vscode.ViewColumn.One);
});

it("a second press shows that terminal again and starts nothing", async () => {
  const opened = await open();
  assert.deepEqual(opened, { opened: vscode.Uri.file(folder("beta")).fsPath, terminal: "Troupe: beta", reused: true });
  assert.equal(named("Troupe: beta").length, 1);
  await wait(2000);
  assert.equal((await calls(1)).length, 1);
});

it("in a workspace of several roots, the other root's editor opens the other root", async () => {
  await edit("alpha");
  assert.deepEqual(await open(), { opened: vscode.Uri.file(folder("alpha")).fsPath, terminal: "Troupe: alpha", reused: false });

  const all = await calls(2);
  samePath(all[1]?.cwd ?? "", folder("alpha"));
  assert.equal(named("Troupe: alpha").length, 1);
  assert.equal(named("Troupe: beta").length, 1);
});

it("with no editor open, the Troupe terminal in front is the folder, and nothing is asked", async () => {
  // The files' tabs, not the terminals': closing a TUI's tab would ask to end it.
  await closeFiles();
  named("Troupe: beta")[0]?.show();
  await until(() => vscode.window.activeTerminal?.name === "Troupe: beta", "beta's terminal in front");
  assert.equal(vscode.window.activeTextEditor, undefined);

  assert.deepEqual(await open(), { opened: vscode.Uri.file(folder("beta")).fsPath, terminal: "Troupe: beta", reused: true });
  assert.equal((await calls(2)).length, 2);
});

it("quitting the TUI closes its terminal", async () => {
  mode("exit0");
  await edit("gamma");
  assert.deepEqual(await open(), { opened: vscode.Uri.file(folder("gamma")).fsPath, terminal: "Troupe: gamma", reused: false });

  samePath((await calls(3))[2]?.cwd ?? "", folder("gamma"));
  await until(() => named("Troupe: gamma").length === 0, "gamma's terminal closed");
});

it("a failed start leaves the terminal open, with the reason in it", async () => {
  mode("exit1");
  await edit("delta");
  await open();

  samePath((await calls(4))[3]?.cwd ?? "", folder("delta"));
  await wait(5000);
  const [terminal] = named("Troupe: delta");
  assert.ok(terminal, "delta's terminal is still there");
  assert.equal(terminal.exitStatus, undefined);

  // Where the shell reports what it runs, the next press starts the TUI again in it.
  if (terminal.shellIntegration !== undefined) {
    mode("stay");
    assert.deepEqual(await open(), { opened: vscode.Uri.file(folder("delta")).fsPath, terminal: "Troupe: delta", reused: true });
    samePath((await calls(5))[4]?.cwd ?? "", folder("delta"));
    assert.equal(named("Troupe: delta").length, 1);
  } else {
    console.log("  (no shell integration in this terminal: the second start is not checked)");
  }
});

it("a missing troupe is one sentence and a link, and no terminal", async () => {
  const config = vscode.workspace.getConfiguration("troupe");
  const before = config.get<string>("path");
  const nowhere = path.join(work, "nowhere", "troupe");
  await config.update("path", nowhere, vscode.ConfigurationTarget.Global);

  try {
    await edit("gamma");
    const count = vscode.window.terminals.length;
    assert.deepEqual(await open(), {
      missing: `There is no troupe to run at ${nowhere}, which troupe.path names, on this computer.`,
    });
    await wait(1000);
    assert.equal(vscode.window.terminals.length, count);
  } finally {
    await config.update("path", before, vscode.ConfigurationTarget.Global);
  }
});

it("troupe.openIn: beside opens it in an editor group beside the file's", async () => {
  await closeAll();
  mode("stay");
  await edit("gamma");
  const before = (await calls(0)).length;

  await setting("openIn", "beside", async () => {
    assert.deepEqual(await open(), { opened: vscode.Uri.file(folder("gamma")).fsPath, terminal: "Troupe: gamma", reused: false });
    samePath((await calls(before + 1))[before]?.cwd ?? "", folder("gamma"));
    const tab = terminalTab("Troupe: gamma");
    assert.ok(tab, "gamma's terminal is a tab in the editor area");
    assert.equal(tab.group.viewColumn, vscode.ViewColumn.Two);
  });
});

it("troupe.openIn: panel opens it in the terminal panel, not the editor area", async () => {
  await closeAll();
  await edit("alpha");
  const before = (await calls(0)).length;

  await setting("openIn", "panel", async () => {
    assert.deepEqual(await open(), { opened: vscode.Uri.file(folder("alpha")).fsPath, terminal: "Troupe: alpha", reused: false });
    await calls(before + 1);
    assert.equal(named("Troupe: alpha").length, 1);
    assert.equal(terminalTab("Troupe: alpha"), undefined);
  });
});

it("a folder given to the command, as a row of the side bar's list gives it, opens there", async () => {
  await closeAll();
  await edit("alpha");
  const before = (await calls(0)).length;

  const opened = await vscode.commands.executeCommand<Opened>("troupe.open", vscode.Uri.file(folder("delta")));
  assert.deepEqual(opened, { opened: vscode.Uri.file(folder("delta")).fsPath, terminal: "Troupe: delta", reused: false });
  samePath((await calls(before + 1))[before]?.cwd ?? "", folder("delta"));
});

it("the activity bar's Troupe opens Troupe at the editor's folder as its side bar shows", async () => {
  await closeAll();
  await vscode.commands.executeCommand("workbench.view.explorer");
  await edit("beta");
  const before = (await calls(0)).length;

  await vscode.commands.executeCommand("workbench.view.extension.troupe");
  samePath((await calls(before + 1))[before]?.cwd ?? "", folder("beta"));
  await until(() => terminalTab("Troupe: beta") !== undefined, "beta's terminal tab");

  // Shown again from the explorer, it shows that terminal, and starts nothing.
  await vscode.commands.executeCommand("workbench.view.explorer");
  await vscode.commands.executeCommand("workbench.view.extension.troupe");
  await wait(2000);
  assert.equal((await calls(0)).length, before + 1);
  assert.equal(named("Troupe: beta").length, 1);
});

it("an editor's title bar opens Troupe at that file's folder, whichever editor is in front", async () => {
  await closeAll();
  await edit("alpha");
  const before = (await calls(0)).length;

  // What VS Code hands a command in editor/title: the URI of that group's file.
  const opened = await vscode.commands.executeCommand<Opened>("troupe.open", vscode.Uri.file(path.join(folder("gamma"), "a.txt")));
  assert.deepEqual(opened, { opened: vscode.Uri.file(folder("gamma")).fsPath, terminal: "Troupe: gamma", reused: false });
  samePath((await calls(before + 1))[before]?.cwd ?? "", folder("gamma"));
});

it("the side bar's Settings is what troupe config --explain says of the folder worked in", async () => {
  await closeAll();
  await edit("delta");
  const before = (await calls(0)).length;

  const shown = await vscode.commands.executeCommand<Shown>("troupe.refreshSettings");
  assert.ok("folder" in shown, "a folder is shown");
  samePath(shown.folder, folder("delta"));

  const model = shown.rows.find((r) => r.label === "Model")?.children ?? [];
  assert.deepEqual(
    model.map((r) => [r.label, r.description]),
    [
      ["Provider", "fake · user"],
      ["Key", "set · user"],
      ["Default model", "fake-large · user"],
    ],
  );
  assert.doesNotMatch(JSON.stringify(shown), /sk-t/);

  const [warning] = shown.rows.find((r) => r.label === "Problems")?.children ?? [];
  assert.equal(warning?.open?.line, 5);

  // Asking is not opening: the fake's log has no call for it.
  assert.equal((await calls(0)).length, before);
});

async function open() {
  return vscode.commands.executeCommand<Opened>("troupe.open");
}

function terminalTab(name: string) {
  return vscode.window.tabGroups.all
    .flatMap((group) => group.tabs)
    .find((tab) => tab.input instanceof vscode.TabInputTerminal && tab.label === name);
}

async function closeFiles() {
  const files = vscode.window.tabGroups.all.flatMap((group) => group.tabs).filter((tab) => tab.input instanceof vscode.TabInputText);
  await vscode.window.tabGroups.close(files);
}

// Every terminal ended, as the extension sees it end, and every file closed.
async function closeAll() {
  for (const terminal of vscode.window.terminals) terminal.dispose();
  await until(() => vscode.window.terminals.length === 0, "the terminals closed");
  await closeFiles();
  await vscode.commands.executeCommand("workbench.action.closeAllGroups");
}

async function setting(name: string, value: unknown, fn: () => Promise<void>) {
  const config = vscode.workspace.getConfiguration("troupe");
  const before = config.inspect(name)?.globalValue;
  await config.update(name, value, vscode.ConfigurationTarget.Global);
  try {
    await fn();
  } finally {
    await config.update(name, before, vscode.ConfigurationTarget.Global);
  }
}

async function edit(name: string) {
  const document = await vscode.workspace.openTextDocument(path.join(folder(name), "a.txt"));
  await vscode.window.showTextDocument(document);
}

function mode(value: "stay" | "exit0" | "exit1") {
  fs.writeFileSync(path.join(work, "bin", "mode"), value);
}

function named(name: string) {
  return vscode.window.terminals.filter((t) => t.name === name);
}

// The fake's calls, once there are at least `count`: a shell can take a while to start.
async function calls(count: number) {
  const read = () =>
    (fs.existsSync(log) ? fs.readFileSync(log, "utf8") : "")
      .split(/\r?\n/)
      .filter((line) => line.startsWith("call\t"))
      .map((line) => {
        const [, cwd = "", ...rest] = line.split("\t");
        // The Windows fake writes its arguments as cmd.exe got them, in one field.
        const args = rest.join(" ").split(/\s+/).filter((a) => a !== "").map((a) => a.replace(/^"(.*)"$/, "$1"));
        return { cwd: cwd.trim(), args };
      });

  await until(() => read().length >= count, `${count} call(s) of the fake troupe`, 60_000);
  return read();
}

function samePath(actual: string, expected: string) {
  const norm = (p: string) => {
    const real = fs.realpathSync(p);
    return process.platform === "win32" ? real.toLowerCase() : real;
  };
  assert.equal(norm(actual), norm(expected));
}

async function until(check: () => boolean, what: string, timeout = 30_000) {
  const deadline = Date.now() + timeout;
  while (!check()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await wait(200);
  }
}

function wait(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
