import assert from "node:assert/strict";
import { test } from "node:test";
import { chooseFolder } from "../../src/folder.js";

const alpha = { name: "alpha" };
const beta = { name: "beta" };

test("a folder asked for, a row of the side bar's list, before any editor", () => {
  assert.deepEqual(chooseFolder({ given: beta, editor: alpha, terminal: alpha, folders: [alpha, beta] }), { folder: beta });
});

test("the active editor's folder, in a workspace of one root or several", () => {
  assert.deepEqual(chooseFolder({ editor: beta, folders: [alpha, beta] }), { folder: beta });
  assert.deepEqual(chooseFolder({ editor: alpha, terminal: beta, folders: [alpha, beta] }), { folder: alpha });
  assert.deepEqual(chooseFolder({ editor: alpha, folders: [alpha] }), { folder: alpha });
});

test("with no editor: the Troupe terminal in front, so a second press does not ask again", () => {
  assert.deepEqual(chooseFolder({ terminal: beta, folders: [alpha, beta] }), { folder: beta });
});

test("with nothing to go by: the only folder, or a question, or nothing", () => {
  assert.deepEqual(chooseFolder({ folders: [alpha] }), { folder: alpha });
  assert.deepEqual(chooseFolder({ folders: [alpha, beta] }), { ask: [alpha, beta] });
  assert.deepEqual(chooseFolder({ folders: [] }), { none: true });
  // An editor on a file outside every folder is no editor.
  assert.deepEqual(chooseFolder({ editor: undefined, folders: [alpha, beta] }), { ask: [alpha, beta] });
});
