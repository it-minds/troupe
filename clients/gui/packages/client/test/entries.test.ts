// A memory document's two versions side by side and who wrote each line (troupe #55): one
// copy for the desktop app and the console both.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { besideRows, writtenBy } from "../src/index.js";

describe("besideRows", () => {
  it("keeps a line on both sides, and pairs a run gone with the run that came", () => {
    assert.deepEqual(
      besideRows([
        { op: "same", text: "# Ours" },
        { op: "del", text: "- Tabs." },
        { op: "add", text: "- Spaces." },
        { op: "same", text: "- Tests." },
      ]),
      [
        { left: "# Ours", right: "# Ours", changed: false },
        { left: "- Tabs.", right: "- Spaces.", changed: true },
        { left: "- Tests.", right: "- Tests.", changed: false },
      ],
    );
  });

  it("does not pair a line gone with lines that came before it", () => {
    assert.deepEqual(
      besideRows([
        { op: "add", text: "- New." },
        { op: "del", text: "- Old." },
      ]),
      [
        { left: null, right: "- New.", changed: true },
        { left: "- Old.", right: null, changed: true },
      ],
    );
  });
});

describe("writtenBy", () => {
  it("names the version and who saved it, or the agent and its session", () => {
    assert.equal(writtenBy({ text: "- Tabs.", version: 3, by: "ada@example.com", session: "s-1", agent: "build" }), "v3 build in s-1");
    assert.equal(writtenBy({ text: "- Tabs.", version: 2, by: "ada@example.com", session: "s-1" }), "v2 an agent in s-1");
    assert.equal(writtenBy({ text: "- Tabs.", version: 1, by: "ada@example.com" }), "v1 ada@example.com");
  });
});
