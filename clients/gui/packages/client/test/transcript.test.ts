// The fold, on its own. No sockets: a transcript is a function of the events, and the
// properties worth pinning down are the ones that make two clients agree — replaying
// the same log twice produces the same list, and an ephemeral changes nothing durable.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { addPending, dropPending, emptyTranscript, fold, isBusy, openApprovals, rootState } from "../src/index.js";
import type { DurableEvent, Entry, TranscriptState, TroupeEvent } from "../src/index.js";

let seq = 0;
function durable(type: string, data: Record<string, unknown> = {}, agent = ["root"], subject = "alice"): DurableEvent {
  seq += 1;
  return { seq, prev_hash: null, ts: new Date().toISOString(), actor: { kind: "user", subject }, agent, type, v: 1, data };
}
function ephemeral(type: string, data: Record<string, unknown>, agent = ["root"]): TroupeEvent {
  return { ephemeral: true, type, agent, data };
}
const foldAll = (events: TroupeEvent[], from: TranscriptState = emptyTranscript) => events.reduce(fold, from);

describe("the transcript fold", () => {
  it("turns a turn into user, tool and assistant entries in order", () => {
    seq = 0;
    const state = foldAll([
      durable("session_created", { profile: "dev", bundle_version: "3" }),
      durable("input_accepted", { command_id: "c-1", author: "alice" }),
      durable("user_input", { source: "user", text: "hello" }),
      durable("tool_call_started", { call_id: "x", name: "read", args: { path: "a.ex" } }),
      durable("tool_call_completed", { call_id: "x", name: "read", ok: true, content: "defmodule A" }),
      durable("llm_response", {
        message: { role: "assistant", content: [{ type: "text", text: "here it is" }] },
        stop_reason: "end_turn",
        model: "fake",
        gateway: { cost_micros: 250 },
      }),
    ]);

    assert.deepEqual(
      state.entries.map((e) => e.kind),
      ["system", "user", "tool", "assistant"],
    );
    const tool = state.entries[2] as Extract<Entry, { kind: "tool" }>;
    assert.equal(tool.ok, true);
    assert.equal(tool.content, "defmodule A");
    assert.equal(state.profile, "dev");
    assert.equal(state.costMicros, 250);
  });

  it("is the same list whether or not the ephemerals arrived", () => {
    seq = 0;
    const durables = [
      durable("user_input", { source: "user", text: "hi" }),
      durable("llm_response", { message: { content: [{ type: "text", text: "hello" }] }, stop_reason: "end_turn" }),
    ];
    const withDeltas = [
      durables[0]!,
      ephemeral("llm_delta", { kind: "text", text: "hel" }),
      ephemeral("llm_delta", { kind: "text", text: "lo" }),
      ephemeral("agent_state", { state: "thinking" }),
      durables[1]!,
      ephemeral("agent_state", { state: "idle" }),
    ];

    // Deltas paint the answer while it is being produced and are cleared by the
    // response that supersedes them, so a client that lost every one of them has the
    // same transcript as one that saw them all.
    assert.deepEqual(foldAll(durables).entries, foldAll(withDeltas).entries);
    assert.equal(foldAll(withDeltas).streaming, "");
    assert.equal(rootState(foldAll(withDeltas)), "idle");
    assert.equal(isBusy(foldAll([durables[0]!, ephemeral("agent_state", { state: "acting" })])), true);
  });

  it("does not paint a subagent's stream into the root's answer", () => {
    seq = 0;
    const state = foldAll([ephemeral("llm_delta", { kind: "text", text: "inner" }, ["root", "explore"])]);
    assert.equal(state.streaming, "");
  });

  it("reconciles an optimistic send exactly when the server names its command id", () => {
    seq = 0;
    let state = addPending(emptyTranscript, "c-a", "mine");
    state = addPending(state, "c-b", "also mine");
    assert.equal(state.pending.length, 2);

    // Somebody else's input does not clear ours.
    state = fold(state, durable("input_accepted", { command_id: "c-other", author: "bob" }, ["root"], "bob"));
    assert.equal(state.pending.length, 2);

    // Queued mid-turn: still ours, now known to be held.
    state = fold(state, durable("input_queued", { command_id: "c-b", author: "alice", text: "also mine" }));
    assert.equal(state.pending.find((p) => p.commandId === "c-b")?.queued, true);

    state = fold(state, durable("input_accepted", { command_id: "c-a", author: "alice" }));
    assert.deepEqual(
      state.pending.map((p) => p.commandId),
      ["c-b"],
    );
    assert.deepEqual(dropPending(state, "c-b").pending, []);
  });

  it("lets the first approval decision stand and names who resolved a later one", () => {
    seq = 0;
    let state = foldAll([durable("approval_requested", { call_id: "k", tool: "shell", args: { command: "rm" } })]);
    assert.equal(openApprovals(state).length, 1);

    state = fold(state, durable("approval_decided", { call_id: "k", tool: "shell", decision: "allow", actor: "alice" }));
    state = fold(state, durable("approval_resolved", { call_id: "k", resolved_by: "alice" }));
    const approval = state.entries.find((e) => e.kind === "approval") as Extract<Entry, { kind: "approval" }>;
    assert.equal(approval.decision, "allow");
    assert.equal(approval.resolvedBy, "alice");
    assert.equal(openApprovals(state).length, 0);
  });

  it("keeps a blob reference as a reference", () => {
    seq = 0;
    const ref = { blob: "sha256:aa", size: 40_000, preview: "first bit", truncated: true };
    const state = foldAll([
      durable("tool_call_started", { call_id: "b", name: "read", args: {} }),
      durable("tool_call_completed", { call_id: "b", name: "read", ok: true, content: ref }),
    ]);
    const tool = state.entries[0] as Extract<Entry, { kind: "tool" }>;
    assert.deepEqual(tool.content, ref);
  });

  it("records the cursor and ignores an event it has already folded", () => {
    seq = 0;
    const e = durable("user_input", { source: "user", text: "once" });
    const state = foldAll([e]);
    assert.equal(state.lastSeq, e.seq);
    // Dropping duplicates is `SessionView`'s job, so the fold is free to be pure; what
    // it must not do is move the cursor backwards.
    assert.equal(fold(state, durable("user_input", { source: "user", text: "later" })).lastSeq, e.seq + 1);
  });
});
