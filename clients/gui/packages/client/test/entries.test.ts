// A memory document's two versions side by side and who wrote each line (troupe #55): one
// copy for the desktop app and the console both.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { besideRows, renderEntries, writtenBy } from "../src/index.js";

// Each document here was rendered by the plane's `Troupe.Protocol.Memory.Entries.render/1`
// too, and the two agreed: the client sends this as `text` to a plane that reads only text.
describe("renderEntries", () => {
  it("writes General first as its body alone, then each topic as a section, a blank line between", () => {
    assert.equal(renderEntries([{ topic: "General", body: "Plain.\n", heading: false }, { topic: "Tone", body: "\n\nShort.\n\n" }]), "Plain.\n\n## Tone\n\nShort.");
    assert.equal(renderEntries([{ body: "Just text" }]), "Just text");
  });

  it("keeps a topic with an empty body as its heading alone, the topic's outer spaces aside", () => {
    assert.equal(renderEntries([{ topic: " Dates ", body: "" }, { topic: "Tone", body: "Short." }]), "## Dates\n\n## Tone\n\nShort.");
    assert.equal(renderEntries([{ topic: "Tone" }]), "## Tone");
  });

  it("drops a body's blank lines at either end and an entry with nothing in it, and keeps the lines between", () => {
    assert.equal(renderEntries([{ topic: "Empty", body: "", heading: false }, { topic: "Tone", body: "  \n\nA.\n  b  \n \n" }]), "## Tone\n\nA.\n  b  ");
    assert.equal(renderEntries([{ topic: "Tone", body: "A.\n\n\nB." }]), "## Tone\n\nA.\n\n\nB.");
    assert.equal(renderEntries([]), "");
  });
});

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
