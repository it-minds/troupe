import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import { invocation } from "../../src/run.js";

test("a program is run as it is, its arguments a list", () => {
  assert.deepEqual(invocation("/usr/bin/troupe", ["config", "--workspace", "/a b"], "linux"), {
    file: "/usr/bin/troupe",
    args: ["config", "--workspace", "/a b"],
    verbatim: false,
  });
  assert.equal(invocation("C:\\t\\troupe.exe", [], "win32").verbatim, false);
});

test("a .cmd on Windows goes through cmd.exe, the line quoted for it", () => {
  const run = invocation("C:\\t s\\troupe.cmd", ["--workspace", "C:\\it's & so"], "win32", "C:\\Windows\\system32\\cmd.exe");
  assert.equal(run.file, "C:\\Windows\\system32\\cmd.exe");
  assert.deepEqual(run.args, ["/d", "/s", "/c", '""C:\\t s\\troupe.cmd" --workspace "C:\\it\'s & so""']);
  assert.equal(run.verbatim, true);
});

test("cmd.exe hands a .cmd the arguments it was meant to have", { skip: process.platform !== "win32" }, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "troupe run "));
  const script = path.join(dir, "echo args.cmd");
  // `%*` as the script got it, quotes and all: an unquoted `%~3` would let the `&` split
  // this script's own echo.
  fs.writeFileSync(script, "@echo off\r\necho(%*\r\n");
  const folder = "C:\\it's $odd & `tick` (x)";

  const run = invocation(script, ["config", "--workspace", folder], "win32", process.env["ComSpec"]);
  const out = spawnSync(run.file, run.args, { windowsVerbatimArguments: run.verbatim, encoding: "utf8" }).stdout;
  assert.equal(out.trim(), `config --workspace "${folder}"`);
  fs.rmSync(dir, { recursive: true, force: true });
});
