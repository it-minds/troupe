import assert from "node:assert/strict";
import { test } from "node:test";
import { terminalName } from "../../src/folder.js";
import { atStart, fromBefore } from "../../src/startup.js";

// Issue #378: Troupe opened as the window opens a folder, when the person turns it on, and
// not a second time after a reload (Decision 816).
const window = { enabled: true, trusted: true, folders: 2, open: false };

test("off unless the setting is on", () => {
  assert.deepEqual(atStart({ ...window, enabled: false }), { not: "off" });
  assert.deepEqual(atStart(window), { open: true });
});

test("a window with no folder opens nothing", () => {
  assert.deepEqual(atStart({ ...window, folders: 0 }), { not: "no folder" });
});

test("a workspace that is not trusted opens nothing", () => {
  assert.deepEqual(atStart({ ...window, trusted: false }), { not: "untrusted" });
});

test("a folder's Troupe terminal there from before a reload is Troupe open already", () => {
  assert.deepEqual(atStart({ ...window, open: true }), { not: "open already" });
});

const folders = [
  { key: "file:///w/alpha", name: "alpha" },
  { key: "file:///w/beta", name: "beta" },
];

test("after a reload a folder's terminal is the one whose process was kept for it, whatever its name", () => {
  // What VS Code gives back after a reload: the shell's name, the process kept.
  const terminals = [
    { terminal: "pwsh 1", name: "pwsh", pid: 11 },
    { terminal: "pwsh 2", name: "pwsh", pid: 22 },
  ];
  assert.deepEqual([...fromBefore(folders, { "file:///w/beta": 22 }, terminals)], [["file:///w/beta", "pwsh 2"]]);
  // A process no longer there, as after a restart, is no terminal of the folder's.
  assert.deepEqual(fromBefore(folders, { "file:///w/alpha": 33 }, terminals).size, 0);
});

test("a terminal still named for a folder is that folder's, and no other name is", () => {
  const terminals = [
    { terminal: "ours", name: terminalName("alpha"), pid: undefined },
    { terminal: "theirs", name: "troupe: beta", pid: 5 },
    { terminal: "gone", name: terminalName("gamma"), pid: 6 },
  ];
  assert.deepEqual([...fromBefore(folders, {}, terminals)], [["file:///w/alpha", "ours"]]);
});

test("the terminal's name is the one Troupe: Open gives it", () => {
  assert.equal(terminalName("my project"), "Troupe: my project");
});
