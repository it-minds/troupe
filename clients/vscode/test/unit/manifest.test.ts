import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { test } from "node:test";

// What package.json promises VS Code, against what the code does with it.
const root = path.resolve(__dirname, "../../..");
const manifest = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
const source = fs.readFileSync(path.join(root, "src/extension.ts"), "utf8");

test("every command contributed is registered, and every one registered is contributed", () => {
  const contributed = manifest.contributes.commands.map((c: { command: string }) => c.command).sort();
  const registered = [...source.matchAll(/registerCommand\("([^"]+)"/g)].map((m) => m[1]).sort();
  assert.deepEqual(registered, contributed);

  for (const k of manifest.contributes.keybindings) assert.ok(contributed.includes(k.command), k.command);
  for (const m of source.matchAll(/\.command = "([^"]+)"/g)) assert.ok(contributed.includes(m[1]), m[1]);
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
