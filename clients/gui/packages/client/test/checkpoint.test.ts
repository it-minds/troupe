// The transcript fold against the checkpoints sessions wrote (troupe #1181): logs under
// test/fixtures/checkpoints at the repository's root, recorded against the scripted model
// with their checkpoints in place. For each checkpoint, its facts are what this fold says at
// its `through` on the fields both keep (usage, cost, goal, the task list, what waits on a
// person); and this fold started from it, its facts given as the events they stand for, then
// the tail, says what the fold from seq 1 says on those fields, the history before aside.

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { emptyTranscript, fold, openApprovals, openQuestions } from "../src/index.js";
import type { DurableEvent, TranscriptState } from "../src/index.js";

const recordings = new URL("../../../../../test/fixtures/checkpoints/", import.meta.url);

// The image build (clients/gui/Dockerfile) sees clients/gui alone, so these logs are not
// there; the GUI job in ci.yml has the whole repository and runs them.
const noRecordings = existsSync(recordings)
  ? false
  : "the recorded logs are at the repository's root, outside this build";

type Facts = {
  usage: Record<string, number>;
  cost_micros: number;
  goal: string | null;
  todos: { content: string }[];
  open_approvals: { call_id: string; agent: string[]; data: Record<string, unknown> }[];
  open_questions: { call_id: string; agent: string[]; data: Record<string, unknown> }[];
  agent: string | null;
};

function recorded(name: string): DurableEvent[] {
  return readFileSync(new URL(`${name}.jsonl`, recordings), "utf8")
    .split(/\r?\n/)
    .filter((line) => line.trim() !== "")
    .map((line) => JSON.parse(line) as DurableEvent);
}

const foldAll = (events: DurableEvent[]): TranscriptState => events.reduce((s, e) => fold(s, e), emptyTranscript);

// What both folds keep, as this one keeps it.
function shared(state: TranscriptState) {
  return {
    usage: state.usage ?? { input_tokens: 0, cache_read: 0, cache_write: 0, output_tokens: 0 },
    cost: state.costMicros ?? 0,
    goal: state.goal ?? null,
    todos: state.todo.map((t) => t.content),
    waiting: [...openApprovals(state), ...openQuestions(state)].map((e) => e.callId).sort(),
  };
}

// The same fields, as the checkpoint says them.
function factsShared(facts: Facts) {
  const u = facts.usage;
  return {
    usage: {
      input_tokens: u["input_tokens"] ?? 0,
      cache_read: u["cache_read"] ?? 0,
      cache_write: u["cache_write"] ?? 0,
      output_tokens: u["output_tokens"] ?? 0,
    },
    cost: facts.cost_micros,
    goal: facts.goal,
    todos: facts.todos.map((t) => t.content),
    waiting: [...facts.open_approvals, ...facts.open_questions].map((e) => e.call_id).sort(),
  };
}

// The checkpoint's facts as events this fold reads, at seqs below its `through`: what a
// reader starting there begins from.
function seeded(checkpoint: DurableEvent): DurableEvent[] {
  const facts = checkpoint.data["facts"] as Facts;
  const root = ["root"];
  const steps: [string, string[], Record<string, unknown>][] = [
    ["agent_started", root, { profile: facts.agent }],
    [
      "llm_response",
      root,
      { message: { role: "assistant", content: [] }, usage: facts.usage, gateway: { cost_micros: facts.cost_micros } },
    ],
    ...(facts.goal ? [["goal_set", root, { text: facts.goal }] as [string, string[], Record<string, unknown>]] : []),
    ["todo_updated", root, { items: facts.todos }],
    ...facts.open_approvals.map((a) => ["approval_requested", a.agent, a.data] as [string, string[], Record<string, unknown>]),
    ...facts.open_questions.map((q) => ["question_asked", q.agent, q.data] as [string, string[], Record<string, unknown>]),
  ];
  return steps.map(([type, agent, data], i) => ({
    seq: i + 1,
    prev_hash: null,
    ts: checkpoint.ts,
    actor: { kind: "system" },
    agent,
    type,
    v: 1,
    data,
  }));
}

describe("a checkpoint in a recorded log", { skip: noRecordings }, () => {
  for (const name of ["manual", "threshold", "overflow", "background_approval"]) {
    it(`${name}: is the fold at its through, and from it the fold of the whole`, () => {
      const log = recorded(name);
      const checkpoints = log.filter((e) => e.type === "checkpoint");
      assert.notEqual(checkpoints.length, 0);
      const whole = shared(foldAll(log));

      for (const checkpoint of checkpoints) {
        const through = checkpoint.data["through"] as number;
        assert.deepEqual(
          factsShared(checkpoint.data["facts"] as Facts),
          shared(foldAll(log.filter((e) => e.seq <= through))),
          `the facts at ${through}`,
        );
        const tail = log.filter((e) => e.seq > through);
        assert.deepEqual(shared(foldAll([...seeded(checkpoint), ...tail])), whole, `from ${checkpoint.seq}`);
      }
    });
  }

  it("draws nothing in the transcript", () => {
    const log = recorded("manual");
    const without = log.filter((e) => e.type !== "checkpoint");
    assert.deepEqual(foldAll(log).entries, foldAll(without).entries);
  });
});
