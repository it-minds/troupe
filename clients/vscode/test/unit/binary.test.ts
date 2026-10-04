import assert from "node:assert/strict";
import { test } from "node:test";
import { findTroupe, type Machine } from "../../src/binary.js";

// A file system that holds exactly the runnable files named.
function machine(platform: NodeJS.Platform, env: Machine["env"], runnable: string[]): Machine {
  const files = new Set(runnable);
  return { platform, env, home: platform === "win32" ? "C:\\Users\\me" : "/home/me", files: { runnable: (f) => files.has(f) } };
}

test("Linux: the first troupe on the PATH, skipping relative and empty entries", () => {
  const m = machine("linux", { PATH: ".::bin:/opt/a:/opt/b" }, ["bin/troupe", "/opt/b/troupe", "/opt/c/troupe"]);
  assert.deepEqual(findTroupe("", m), { path: "/opt/b/troupe" });
});

// #231: an extensionless `troupe` on the PATH is not a program on Windows. Windows's own
// lookup would not run it either; a shell-open hands it to an editor.
test("Windows: never an extensionless match, and troupe.exe before troupe.cmd", () => {
  const m = machine(
    "win32",
    { Path: 'C:\\tools;"C:\\Program Files\\troupe";C:\\other' },
    ["C:\\tools\\troupe", "C:\\Program Files\\troupe\\troupe.cmd", "C:\\Program Files\\troupe\\troupe.exe", "C:\\other\\troupe.exe"],
  );
  assert.deepEqual(findTroupe("", m), { path: "C:\\Program Files\\troupe\\troupe.exe" });

  const onlyBare = machine("win32", { PATH: "C:\\tools" }, ["C:\\tools\\troupe", "C:\\tools\\troupe.js"]);
  assert.deepEqual(findTroupe("", onlyBare), { missing: "path" });

  const shim = machine("win32", { PATH: "C:\\tools" }, ["C:\\tools\\troupe", "C:\\tools\\troupe.cmd"]);
  assert.deepEqual(findTroupe("", shim), { path: "C:\\tools\\troupe.cmd" });
});

test("off the PATH: where the installer puts it", () => {
  const win = machine("win32", { PATH: "C:\\Windows", LOCALAPPDATA: "C:\\Users\\me\\AppData\\Local" }, [
    "C:\\Users\\me\\AppData\\Local\\Programs\\troupe\\troupe.exe",
  ]);
  assert.deepEqual(findTroupe("", win), { path: "C:\\Users\\me\\AppData\\Local\\Programs\\troupe\\troupe.exe" });

  const linux = machine("linux", { PATH: "/usr/bin" }, ["/home/me/.local/bin/troupe"]);
  assert.deepEqual(findTroupe("", linux), { path: "/home/me/.local/bin/troupe" });

  assert.deepEqual(findTroupe("", machine("darwin", { PATH: "/usr/bin" }, [])), { missing: "path" });
});

test("troupe.path: a path, a path under ~, or a name looked up on the PATH", () => {
  const linux = machine("linux", { PATH: "/usr/bin" }, ["/opt/troupe/bin/troupe", "/home/me/bin/troupe", "/usr/bin/troupe-dev"]);
  assert.deepEqual(findTroupe("/opt/troupe/bin/troupe", linux), { path: "/opt/troupe/bin/troupe" });
  assert.deepEqual(findTroupe(" ~/bin/troupe ", linux), { path: "/home/me/bin/troupe" });
  assert.deepEqual(findTroupe("troupe-dev", linux), { path: "/usr/bin/troupe-dev" });
  assert.deepEqual(findTroupe("/opt/nothing", linux), { missing: "setting", setting: "/opt/nothing" });
  assert.deepEqual(findTroupe("bin/troupe", linux), { missing: "setting", setting: "bin/troupe" });

  // Without the setting the PATH would have answered: a setting that is wrong says so.
  const both = machine("linux", { PATH: "/usr/bin" }, ["/usr/bin/troupe"]);
  assert.deepEqual(findTroupe("/opt/nothing", both), { missing: "setting", setting: "/opt/nothing" });
});

test("troupe.path on Windows: the extension is added, and a bare file is still not a program", () => {
  const m = machine("win32", { PATH: "" }, ["D:\\troupe\\troupe", "D:\\troupe\\troupe.exe", "D:\\x\\troupe"]);
  assert.deepEqual(findTroupe("D:\\troupe\\troupe", m), { path: "D:\\troupe\\troupe.exe" });
  assert.deepEqual(findTroupe("D:\\troupe\\troupe.exe", m), { path: "D:\\troupe\\troupe.exe" });
  assert.deepEqual(findTroupe("D:\\x\\troupe", m), { missing: "setting", setting: "D:\\x\\troupe" });
});
