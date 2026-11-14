// The status lines and the rule that picks one (docs/design/frames.md §7). The terminal
// client's reader is generated from the same file and held to the same fixture by
// clients/tui/test/troupe/lines_test.exs.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import { LINES, firstLine, lineOrder, pickLine, type LineKind } from "../src/index.js";

const fixture = JSON.parse(readFileSync(new URL("../../../docs/design/lines.order.json", import.meta.url), "utf8")) as {
  seeds: Record<string, Record<string, number[]>>;
};
const kinds = Object.keys(LINES) as LineKind[];

describe("the status lines", () => {
  it("are taken in the order the shared fixture gives, whatever reads them", () => {
    assert.ok(Object.keys(fixture.seeds).length >= 4);
    for (const [seed, byKind] of Object.entries(fixture.seeds)) {
      assert.deepEqual(Object.keys(byKind).sort(), [...kinds].sort());
      for (const kind of kinds) assert.deepEqual(lineOrder(kind, seed), byKind[kind], `${kind} for seed ${JSON.stringify(seed)}`);
    }
  });

  it("give each line once in a turn, and none past the end of the list: the facts alone", () => {
    for (const kind of kinds) {
      const count = LINES[kind].length;
      const taken = Array.from({ length: count }, (_, i) => pickLine(kind, "turn-1", i + 1));
      assert.equal(new Set(taken).size, count);
      assert.equal(pickLine(kind, "turn-1", count + 1), null);
    }
  });

  it("do not open two turns the same way", () => {
    const openings = new Set(Array.from({ length: 20 }, (_, n) => pickLine("thinking", `s/${n}`, 1)));
    assert.ok(openings.size > 5);
  });

  it("keep the register: no exclamation mark, no emoji, a lower-case fragment except the two sentences", () => {
    for (const kind of kinds) {
      for (const line of LINES[kind]) {
        assert.ok(!line.includes("!") && !/\p{Extended_Pictographic}/u.test(line), `${kind}: ${line}`);
        if (kind === "start_screen" || kind === "curtain_up") continue;
        assert.equal(line, line.toLowerCase(), `${kind}: ${line}`);
        assert.ok(!line.endsWith("."), `${kind}: ${line}`);
      }
    }
  });

  it("have the sizes the design asks for, and keep every line the clients had", () => {
    for (const kind of ["thinking", "reading", "acting"] as const) assert.ok(LINES[kind].length >= 20 && LINES[kind].length <= 30, kind);
    for (const kind of ["casting", "starting", "compacting", "long_turn", "loading"] as const) assert.ok(LINES[kind].length >= 10 && LINES[kind].length <= 15, kind);
    for (const kind of ["daemon_starting", "signing_in", "checking_for_an_update", "first_run"] as const) assert.ok(LINES[kind].length >= 5 && LINES[kind].length <= 10, kind);
    const had: Array<[LineKind, string]> = [
      ["starting", "the house lights go down"],
      ["thinking", "the actors are powdering their nose"],
      ["thinking", "the prompter finds the page"],
      ["acting", "shifting the scenery"],
      ["reading", "rereading the second act"],
      ["compacting", "trimming for time"],
      ["casting", "handing out scripts"],
      ["waiting_for_a_place", "waiting in the wings"],
      ["curtain_up", "Lights, cues, action."],
    ];
    for (const [kind, line] of had) assert.ok((LINES[kind] as readonly string[]).includes(line), `${kind}: ${line}`);
  });

  it("firstLine is the first taken", () => {
    assert.equal(firstLine("start_screen", "a"), pickLine("start_screen", "a", 1));
  });
});
