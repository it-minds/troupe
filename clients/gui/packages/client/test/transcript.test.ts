// The fold, on its own. No sockets: a transcript is a function of the events, and the
// properties worth pinning down are the ones that make two clients agree — replaying
// the same log twice produces the same list, and an ephemeral changes nothing durable.

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { addPending, dropPending, emptyTranscript, fold, isBusy, needsYou, openApprovals, openQuestions, rootState } from "../src/index.js";
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

  it("ends an approval with its call, or with a cancel of the agent that asked or of one above it", () => {
    seq = 0;
    const asked = foldAll([
      durable("approval_requested", { call_id: "a", tool: "shell", args: {} }),
      durable("approval_requested", { call_id: "b", tool: "shell", args: {} }, ["root", "explore"]),
      durable("approval_requested", { call_id: "c", tool: "shell", args: {} }, ["root", "other"]),
    ]);
    assert.equal(openApprovals(asked).length, 3);

    const timedOut = fold(asked, durable("tool_call_completed", { call_id: "a", name: "shell", ok: false, content: "The tool timed out after 180000ms." }));
    assert.deepEqual(
      openApprovals(timedOut).map((e) => e.callId),
      ["b", "c"],
    );

    // A subagent's cancel reaches it and what is under it, not its siblings.
    const cancelled = fold(timedOut, durable("cancelled", {}, ["root", "explore"]));
    assert.deepEqual(
      openApprovals(cancelled).map((e) => e.callId),
      ["c"],
    );
    assert.equal(cancelled.entries.at(-1)?.kind, "system", "the cancel is still said in the transcript");
    assert.deepEqual(openApprovals(fold(cancelled, durable("cancelled"))), []);
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

// Logs real sessions wrote against the scripted model (test/fixtures/approvals at the
// repository's root), so the inbox is held to what the daemon actually writes (#142): a
// cancel closes each call it stops with a `tool_call_completed` and then says
// `cancelled`; a tool that timed out waiting is closed the same way; a subagent the cancel
// took down says nothing at all. `open` stops while the approval is still waiting.
const recordings = new URL("../../../../../test/fixtures/approvals/", import.meta.url);

// The image build (clients/gui/Dockerfile) sees clients/gui alone, so these logs are not
// there; the GUI job in ci.yml has the whole repository and runs them.
const noRecordings = existsSync(recordings)
  ? false
  : "the recorded logs are at the repository's root, outside this build";

function recorded(name: string): DurableEvent[] {
  return readFileSync(new URL(`${name}.jsonl`, recordings), "utf8")
    .split(/\r?\n/)
    .filter((line) => line.trim() !== "")
    .map((line) => JSON.parse(line) as DurableEvent);
}

describe("an approval in a recorded log", { skip: noRecordings }, () => {
  it("is not open once its turn was cancelled or its tool timed out", () => {
    for (const name of ["cancelled", "timed_out", "subagent_cancelled"]) {
      const state = foldAll(recorded(name));
      assert.deepEqual(openApprovals(state), [], name);
      assert.equal(needsYou(state), false, name);
    }
  });

  it("is closed by its decision, and open while nobody has answered it", () => {
    const decided = foldAll(recorded("decided"));
    assert.deepEqual(openApprovals(decided), []);
    const approval = decided.entries.find((e) => e.kind === "approval") as Extract<Entry, { kind: "approval" }>;
    assert.equal(approval.decision, "allow");
    assert.equal(approval.closed, false, "an answered approval is a decision, not one that ended unanswered");

    const open = foldAll(recorded("open"));
    assert.equal(openApprovals(open).length, 1);
    assert.equal(needsYou(open), true);
  });
});

describe("questions, and what the daemon says about limits (troupe-remote Decisions 658-660)", () => {
  it("folds an ask_user into an open question, and the answer closes it", () => {
    seq = 0;
    const asked = foldAll([
      durable("question_asked", {
        call_id: "q1",
        agent_path: ["root"],
        question: "Which colour?",
        options: [{ label: "red", description: null }, { label: "blue", description: "calm" }, "green"],
        multiple: true,
      }),
    ]);

    const [q] = openQuestions(asked);
    assert.ok(q);
    assert.equal(q.asked, "agent");
    assert.equal(q.question, "Which colour?");
    assert.equal(q.multiple, true);
    assert.deepEqual(
      q.options.map((o) => o.label),
      ["red", "blue", "green"],
    );
    assert.equal(needsYou(asked), true);

    const answered = fold(asked, durable("question_answered", { call_id: "q1", text: "blue, green" }));
    assert.deepEqual(openQuestions(answered), []);
    assert.equal((answered.entries[0] as Extract<Entry, { kind: "question" }>).answer, "blue, green");
    assert.equal(needsYou(answered), false);
  });

  it("makes one budget question of the harness's own event and the question it rides on, whichever comes first", () => {
    seq = 0;
    const first = foldAll([
      durable("budget_ask_started", { call_id: "budget-1", dimension: "turns", used: 40, limit: 40, detail: "turns 40/40 (100%)" }),
      durable("question_asked", {
        call_id: "budget-1",
        agent_path: ["root"],
        question: "turns 40/40 (100%) — continue?",
        options: [{ label: "allow" }, { label: "always" }, { label: "deny" }],
        multiple: false,
      }),
    ]);

    assert.equal(openQuestions(first).length, 1, "one entry, not two");
    const [q] = openQuestions(first);
    assert.equal(q!.asked, "budget");
    assert.equal(q!.question, "turns 40/40 (100%)");
    assert.deepEqual(
      q!.options.map((o) => o.label),
      ["allow", "always", "deny"],
    );

    // The other order — a client that subscribed between the two — is the same entry.
    seq = 0;
    const other = foldAll([
      durable("question_asked", { call_id: "budget-1", agent_path: ["root"], question: "turns 40/40 (100%) — continue?", options: [], multiple: false }),
      durable("budget_ask_started", { call_id: "budget-1", dimension: "turns", used: 40, limit: 40, detail: "turns 40/40 (100%)" }),
    ]);
    assert.equal(openQuestions(other).length, 1);
    assert.equal(openQuestions(other)[0]!.asked, "budget");

    // Either answer event closes it; the second changes nothing.
    const closed = foldAll(
      [durable("budget_ask_answered", { call_id: "budget-1", decision: "allow", grant: { turns: 40 } }), durable("question_answered", { call_id: "budget-1", text: "allow" })],
      first,
    );
    assert.deepEqual(openQuestions(closed), []);
    assert.equal((closed.entries[0] as Extract<Entry, { kind: "question" }>).answer, "allow");
  });

  it("shows the harness's notes as notes, not as the person's words", () => {
    seq = 0;
    const state = foldAll([
      durable("user_input", { source: "harness", text: "Your previous reply was cut off" }),
      durable("truncated", { reason: "max_tokens", note: "…" }),
      durable("truncated", { reason: "empty", final: true }),
      durable("truncated", { reason: "max_tokens", calls: 2 }),
      durable("compacted", { summary: "s", reason: "context_overflow" }),
      durable("budget_warning", { dimension: "turns", used: 32, limit: 40, fraction: 0.8, detail: "turns 32/40 (80%)" }),
    ]);

    assert.deepEqual(
      state.entries.map((e) => e.kind),
      ["system", "system", "system", "system", "system", "system"],
    );
    const texts = state.entries.map((e) => (e as Extract<Entry, { kind: "system" }>).text);
    assert.equal(texts[0], "the harness said: Your previous reply was cut off");
    assert.equal(texts[1], "the reply was cut at the output cap; asking again");
    assert.equal(texts[2], "the reply had no text and no tool call; giving up");
    assert.match(texts[3]!, /2 tool call\(s\) answered with an error/);
    assert.match(texts[4]!, /no longer fit/);
    assert.equal(texts[5], "nearly out: turns 32/40 (80%)");
  });

  it("streams the daemon's reasoning into the thinking pane, and a waiting agent needs you", () => {
    seq = 0;
    const state = foldAll([ephemeral("llm_delta", { kind: "reasoning", text: "let me " }), ephemeral("llm_delta", { kind: "reasoning", text: "think" })]);
    assert.equal(state.thinking, "let me think");
    assert.equal(needsYou(fold(state, ephemeral("agent_state", { state: "waiting" }))), true);
    assert.equal(isBusy(fold(state, ephemeral("agent_state", { state: "waiting" }))), false);
  });
});
