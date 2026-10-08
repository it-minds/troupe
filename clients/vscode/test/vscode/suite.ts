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

it("beside the model, the Models group is what troupe models --json says, asked without --refresh", async () => {
  await edit("delta");
  const shown = await vscode.commands.executeCommand<Shown>("troupe.refreshSettings");
  assert.ok("folder" in shown, "a folder is shown");

  assert.deepEqual(shown.rows.slice(0, 2).map((r) => r.label), ["Model", "Models"]);
  const models = shown.rows[1]?.children ?? [];
  assert.deepEqual(
    models.map((r) => [r.label, r.description, r.icon]),
    [
      ["openai's list", "2 models, fetched 3 hours ago", "cloud"],
      ["fake-large", "default, expensive · 200k window · $3.00/$15 · from openai's list", "star-full"],
      // The 200,000 the JSON gives it is Troupe's fallback: no window is shown.
      ["fake-retired", "not served by openai", "warning"],
      ["fake-small", "cheap · 128k window · $0.25/$1.25 · from openai's list", "star-full"],
    ],
  );
  assert.doesNotMatch(JSON.stringify(shown), /sk-t/);

  const asked = modelsCalls();
  assert.ok(asked.length > 0, "troupe models was asked");
  for (const line of asked) {
    assert.match(line, /^models --json --workspace /);
    assert.doesNotMatch(line, /--refresh/);
  }
  samePath(asked.at(-1)?.replace(/^models --json --workspace /, "").replace(/^"(.*)"$/, "$1") ?? "", folder("delta"));
});

it("the Models group's button asks the providers again: --refresh, and only from it", async () => {
  const before = modelsCalls().length;
  const shown = await vscode.commands.executeCommand<Shown>("troupe.refreshModels");
  assert.ok("folder" in shown, "a folder is shown");
  assert.equal(shown.rows[1]?.label, "Models");

  const since = modelsCalls().slice(before);
  assert.equal(since.filter((line) => line.includes("--refresh")).length, 1, since.join("\n"));
});

it("a troupe models that fails is one line in the group, and the settings are still shown", async () => {
  const fail = path.join(work, "bin", "models.fail");
  fs.writeFileSync(fail, "");

  try {
    const shown = await vscode.commands.executeCommand<Shown>("troupe.refreshSettings");
    assert.ok("folder" in shown, "a folder is shown");
    assert.equal(shown.rows[0]?.label, "Model");
    assert.deepEqual(
      shown.rows[1]?.children?.map((r) => [r.label, r.description, r.icon]),
      [["Troupe could not list its models", "troupe: the fake was told not to list its models", "error"]],
    );
  } finally {
    fs.rmSync(fail, { force: true });
  }
});

it("a config that does not load: its errors, each opening its file at its line, and the Models group says why", async () => {
  const explainFail = path.join(work, "bin", "explain.fail");
  const modelsFail = path.join(work, "bin", "models.fail");
  const fails = [explainFail, modelsFail];
  // What `troupe config --explain --json` prints on standard output for such a config, and
  // nothing on standard error (Decision 799).
  const userFile = path.join(work, "bin", "config.yaml");
  const message = 'max_turns must be a whole number, at least 1, not "many"';
  fs.writeFileSync(explainFail, JSON.stringify({ errors: [{ level: "error", source: userFile, line: 5, key: "max_turns", message }] }, null, 2));
  fs.writeFileSync(modelsFail, "");

  try {
    const shown = await vscode.commands.executeCommand<Shown>("troupe.refreshSettings");
    assert.ok("folder" in shown, "a folder is shown");
    assert.deepEqual(
      shown.rows.map((r) => [r.label, r.description, r.icon]),
      [
        ["The configuration did not load", "1 error", "error"],
        ["Models", undefined, "library"],
      ],
    );
    assert.doesNotMatch(JSON.stringify(shown), /Command failed/);

    const [error] = shown.rows[0]?.children ?? [];
    assert.deepEqual([error?.label, error?.description, error?.icon], [message, `${userFile}:5`, "error"]);
    assert.deepEqual(error?.open, { path: userFile, line: 5, exists: true });

    assert.deepEqual(shown.rows[1]?.children?.map((r) => [r.label, r.description]), [
      ["Troupe could not list its models", "troupe: the fake was told not to list its models"],
    ]);
  } finally {
    for (const file of fails) fs.rmSync(file, { force: true });
  }
});

it("a missing troupe is the one sentence in the Settings view", async () => {
  const nowhere = path.join(work, "nowhere", "troupe");

  await setting("path", nowhere, async () => {
    const shown = await vscode.commands.executeCommand<Shown>("troupe.refreshSettings");
    assert.ok("folder" in shown, "a folder is shown");
    assert.deepEqual(shown.rows, [
      { label: `There is no troupe to run at ${nowhere}, which troupe.path names, on this computer.`, icon: "error" },
    ]);
  });
});

// Issue #378: troupe's other command lines, each into the folder's terminal.

it("Troupe: Resume Last Session Here types troupe resume into the folder's terminal", async () => {
  await closeAll();
  mode("stay");
  await edit("beta");
  const before = (await calls(0)).length;

  const opened = await vscode.commands.executeCommand<Opened>("troupe.resume");
  assert.deepEqual(opened, { opened: vscode.Uri.file(folder("beta")).fsPath, terminal: "Troupe: beta", reused: false });

  const call = (await calls(before + 1))[before];
  assert.ok(call);
  samePath(call.cwd, folder("beta"));
  assert.deepEqual([call.args[0], call.args[1]], ["resume", "--workspace"]);
  samePath(call.args[2] ?? "", folder("beta"));
  assert.equal(call.args.length, 3);
});

it("a command into a terminal Troupe runs in shows it, types nothing and says so", async () => {
  const before = (await calls(0)).length;
  const opened = await vscode.commands.executeCommand<Opened>("troupe.doctor");

  assert.ok("busy" in opened, JSON.stringify(opened));
  assert.match(opened.busy, /^Troupe: beta is in use, so nothing was typed into it/);
  await wait(2000);
  assert.equal((await calls(0)).length, before);
  assert.equal(named("Troupe: beta").length, 1);
});

it("Troupe: Run a Task… types troupe run with the task after --, as one argument", async () => {
  await closeAll();
  await edit("gamma");
  const before = (await calls(0)).length;

  // The task as a key's `args` gives it; from the palette it is asked for.
  const opened = await vscode.commands.executeCommand<Opened>("troupe.run", "tidy the README, then stop");
  assert.deepEqual(opened, { opened: vscode.Uri.file(folder("gamma")).fsPath, terminal: "Troupe: gamma", reused: false });

  const call = (await calls(before + 1))[before];
  assert.ok(call);
  samePath(call.cwd, folder("gamma"));
  assert.deepEqual([call.args[0], call.args[1]], ["run", "--workspace"]);
  samePath(call.args[2] ?? "", folder("gamma"));
  assert.deepEqual(call.args.slice(3), ["--", "tidy the README, then stop"]);
});

it("Troupe: Run a Task… asks for the task, and a question dismissed types nothing", async () => {
  await closeAll();
  await edit("gamma");
  const before = (await calls(0)).length;

  const asked = vscode.commands.executeCommand<Opened>("troupe.run");
  await wait(1000);
  await vscode.commands.executeCommand("workbench.action.closeQuickOpen");

  assert.deepEqual(await asked, { cancelled: true });
  await wait(1000);
  assert.equal((await calls(0)).length, before);
  assert.equal(named("Troupe: gamma").length, 0);
});

it("Troupe: Doctor's report stays to be read, and Open Settings is typed into the same terminal", async () => {
  await closeAll();
  mode("exit0");
  await edit("delta");
  const before = (await calls(0)).length;

  assert.deepEqual(await vscode.commands.executeCommand<Opened>("troupe.doctor"), {
    opened: vscode.Uri.file(folder("delta")).fsPath,
    terminal: "Troupe: delta",
    reused: false,
  });
  const doctor = (await calls(before + 1))[before];
  assert.ok(doctor);
  assert.equal(doctor.args[0], "doctor");
  samePath(doctor.args[2] ?? "", folder("delta"));

  // It ended with 0, and the terminal is still there: no `exit` after a report.
  await wait(5000);
  const [terminal] = named("Troupe: delta");
  assert.ok(terminal, "delta's terminal is still there");
  assert.equal(terminal.exitStatus, undefined);

  if (terminal.shellIntegration !== undefined) {
    assert.deepEqual(await vscode.commands.executeCommand<Opened>("troupe.config"), {
      opened: vscode.Uri.file(folder("delta")).fsPath,
      terminal: "Troupe: delta",
      reused: true,
    });
    const config = (await calls(before + 2))[before + 1];
    assert.deepEqual(config?.args.slice(0, 2), ["config", "--workspace"]);
    assert.equal(named("Troupe: delta").length, 1);
  } else {
    console.log("  (no shell integration in this terminal: the second line is not checked)");
  }
});

// Issue #378: "ask about this file" in two clicks.

it("Ask Troupe About This File opens Troupe at its folder with its path in the prompt", async () => {
  await closeAll();
  mode("stay");
  await edit("beta");
  const before = (await calls(0)).length;

  // What the explorer's and an editor's menus hand the command: the file's URI.
  const file = vscode.Uri.file(path.join(folder("alpha"), "src", "b.txt"));
  const opened = await vscode.commands.executeCommand<Opened>("troupe.askAboutFile", file);
  assert.deepEqual(opened, { opened: vscode.Uri.file(folder("alpha")).fsPath, terminal: "Troupe: alpha", reused: false });

  const call = (await calls(before + 1))[before];
  assert.ok(call);
  samePath(call.cwd, folder("alpha"));
  assert.equal(call.args[0], "--workspace");
  samePath(call.args[1] ?? "", folder("alpha"));
  assert.deepEqual(call.args.slice(2), ["--prompt", "@src/b.txt "]);
});

it("Ask Troupe About This Folder puts the folder's path in the prompt", async () => {
  await closeAll();
  const before = (await calls(0)).length;

  await vscode.commands.executeCommand<Opened>("troupe.askAboutFolder", vscode.Uri.file(path.join(folder("alpha"), "src")));
  assert.deepEqual((await calls(before + 1))[before]?.args.slice(2), ["--prompt", "@src/ "]);
});

it("from the palette, Ask Troupe About This File asks about the active editor's file", async () => {
  await closeAll();
  await edit("delta");
  const before = (await calls(0)).length;

  const opened = await vscode.commands.executeCommand<Opened>("troupe.askAboutFile");
  assert.deepEqual(opened, { opened: vscode.Uri.file(folder("delta")).fsPath, terminal: "Troupe: delta", reused: false });
  assert.deepEqual((await calls(before + 1))[before]?.args.slice(2), ["--prompt", "@a.txt "]);

  // With Troupe running there, it says what to type into it, and types nothing. Troupe's
  // tab is the editor in front now, so the file is handed over as the explorer hands it.
  const busy = await vscode.commands.executeCommand<Opened>("troupe.askAboutFile", vscode.Uri.file(path.join(folder("delta"), "a.txt")));
  assert.ok("busy" in busy, JSON.stringify(busy));
  assert.match(busy.busy, /type @a\.txt into Troupe there/);
  await wait(1000);
  assert.equal((await calls(0)).length, before + 1);
});

it("with no file to ask about, it says so and opens nothing", async () => {
  await closeAll();
  const count = vscode.window.terminals.length;
  const asked = await vscode.commands.executeCommand<Opened>("troupe.askAboutFile");
  assert.ok("noFile" in asked, JSON.stringify(asked));
  assert.equal(vscode.window.terminals.length, count);
});

// Issue #378: "Troupe" in the terminal's profile menu (Decision 816).

it("the Troupe profile is a terminal whose program is troupe, at the active editor's folder", async () => {
  await closeAll();
  mode("stay");
  await edit("beta");
  const before = (await calls(0)).length;

  await profile();
  const call = (await calls(before + 1))[before];
  assert.ok(call);
  samePath(call.cwd, folder("beta"));
  assert.equal(call.args[0], "--workspace");
  samePath(call.args[1] ?? "", folder("beta"));
  assert.equal(call.args.length, 2);

  // No shell with a line typed into it: troupe is what the terminal runs, a .cmd through
  // cmd.exe as the Settings view runs it, never the extensionless file beside it.
  await until(() => named("Troupe: beta").length === 1, "beta's terminal from the profile");
  const options = named("Troupe: beta")[0]?.creationOptions as vscode.TerminalOptions;
  if (process.platform === "win32") {
    assert.match(options.shellPath ?? "", /cmd(\.exe)?$/i);
    assert.match(String(options.shellArgs), /^\/d \/s \/c ".*troupe\.cmd --workspace /i);
  } else {
    samePath(options.shellPath ?? "", path.join(work, "bin", "troupe"));
  }
  samePath(options.cwd instanceof vscode.Uri ? options.cwd.fsPath : String(options.cwd), folder("beta"));
});

it("a profile is a new terminal, and Troupe: Open then shows the folder's first", async () => {
  const before = (await calls(0)).length;

  await profile();
  await calls(before + 1);
  await until(() => named("Troupe: beta").length === 2, "a second terminal from the profile");

  assert.deepEqual(await open(), { opened: vscode.Uri.file(folder("beta")).fsPath, terminal: "Troupe: beta", reused: true });
  await wait(2000);
  assert.equal((await calls(0)).length, before + 1);
  assert.equal(named("Troupe: beta").length, 2);
});

it("the profile's terminal closes when troupe exits", async () => {
  await closeAll();
  mode("exit0");
  await edit("gamma");
  const before = (await calls(0)).length;

  await profile();
  samePath((await calls(before + 1))[before]?.cwd ?? "", folder("gamma"));
  await until(() => named("Troupe: gamma").length === 0, "gamma's terminal closed");
});

it("with no troupe, the profile opens no terminal", async () => {
  await closeAll();
  await edit("gamma");
  const before = (await calls(0)).length;

  await setting("path", path.join(work, "nowhere", "troupe"), async () => {
    await profile().catch(() => undefined);
    await wait(2000);
    assert.equal(vscode.window.terminals.length, 0);
    assert.equal((await calls(0)).length, before);
  });
});

async function open() {
  return vscode.commands.executeCommand<Opened>("troupe.open");
}

// What the terminal's profile menu does with "Troupe": a terminal from the extension's
// profile, where the menu is (here the panel's), with no folder of VS Code's own choosing.
async function profile() {
  await vscode.commands.executeCommand("workbench.action.createTerminalEditor", {
    config: { extensionIdentifier: "objective-mj.troupe", id: "troupe.tui", title: "Troupe" },
    location: vscode.TerminalLocation.Panel,
  });
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
        // The Windows fake writes its arguments as cmd.exe got them, in one field, split here
        // at the spaces outside quotes; the POSIX fake writes each in a field of its own.
        const args = process.platform === "win32" ? split(rest.join("\t").trim()) : rest;
        return { cwd: cwd.trim(), args };
      });

  await until(() => read().length >= count, `${count} call(s) of the fake troupe`, 60_000);
  return read();
}

// A command line as a program splits it, for the words these tests type: no backslash
// before a quote.
function split(line: string) {
  const words: string[] = [];
  let word = "";
  let quoted = false;
  let started = false;

  for (const ch of line) {
    if (ch === '"') {
      quoted = !quoted;
      started = true;
    } else if (/\s/.test(ch) && !quoted) {
      if (started) words.push(word);
      word = "";
      started = false;
    } else {
      word += ch;
      started = true;
    }
  }
  if (started) words.push(word);
  return words;
}

// The fake's `troupe models` calls, each its arguments as one line.
function modelsCalls() {
  const file = path.join(work, "bin", "models.log");
  return (fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "").split(/\r?\n/).filter((line) => line.trim() !== "").map((line) => line.trim());
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
