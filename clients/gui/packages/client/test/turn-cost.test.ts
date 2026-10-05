// What a turn cost, under it once it ends (issue #389, troupe-remote Decision 769). The
// event that ends a turn carries `turn`; the fold makes one line of it in the terminal
// client's words (its Decision 139), so every client says the same thing, and the call
// that writes a compaction's summary is the session's spend as a reply's is.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { emptyTranscript, fold, turnLine } from "../src/index.js";
import type { DurableEvent, Entry, TranscriptState, TroupeEvent, TurnCost } from "../src/index.js";

let seq = 0;
function durable(type: string, data: Record<string, unknown> = {}, agent = ["root"]): DurableEvent {
  seq += 1;
  return { seq, prev_hash: null, ts: new Date().toISOString(), actor: { kind: "agent" }, agent, type, v: 1, data };
}
const foldAll = (events: TroupeEvent[], from: TranscriptState = emptyTranscript) => events.reduce(fold, from);

// 100 fresh tokens, 1,000 from the cache and one out, three times.
const TURN = { calls: 3, input_tokens: 300, cache_read: 3_000, cache_write: 0, output_tokens: 3, cost_micros: 37_500, unpriced: 0 };

/** A turn of `calls` answers, each priced at 12,500 micros. */
function turn(text: string, calls: number): DurableEvent[] {
  return [
    durable("user_input", { source: "user", text }),
    ...Array.from({ length: calls }, (_, i) =>
      durable("llm_response", {
        message: { role: "assistant", content: [{ type: "text", text: `step ${i + 1}` }] },
        usage: { input_tokens: 100, cache_read: 1_000, cache_write: 0, output_tokens: 1 },
        gateway: { cost_micros: 12_500 },
      }),
    ),
  ];
}

const lines = (state: TranscriptState): string[] => state.entries.flatMap((e) => (e.kind === "turn" ? [e.text] : []));
const last = (state: TranscriptState): Entry | undefined => state.entries.at(-1);

describe("what a turn cost (issue #389)", () => {
  it("is one line under a turn that ends, in the terminal client's words", () => {
    seq = 0;
    const state = foldAll([...turn("go", 3), durable("turn_ended", { turn: TURN })]);
    assert.equal(last(state)?.kind, "turn");
    assert.deepEqual(lines(state), ["turn: 3 calls · ↑ 300 sent · 3.0k cached · ↓ 3 received · $0.04"]);
  });

  it("is each turn's own, one line a turn, and nothing while a turn runs", () => {
    seq = 0;
    const running = foldAll(turn("go", 3));
    assert.deepEqual(lines(running), []);

    const second = { ...TURN, calls: 1, input_tokens: 100, cache_read: 1_000, output_tokens: 1, cost_micros: 12_500 };
    const state = foldAll([durable("turn_ended", { turn: TURN }), ...turn("again", 1), durable("turn_ended", { turn: second })], running);
    assert.deepEqual(lines(state), [
      "turn: 3 calls · ↑ 300 sent · 3.0k cached · ↓ 3 received · $0.04",
      "turn: 1 call · ↑ 100 sent · 1.0k cached · ↓ 1 received · $0.01",
    ]);
  });

  it("ends a cancelled turn and a finished agent too, under the note that says so", () => {
    seq = 0;
    const cancelled = foldAll([...turn("go", 1), durable("cancelled", { turn: { ...TURN, calls: 1 } })]);
    assert.deepEqual(
      cancelled.entries.slice(-2).map((e) => (e.kind === "system" || e.kind === "turn" ? e.text : e.kind)),
      ["turn cancelled", "turn: 1 call · ↑ 300 sent · 3.0k cached · ↓ 3 received · $0.04"],
    );

    const done = foldAll([...turn("go", 2), durable("agent_done", { reason: "finished", summary: "ok", turn: { ...TURN, calls: 2 } })]);
    assert.deepEqual(
      done.entries.slice(-2).map((e) => (e.kind === "system" || e.kind === "turn" ? e.text : e.kind)),
      ["done: finished", "turn: 2 calls · ↑ 300 sent · 3.0k cached · ↓ 3 received · $0.04"],
    );
    assert.equal(done.doneReason, "finished");
  });

  it("says a turn nobody priced has no price, rather than that it was free, and how many calls were not priced", () => {
    seq = 0;
    const none = foldAll([durable("turn_ended", { turn: { ...TURN, calls: 2, cost_micros: 0, unpriced: 2 } })]);
    assert.match(lines(none)[0]!, /^turn: 2 calls · .* · no price$/);

    const one = foldAll([durable("turn_ended", { turn: { ...TURN, cost_micros: 5_000, unpriced: 1 } })]);
    assert.match(lines(one)[0]!, / · under a cent, 1 call unpriced$/);

    const two = foldAll([durable("turn_ended", { turn: { ...TURN, cost_micros: 1_234_567, unpriced: 2 } })]);
    assert.match(lines(two)[0]!, / · \$1\.23, 2 calls unpriced$/);

    const free = foldAll([durable("turn_ended", { turn: { ...TURN, cost_micros: 0 } })]);
    assert.match(lines(free)[0]!, / · \$0\.00$/);
  });

  it("says nothing for a turn that made no call, one a log from before turns were counted ended, or one the root failed", () => {
    seq = 0;
    const state = foldAll([
      durable("turn_ended", { turn: { ...TURN, calls: 0 } }),
      durable("turn_ended", {}),
      durable("cancelled", {}),
      durable("turn_ended", { reason: "agent_failed", detail: "raised" }),
    ]);
    assert.deepEqual(lines(state), []);
    assert.equal(last(state)?.kind, "system");
  });

  it("keeps a subagent's line its own, under its path", () => {
    seq = 0;
    const state = foldAll([durable("agent_done", { reason: "finished", turn: { ...TURN, calls: 2 } }, ["root", "explore-1"])]);
    const line = last(state);
    assert.equal(line?.kind, "turn");
    assert.deepEqual(line?.agent, ["root", "explore-1"]);
    assert.equal(state.doneReason, undefined);
  });

  it("counts the call that wrote a compaction's summary in the session's spend, as a reply's", () => {
    seq = 0;
    const compacted = durable("compacted", {
      summary: "the gist",
      reason: "threshold",
      model: "cheap",
      usage: { input_tokens: 900, cache_read: 0, cache_write: 0, output_tokens: 40 },
      gateway: { cost_micros: 2_000 },
    });
    const state = foldAll([...turn("go", 2), compacted, durable("turn_ended", { turn: { ...TURN, calls: 3 } })]);
    assert.equal(state.costMicros, 27_000);
    assert.deepEqual(state.usage, { input_tokens: 1_100, cache_read: 2_000, cache_write: 0, output_tokens: 42 });
    assert.match(lines(state)[0]!, /^turn: 3 calls · /);

    // A compaction from before it said what its call used adds nothing, and is still a note.
    seq = 0;
    const old = foldAll([...turn("go", 1), durable("compacted", { summary: "the gist" })]);
    assert.equal(old.costMicros, 12_500);
    assert.deepEqual(old.usage, { input_tokens: 100, cache_read: 1_000, cache_write: 0, output_tokens: 1 });
    assert.equal((last(old) as Extract<Entry, { kind: "system" }>).text, "conversation compacted");
  });
});

describe("the turn line's figures", () => {
  const line = (t: Partial<TurnCost>): string => turnLine({ ...TURN, ...t });

  it("are tokens in thousands and millions to one decimal, rounded half up, as the terminal client works them out", () => {
    assert.match(line({ input_tokens: 999, cache_read: 1_000, output_tokens: 1_150 }), /↑ 999 sent · 1\.0k cached · ↓ 1\.2k received/);
    // A turn of millions, which the issue was about: never `1.0e3k`.
    assert.match(line({ input_tokens: 6_000_000, cache_read: 999_999, output_tokens: 48_249 }), /↑ 6\.0M sent · 1000\.0k cached · ↓ 48\.2k received/);
    // Written to the cache is sent and billed in full.
    assert.match(line({ input_tokens: 1_000, cache_write: 250 }), /↑ 1\.3k sent/);
  });

  it("is money to the cent, rounded half up", () => {
    assert.match(line({ cost_micros: 45_000 }), / · \$0\.05$/);
    assert.match(line({ cost_micros: 1_045_000 }), / · \$1\.05$/);
    assert.match(line({ cost_micros: 1_044_999 }), / · \$1\.04$/);
    assert.match(line({ cost_micros: 9_999 }), / · under a cent$/);
    assert.match(line({ cost_micros: 410_000 }), / · \$0\.41$/);
  });
});
