// Runs inside the VS Code that run.ts starts, on its workspace of four roots, against the
// fake `troupe` it wrote. Each test presses Troupe: Open as a person would, by the command,
// and reads what happened from the command's answer, the window's terminals and the
// fake's log: where it was started, and with what arguments.

import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import type { Opened } from "../../src/extension.js";

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
  await vscode.commands.executeCommand("workbench.action.closeAllEditors");
  named("Troupe: beta")[0]?.show();
  await until(() => vscode.window.activeTerminal?.name === "Troupe: beta", "beta's terminal in front");

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

async function open() {
  return vscode.commands.executeCommand<Opened>("troupe.open");
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
