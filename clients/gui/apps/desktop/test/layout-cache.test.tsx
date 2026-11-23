// The transcript's layout is kept per turn (troupe #1182): a turn is laid out again only
// when it changed, or while a call of it runs and the clock moves, so a redraw for one new
// event or for the clock's tick hands the screen the same objects for every other turn,
// and draws exactly what the layout from scratch draws.

import { describe, expect, it } from "vitest";
import { emptyTranscript, foldMany } from "@troupe/client";
import type { DurableEvent, TranscriptState } from "@troupe/client";
import { layout } from "../src/frames";
import type { LayoutCache } from "../src/frames";

let seq = 0;
const ev = (type: string, data: Record<string, unknown>): DurableEvent => ({
  seq: ++seq,
  prev_hash: null,
  ts: new Date(Date.UTC(2026, 10, 23, 10, 0, seq)).toISOString(),
  actor: type === "user_input" ? { kind: "user", subject: "ada" } : { kind: "system" },
  agent: ["root"],
  type,
  v: 1,
  data,
});

function turn(n: number, done = true): DurableEvent[] {
  return [
    ev("user_input", { source: "user", text: `turn ${n}` }),
    ev("tool_call_started", { call_id: `c-${n}`, name: "read_file", args: { path: "a" } }),
    ...(done ? [ev("tool_call_completed", { call_id: `c-${n}`, ok: true, content: "x" }), ev("llm_response", { message: { role: "assistant", content: [{ type: "text", text: `answer ${n}` }] } }), ev("turn_ended", {})] : []),
  ];
}

const opts = (now: number) => ({ detail: "quiet" as const, opened: new Set<string>(), now });

describe("the layout kept per turn", () => {
  it("hands back the same objects for every turn that did not change, and lays out what the whole layout does", () => {
    seq = 0;
    let state: TranscriptState = foldMany(emptyTranscript, [...turn(0), ...turn(1), ...turn(2)]);
    const cache: LayoutCache = new Map();
    const first = layout(state.entries, opts(1_000), cache);
    expect(first).toEqual(layout(state.entries, opts(1_000)));

    // A new turn that is still running: the three before it are the same objects.
    state = foldMany(state, turn(3, false));
    const second = layout(state.entries, opts(2_000), cache);
    expect(second).toEqual(layout(state.entries, opts(2_000)));
    const before = first.length;
    second.slice(0, before).forEach((d, i) => expect(d).toBe(first[i]));

    // The clock moves: only the running turn, whose strip counts, is laid out again.
    const third = layout(state.entries, opts(9_000), cache);
    expect(third).toEqual(layout(state.entries, opts(9_000)));
    third.slice(0, before).forEach((d, i) => expect(d).toBe(second[i]));
    const strip = third.slice(before).find((d) => d.strip)?.strip;
    expect(strip?.ms).toBeGreaterThan(second.slice(before).find((d) => d.strip)!.strip!.ms!);
  });
});
