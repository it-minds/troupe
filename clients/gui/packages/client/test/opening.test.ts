// Opening a transcript (troupe #1182): the replay folded at once says what the fold an
// event at a time says; a transcript opened from a checkpoint is its summary, what still
// waits, and the tail; and history paged in before it, a page at a time down to seq 1, draws
// what the fold from seq 1 draws. Over the logs real sessions wrote, with their
// checkpoints in place (test/fixtures/checkpoints, troupe #1181), and the approval and
// question recordings beside them.

import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { TranscriptFeed, emptyTranscript, fold, foldMany, fromCheckpoint, openApprovals, withEarlier } from "../src/index.js";
import type { DurableEvent, Entry, TranscriptState, TroupeEvent } from "../src/index.js";

const fixtures = new URL("../../../../../test/fixtures/", import.meta.url);

// The image build (clients/gui/Dockerfile) sees clients/gui alone, so these logs are not
// there; the GUI job in ci.yml has the whole repository and runs them.
const noRecordings = existsSync(fixtures) ? false : "the recorded logs are at the repository's root, outside this build";

function recorded(dir: string, name: string): DurableEvent[] {
  return readFileSync(new URL(`${dir}/${name}`, fixtures), "utf8")
    .split(/\r?\n/)
    .filter((line) => line.trim() !== "")
    .map((line) => JSON.parse(line) as DurableEvent);
}

function logs(dir: string): Array<[string, DurableEvent[]]> {
  if (noRecordings) return [];
  return readdirSync(new URL(`${dir}/`, fixtures))
    .filter((f) => f.endsWith(".jsonl"))
    .map((f) => [`${dir}/${f}`, recorded(dir, f)]);
}

const lastCheckpoint = (log: DurableEvent[]): DurableEvent => [...log].reverse().find((e) => e.type === "checkpoint")!;

const NOW =Date.parse("2026-11-23T12:00:00Z");
const oneByOne = (events: readonly TroupeEvent[], from: TranscriptState = emptyTranscript): TranscriptState =>
  events.reduce((s, e) => fold(s, e, { now: NOW }), from);

// What a session's start draws in front of its first turn, which every fold here draws alike.
const byStream = (entries: Entry[]): Entry[] => entries.filter((e) => e.kind !== "earlier");

/** Feed `events` through a `TranscriptFeed` as a socket would: the answer, then the replay. */
function fed(events: DurableEvent[], answer: { head_seq: number; checkpoint?: unknown }): { state: TranscriptState; sets: number } {
  let state = emptyTranscript;
  let sets = 0;
  const feed = new TranscriptFeed((update) => {
    sets += 1;
    state = update(state);
  });
  feed.subscribed(answer);
  for (const e of events) feed.push(e, NOW);
  feed.stop();
  return { state, sets };
}

describe("the replay folded at once", { skip: noRecordings }, () => {
  for (const [name, log] of [...logs("checkpoints"), ...logs("approvals"), ...logs("questions")]) {
    it(`${name}: is the fold an event at a time, set once`, () => {
      const { state, sets } = fed(log, { head_seq: log.at(-1)!.seq });
      assert.equal(sets, 1);
      assert.deepEqual(state, oneByOne(log));
    });
  }

  it("holds events that arrive before the subscription's answer, and goes live after the head", () => {
    const log = recorded("checkpoints", "manual.jsonl");
    let state = emptyTranscript;
    let sets = 0;
    const feed = new TranscriptFeed((update) => {
      sets += 1;
      state = update(state);
    });
    for (const e of log.slice(0, 40)) feed.push(e, NOW);
    assert.equal(sets, 0);
    feed.subscribed({ head_seq: 45 });
    for (const e of log.slice(40, 45)) feed.push(e, NOW);
    assert.equal(sets, 1);
    assert.equal(feed.live, true);
    for (const e of log.slice(45)) feed.push(e, NOW);
    assert.equal(sets, 1 + log.length - 45);
    assert.deepEqual(state, oneByOne(log));
  });

  it("folds what it has once nothing more arrives, when the replay stops short of the head", async () => {
    const log = recorded("checkpoints", "manual.jsonl");
    let state = emptyTranscript;
    const feed = new TranscriptFeed((update) => void (state = update(state)), 20);
    feed.subscribed({ head_seq: log.length + 5 });
    for (const e of log) feed.push(e, NOW);
    assert.equal(feed.live, false);
    await new Promise((r) => setTimeout(r, 60));
    assert.equal(feed.live, true);
    assert.deepEqual(state, oneByOne(log));
  });
});

describe("a transcript opened from a checkpoint", { skip: noRecordings }, () => {
  for (const [name, log] of logs("checkpoints")) {
    it(`${name}: is the summary, what still waits and the tail, and paged back it is the whole`, () => {
      const checkpoint = lastCheckpoint(log);
      const through = checkpoint.data["through"] as number;
      const tail = log.filter((e) => e.seq > through);
      const whole = oneByOne(log);

      // The open: what the server sends after `through`, and nothing before it.
      const { state: opened, sets } = fed(tail, { head_seq: log.at(-1)!.seq, checkpoint });
      assert.equal(sets, 1);
      assert.equal(opened.entries[0]?.kind, "earlier");
      assert.equal((opened.entries[0] as Extract<Entry, { kind: "earlier" }>).summary, checkpoint.data["summary"]);
      // Nothing from before `through` but the summary and what the checkpoint says still waits.
      const before = opened.entries.slice(1).filter((e) => e.seq <= through);
      assert.deepEqual(
        before.map((e) => ("callId" in e ? e.callId : e.kind)),
        opened.earlier!.seeded,
      );
      assert.deepEqual(opened.entries.slice(1).filter((e) => e.seq > through), oneByOne(tail).entries);
      // The head's facts are the whole session's.
      assert.deepEqual(opened.usage, whole.usage);
      assert.equal(opened.costMicros ?? 0, whole.costMicros ?? 0);
      assert.deepEqual(opened.todo, whole.todo);
      assert.equal(opened.goal, whole.goal);
      assert.equal(opened.profile, whole.profile);
      assert.equal(opened.doneReason, whole.doneReason);
      assert.deepEqual(openApprovals(opened).map((a) => a.callId), openApprovals(whole).map((a) => a.callId));
      assert.equal(opened.earlier?.more, true);

      // Paged back a few events at a time, each page drawn above the last, to seq 1.
      let state = opened;
      let pages = 0;
      while (state.earlier?.more) {
        const before = state.earlier.from;
        const page = log.filter((e) => e.seq < before).slice(-7);
        state = withEarlier(state, page, page[0]!.seq > 1);
        pages += 1;
        assert.equal(state.earlier?.from, page[0]!.seq);
      }
      assert.equal(pages, Math.ceil(through / 7));
      // Drawn where the whole fold draws it, the approvals the checkpoint still listed
      // drawn once, under the summary, in place of where they were asked.
      const bySeq = (entries: Entry[]): Entry[] => [...entries].sort((a, b) => a.seq - b.seq);
      assert.deepEqual(bySeq(byStream(state.entries)), bySeq(whole.entries));
      if (openApprovals(whole).length === 0 && name !== "checkpoints/background_approval.jsonl") assert.deepEqual(byStream(state.entries), whole.entries);
    });
  }

  it("draws a live event after the tail while a page is on its way", () => {
    const log = recorded("checkpoints", "manual.jsonl");
    const checkpoint = lastCheckpoint(log);
    const through = checkpoint.data["through"] as number;
    const opened = fed(
      log.filter((e) => e.seq > through),
      { head_seq: log.at(-1)!.seq, checkpoint },
    ).state;
    // The page is asked for; a person's line arrives before it does.
    const live: DurableEvent = { ...log.at(-1)!, seq: log.at(-1)!.seq + 1, type: "user_input", agent: ["root"], data: { source: "user", text: "and one more thing" } };
    const meanwhile = fold(opened, live, { now: NOW });
    const paged = withEarlier(
      meanwhile,
      log.filter((e) => e.seq <= through),
      false,
    );
    const last = paged.entries.at(-1)!;
    assert.equal(last.kind, "user");
    assert.equal(last.kind === "user" && last.text, "and one more thing");
    assert.equal(paged.entries.findIndex((e) => e.kind === "earlier"), paged.earlier!.drawn);
    assert.equal(paged.earlier!.more, false);
  });

  it("says the summary was made when the compaction was written, or when the checkpoint was where it says none", () => {
    const log = recorded("checkpoints", "manual.jsonl");
    const checkpoint = lastCheckpoint(log);
    const compacted = log.find((e) => e.seq === checkpoint.data["compacted"])!;
    assert.notEqual(compacted.ts, checkpoint.ts);
    const at = (state: TranscriptState): string | undefined => {
      const e = state.entries.find((x) => x.kind === "earlier");
      return e?.kind === "earlier" ? e.at : undefined;
    };

    assert.equal(at(fromCheckpoint({ ...checkpoint, data: { ...checkpoint.data, compacted_at: compacted.ts } })), compacted.ts);
    // A checkpoint written before it carried the compaction's time, as the recordings are.
    assert.equal(checkpoint.data["compacted_at"], undefined);
    assert.equal(at(fromCheckpoint(checkpoint)), checkpoint.ts);
  });

  it("starts from the summary alone for facts in a shape it does not know", () => {
    const log = recorded("checkpoints", "manual.jsonl");
    const checkpoint = lastCheckpoint(log);
    const state = fromCheckpoint({ ...checkpoint, data: { ...checkpoint.data, shape: "session/9" } });
    assert.deepEqual(state.entries.map((e) => e.kind), ["earlier"]);
    assert.equal(state.usage, undefined);
    assert.equal(state.goal, undefined);
  });
});

describe("a session with no checkpoint", () => {
  it("opens from its first event as before, with nothing earlier to page", () => {
    const events: DurableEvent[] = [
      { seq: 1, prev_hash: null, ts: "2026-11-23T10:00:00Z", actor: { kind: "system" }, agent: ["root"], type: "session_created", v: 1, data: { profile: "build" } },
      { seq: 2, prev_hash: null, ts: "2026-11-23T10:00:01Z", actor: { kind: "user", subject: "ada" }, agent: ["root"], type: "user_input", v: 1, data: { source: "user", text: "hello" } },
    ];
    const { state } = fed(events, { head_seq: 2, checkpoint: null });
    assert.deepEqual(state, foldMany(emptyTranscript, events, { now: NOW }));
    assert.equal(state.earlier, undefined);
  });
});
