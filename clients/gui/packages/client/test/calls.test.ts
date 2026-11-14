// A call in a person's words, which the desktop app and the console both say (troupe #899):
// what an approval shows before it is answered, where the call runs, and who answered it.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { ONCE_ONLY_SENTENCE, callConsequence, callEvidence, callHeadline, emptyTranscript, fold, toolTarget } from "../src/index.js";
import type { DurableEvent, Entry } from "../src/index.js";

let seq = 0;
function durable(type: string, data: Record<string, unknown>, subject = "carol@example.com"): DurableEvent {
  seq += 1;
  return { seq, prev_hash: null, ts: new Date().toISOString(), actor: { kind: "user", subject }, agent: ["root"], type, v: 1, data };
}

describe("a call in words", () => {
  it("an approval's evidence is its command and folder, its file, and a diff where it carries one", () => {
    assert.deepEqual(callEvidence({ command: "ls -la", cwd: "/work/billing" }), { command: "ls -la", cwd: "/work/billing", path: null, diff: null });
    assert.deepEqual(callEvidence({ path: "lib/a.ex", diff: "--- a\n+++ b\n" }), { command: null, cwd: null, path: "lib/a.ex", diff: "--- a\n+++ b\n" });
    assert.deepEqual(callEvidence(null), { command: null, cwd: null, path: null, diff: null });
  });

  it("says where a command runs: on the platform, or on the laptop a relayed session is on", () => {
    assert.equal(callHeadline("shell"), "Run a command?");
    assert.match(callConsequence("shell"), /runs on the platform/);
    assert.match(callConsequence("shell", "laptop"), /runs on the laptop the session is on/);
    assert.match(ONCE_ONLY_SENTENCE, /done at the laptop/);
    assert.equal(toolTarget("shell", { command: "ls   -la" }), "ls -la");
  });

  it("an answered approval names who answered it, from the decision's actor", () => {
    seq = 0;
    const asked = fold(emptyTranscript, durable("approval_requested", { call_id: "c1", tool: "shell", args: { command: "ls" } }, "ada@example.com"));
    const decided = fold(asked, durable("approval_decided", { call_id: "c1", tool: "shell", decision: "allow" }));
    const entry = decided.entries.find((e): e is Extract<Entry, { kind: "approval" }> => e.kind === "approval");
    assert.equal(entry?.decision, "allow");
    assert.equal(entry?.decidedBy, "carol@example.com");
  });
});
