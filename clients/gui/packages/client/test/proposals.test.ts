// What the harness proposes in a pod session (troupe #1208), as the shared fold keeps it:
// a card once, whatever replays it, and its answer's line; from a checkpoint, the open one
// drawn as it was; the logs the harness recorded under test/fixtures/proposals read the same
// way the core reads them; and the schedule's chooser as cron and back.

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { describe, it } from "node:test";
import {
  answeredLine,
  cronOf,
  editsOf,
  emptyTranscript,
  fold,
  fromCheckpoint,
  runsLine,
  scheduleOf,
  scheduleWords,
} from "../src/index.js";
import type { DurableEvent, Entry, ProposalState, TranscriptState } from "../src/index.js";

const recordings = new URL("../../../../../test/fixtures/proposals/", import.meta.url);
const noRecordings = existsSync(recordings) ? false : "the recorded logs are at the repository's root, outside this build";

function recorded(name: string): DurableEvent[] {
  return readFileSync(new URL(`${name}.jsonl`, recordings), "utf8")
    .split(/\r?\n/)
    .filter((line) => line.trim() !== "")
    .map((line) => JSON.parse(line) as DurableEvent);
}

const foldAll = (events: DurableEvent[], from: TranscriptState = emptyTranscript): TranscriptState => events.reduce((s, e) => fold(s, e), from);
const proposals = (s: TranscriptState) => s.entries.filter((e): e is Extract<Entry, { kind: "proposal" }> => e.kind === "proposal");

describe("a proposal in the transcript", { skip: noRecordings }, () => {
  it("open: one card, with its question, why, draft and answers, and nothing waiting", () => {
    const log = recorded("open");
    const state = foldAll(log);
    const [card] = proposals(state);
    assert.ok(card);
    assert.equal(card.id, "proposal-1");
    assert.equal(card.title, "Rerun this report every Monday?");
    assert.match(card.why, /live data/);
    assert.deepEqual(card.options, ["accepted", "later", "never"]);
    assert.equal(card.mode, "direct");
    assert.equal(card.draft.source.cron, "0 6 * * 1");
    assert.equal(card.decision, undefined);
    // The same log again draws the same one card.
    assert.equal(proposals(foldAll(log, state)).length, 1);
    // Nothing waits for it.
    assert.equal(state.entries.some((e) => e.kind === "question"), false);
  });

  it("accepted and never: the card carries its answer, who gave it and what a yes made", () => {
    const [accepted] = proposals(foldAll(recorded("accepted")));
    assert.equal(accepted?.decision, "accepted");
    assert.equal(accepted?.result?.name, "rerun-weekly-numbers");
    assert.deepEqual(accepted?.edited, ["cron"]);
    assert.equal(accepted?.answeredBy, "ada@example.test");
    assert.equal(answeredLine(accepted as ProposalState, true), "You turned on a rerun of “Weekly numbers”, every day at 06:00 UTC.");

    const [never] = proposals(foldAll(recorded("never")));
    assert.equal(never?.decision, "never");
    assert.equal(answeredLine(never as ProposalState, true), "You won't be asked about rerunning “Weekly numbers” again.");
    assert.equal(answeredLine(never as ProposalState, false), "Ada said never for rerunning “Weekly numbers”.");
  });

  it("from a checkpoint, an open proposal in its facts is drawn as it was", () => {
    const made = recorded("open").find((e) => e.type === "proposal_made")!;
    const checkpoint: DurableEvent = {
      ...made,
      seq: made.seq + 1,
      type: "checkpoint",
      data: { shape: "session/1", through: made.seq, compacted: 1, previous: null, summary: "earlier", facts: { open_proposals: [{ id: "proposal-1", seq: made.seq, agent: ["root"], data: made.data }] } },
    };
    const state = fromCheckpoint(checkpoint);
    const [card] = proposals(state);
    assert.equal(card?.id, "proposal-1");
    assert.equal(card?.decision, undefined);
  });
});

describe("the schedule and the card's words", () => {
  it("reads a cron as the chooser offers it, and writes it back", () => {
    assert.deepEqual(scheduleOf("0 6 * * 1"), { every: "weekly", hour: 6, day: 1, cron: "0 6 * * 1" });
    assert.equal(scheduleOf("0 7 * * 1-5").every, "weekdays");
    assert.equal(scheduleOf("0 9 1 * *").every, "monthly");
    assert.equal(scheduleOf("*/15 * * * *").every, "custom");
    assert.equal(cronOf({ every: "daily", hour: 8, day: 1, cron: "" }), "0 8 * * *");
    assert.equal(cronOf({ every: "weekly", hour: 6, day: 5, cron: "" }), "0 6 * * 5");
    assert.equal(cronOf({ every: "custom", hour: 6, day: 1, cron: " 30 2 * * 0 " }), "30 2 * * 0");
    assert.equal(scheduleWords("0 6 * * 1"), "every Monday at 06:00 UTC");
    assert.equal(scheduleWords("30 2 * * 0"), "on the schedule 30 2 * * 0 (UTC)");
  });

  it("sends only what the owner changed, and says what it runs as and costs", () => {
    // A draft as the harness writes one, here rather than read from a recording, so this
    // runs where the recordings are not (the GUI image sees clients/gui alone).
    const draft: ProposalState["draft"] = {
      name: "rerun-weekly-numbers",
      schedule: "every Monday",
      source: { kind: "schedule", cron: "0 6 * * 1", tz: "UTC" },
      prompt_template: "Pull the numbers and publish the weekly report.",
      profile: "build",
      agent: "build",
      visibility: "private",
      review: "required",
      notify: [],
      terms: { budget_micros: 1_000_000, approvals: "deny", allow: ["publish_artifact", "shell(curl)"] },
      artifact: { id: "art-weeklynumbers01", title: "Weekly numbers", version: 1 },
    };
    assert.deepEqual(editsOf(draft, draft.source.cron, draft.prompt_template, 1_000_000), {});
    assert.deepEqual(editsOf(draft, "0 7 * * 1-5", draft.prompt_template, 2_000_000), { cron: "0 7 * * 1-5", budget_micros: 2_000_000 });
    assert.equal(runsLine(draft), "Runs as you, on build, up to $1.00 a run; each run is a new version of “Weekly numbers”, and you are asked to review it.");
  });
});
