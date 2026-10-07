import assert from "node:assert/strict";
import * as path from "node:path";
import { test } from "node:test";
import { mention, typed } from "../../src/lines.js";

// Issue #378: each command's line into the folder's terminal. The ones that open the TUI take
// `troupe.args` and close the terminal on a clean quit; a report keeps it, and takes no
// TUI arguments.
test("what each command types, and which close their terminal", () => {
  const ws = "C:\\dev\\app";
  const extra = ["--no-mouse"];

  assert.deepEqual(typed({ open: true }, ws, extra), { args: ["--workspace", ws, "--no-mouse"], exit: true });
  assert.deepEqual(typed({ resume: true }, ws, extra), { args: ["resume", "--workspace", ws, "--no-mouse"], exit: true });
  assert.deepEqual(typed({ run: "-v is broken" }, ws, extra), {
    args: ["run", "--workspace", ws, "--no-mouse", "--", "-v is broken"],
    exit: true,
  });
  assert.deepEqual(typed({ doctor: true }, ws, extra), { args: ["doctor", "--workspace", ws], exit: false });
  assert.deepEqual(typed({ config: true }, ws, extra), { args: ["config", "--workspace", ws], exit: false });
  assert.deepEqual(typed({ ask: "@src/a.ts " }, ws, extra), {
    args: ["--workspace", ws, "--no-mouse", "--prompt", "@src/a.ts "],
    exit: true,
  });
});

test("the path in the prompt is the folder's, as the TUI's @ completion writes it", () => {
  const win = path.win32;
  assert.equal(mention("C:\\dev\\app", "C:\\dev\\app\\src\\main.ts", false, win), "@src/main.ts ");
  assert.equal(mention("C:\\dev\\app", "C:\\dev\\app\\src", true, win), "@src/ ");
  assert.equal(mention("C:\\dev\\app", "C:\\dev\\app", true, win), "@./ ");
  assert.equal(mention("C:\\dev\\app", "C:\\dev\\app\\docs\\my notes.md", false, win), '@"docs/my notes.md" ');

  const posix = path.posix;
  assert.equal(mention("/home/me/app", "/home/me/app/lib/a.ex", false, posix), "@lib/a.ex ");
  assert.equal(mention("/home/me/app", "/home/me/app/lib", true, posix), "@lib/ ");
  // A quote or a backslash is a name's own on Linux: escaped inside the quotes.
  assert.equal(mention("/w", '/w/say "hi".md', false, posix), '@"say \\"hi\\".md" ');
  assert.equal(mention("/w", "/w/a\\b", false, posix), '@"a\\\\b" ');
});
