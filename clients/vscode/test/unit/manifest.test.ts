import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { test } from "node:test";

// What package.json promises VS Code, against what the code does with it.
const root = path.resolve(__dirname, "../../..");
const manifest = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
const source = fs
  .readdirSync(path.join(root, "src"))
  .filter((f) => f.endsWith(".ts"))
  .map((f) => fs.readFileSync(path.join(root, "src", f), "utf8"))
  .join("\n");

test("every command contributed is registered, and every one registered is contributed", () => {
  const contributed = manifest.contributes.commands.map((c: { command: string }) => c.command).sort();
  const registered = [...source.matchAll(/registerCommand\("([^"]+)"/g)].map((m) => m[1]).sort();
  assert.deepEqual(registered, contributed);

  for (const k of manifest.contributes.keybindings) assert.ok(contributed.includes(k.command), k.command);
  for (const items of Object.values(manifest.contributes.menus) as { command: string }[][])
    for (const m of items) assert.ok(contributed.includes(m.command), m.command);
  for (const m of source.matchAll(/\.command = "([^"]+)"/g)) assert.ok(contributed.includes(m[1]), m[1]);
});

// The activity bar's icon and the terminal tab's are files in media/, which the .vsix keeps.
test("every icon named is a file the package keeps", () => {
  const { viewsContainers, views, commands } = manifest.contributes;
  const named: string[] = [...viewsContainers.activitybar, ...Object.values(views).flat()].map((v: any) => v.icon);
  for (const c of commands) if (typeof c.icon === "object") named.push(c.icon.light, c.icon.dark);
  for (const m of source.matchAll(/media\("([^"]+)"\)/g)) named.push(`media/${m[1]}`);

  assert.ok(named.length >= 5);
  for (const icon of named) {
    assert.match(icon, /^media\//, icon);
    assert.ok(fs.existsSync(path.join(root, icon)), icon);
  }
  assert.match(fs.readFileSync(path.join(root, ".vscodeignore"), "utf8"), /^!media\/\*\*$/m);
});

// On Windows Ctrl+Alt is AltGr: where the layout gives the key a character there (Þ for
// Shift+T on US-International), VS Code types it and the key never reaches the command.
test("no key on Windows is a Ctrl+Alt key", () => {
  for (const k of manifest.contributes.keybindings) {
    const mods = (k.win ?? k.key).toLowerCase().split(/[ +]/);
    assert.ok(!(mods.includes("ctrl") && mods.includes("alt")), `${k.command}: ${k.win ?? k.key}`);
  }
});

// A repository's own .vscode/settings.json is not the person's to trust: it must not name
// the program the terminal runs, nor add `--auto-approve` to it. `machine` scope keeps both
// to the person's user settings and the remote host's.
test("every setting read is contributed, and only a user or remote setting", () => {
  const properties = manifest.contributes.configuration.properties;
  const read = [...source.matchAll(/config\.get<[^>]+>\("([^"]+)"/g)].map((m) => `troupe.${m[1]}`).sort();

  assert.deepEqual(read, Object.keys(properties).sort());
  for (const key of read) assert.equal(properties[key].scope, "machine", key);
});

test("the API the types allow is the API the engine promises", () => {
  const types = fs.readFileSync(path.join(root, "node_modules/@types/vscode/package.json"), "utf8");
  const floor = manifest.engines.vscode.replace(/^\^/, "");
  assert.equal(JSON.parse(types).version.split(".").slice(0, 2).join("."), floor.split(".").slice(0, 2).join("."));
  assert.deepEqual(manifest.extensionKind, ["workspace"]);
  assert.equal(manifest.dependencies, undefined, "the package ships no dependencies: vsce runs with --no-dependencies");
});
