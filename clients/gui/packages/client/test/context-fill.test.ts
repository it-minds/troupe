// How full the model's context is (troupe #919, the window from #920): the tokens the root
// agent's last model call sent, and the window once a `context_status` event says it.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { contextStatus, emptyTranscript, fold } from "../src/index.js";
import type { DurableEvent, EphemeralEvent, TranscriptState } from "../src/index.js";

let seq = 0;
function durable(type: string, data: Record<string, unknown>, agent = ["root"]): DurableEvent {
  seq += 1;
  return { seq, prev_hash: null, ts: new Date().toISOString(), actor: { kind: "agent" }, agent, type, v: 1, data };
}

const reply = (input: number, read = 0, write = 0, agent = ["root"]): DurableEvent =>
  durable("llm_response", { message: { role: "assistant", content: [{ type: "text", text: "ok" }] }, usage: { input_tokens: input, cache_read: read, cache_write: write, output_tokens: 9 } }, agent);

describe("the context fill", () => {
  it("is what the root's last call sent, not the session's sum, and a subagent's call leaves it", () => {
    let s: TranscriptState = emptyTranscript;
    assert.equal(s.context, undefined);
    s = fold(s, reply(20_000, 4_000, 100));
    assert.deepEqual(s.context, { used: 24_100, window: undefined });
    s = fold(s, reply(30_000));
    assert.deepEqual(s.context, { used: 30_000, window: undefined });
    s = fold(s, reply(500, 0, 0, ["root", "helper"]));
    assert.deepEqual(s.context, { used: 30_000, window: undefined });
  });

  it("takes the window and the fill from a context_status, durable or not, and keeps the window after", () => {
    let s = fold(emptyTranscript, durable("context_status", { window_tokens: 200_000, used_tokens: 50_000 }));
    assert.deepEqual(s.context, { used: 50_000, window: 200_000 });
    s = fold(s, reply(60_000));
    assert.deepEqual(s.context, { used: 60_000, window: 200_000 });
    const live: EphemeralEvent = { ephemeral: true, type: "context_status", agent: ["root"], data: { window_tokens: 100_000, used_tokens: 1_000 } };
    s = fold(s, live);
    assert.deepEqual(s.context, { used: 1_000, window: 100_000 });
  });

  it("ignores a context_status that is not one", () => {
    assert.equal(contextStatus({ window_tokens: "200k", used_tokens: 1 }), null);
    assert.equal(contextStatus({ window_tokens: 0, used_tokens: 1 }), null);
    assert.equal(contextStatus({ used_tokens: 1 }), null);
    const s = fold(emptyTranscript, durable("context_status", { window_tokens: -1, used_tokens: 5 }));
    assert.equal(s.context, undefined);
  });
});
