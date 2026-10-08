// Runs inside the VS Code windows run.ts opens on one folder with troupe.openOnFolderOpen
// on, against the same fake `troupe` (Decision 816), as TROUPE_TEST_STARTUP says:
// - `opens`: Troupe opens as the folder opens, at the folder, once.
// - `reload`: a Troupe terminal for the folder is there as the extension starts, and no
//   second Troupe starts. The test runs before the extension starts (onStartupFinished),
//   so the terminal it makes, named for the folder, stands in for the one VS Code keeps
//   across a reload. VS Code ends a test run that reloads its window; a real reload gives
//   the terminal back under its shell's name, known by its process id instead, which the
//   unit tests and the check by hand in Decision 816 cover.
// runTests starts VS Code with --disable-workspace-trust, so a folder that is not trusted
// is left to the unit tests (startup.test.ts).

import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";

const work = process.env["TROUPE_TEST_WORK"] ?? "";
const what = process.env["TROUPE_TEST_STARTUP"] ?? "";
const folder = vscode.workspace.workspaceFolders?.[0];

export async function run(): Promise<void> {
  const extension = vscode.extensions.getExtension("objective-mj.troupe");
  assert.ok(extension, "the extension is loaded");
  assert.ok(folder, "a folder is open");
  const name = `Troupe: ${folder.name}`;
  const before = read().length;

  try {
    if (what === "reload") {
      assert.ok(!extension.isActive, "the extension started before the test could stand in for a reload");
      vscode.window.createTerminal({ name, cwd: folder.uri });
    }

    // The extension starts when the window has, not when a test asks.
    await until(() => extension.isActive, "the extension started with the window");

    if (what === "opens") {
      const call = (await calls(before + 1))[before];
      assert.ok(call);
      samePath(call.cwd, folder.uri.fsPath);
      assert.equal(call.args[0], "--workspace");
      samePath(call.args[1] ?? "", folder.uri.fsPath);
      await until(() => named(name).length === 1, `${name}'s terminal`);
      await wait(3000);
      assert.equal(read().length, before + 1);
      console.log("ok - Troupe opened as the folder opened, at the folder, once");
    } else if (what === "reload") {
      await wait(5000);
      assert.equal(read().length, before);
      assert.equal(named(name).length, 1);
      console.log("ok - with the folder's Troupe terminal there from before a reload, no second Troupe started");
    } else {
      throw new Error(`TROUPE_TEST_STARTUP is ${JSON.stringify(what)}`);
    }
  } finally {
    for (const terminal of vscode.window.terminals) terminal.dispose();
  }
}

function named(name: string) {
  return vscode.window.terminals.filter((t) => t.name === name);
}

// The fake's calls at the folder, as suite.ts reads them.
function read() {
  const log = path.join(work, "bin", "calls.log");
  return (fs.existsSync(log) ? fs.readFileSync(log, "utf8") : "")
    .split(/\r?\n/)
    .filter((line) => line.startsWith("call\t"))
    .map((line) => {
      const [, cwd = "", ...rest] = line.split("\t");
      const args = process.platform === "win32" ? rest.join("\t").trim().split(/\s+/).map((a) => a.replace(/^"(.*)"$/, "$1")) : rest;
      return { cwd: cwd.trim(), args };
    })
    .filter((call) => folder !== undefined && same(call.cwd, folder.uri.fsPath));
}

async function calls(count: number) {
  await until(() => read().length >= count, `${count} call(s) of the fake troupe`, 60_000);
  return read();
}

function same(a: string, b: string) {
  try {
    return norm(a) === norm(b);
  } catch {
    return false;
  }
}

function samePath(actual: string, expected: string) {
  assert.equal(norm(actual), norm(expected));
}

function norm(p: string) {
  const real = fs.realpathSync(p);
  return process.platform === "win32" ? real.toLowerCase() : real;
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
