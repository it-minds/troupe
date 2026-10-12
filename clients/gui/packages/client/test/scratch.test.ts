// The session's scratchpad (issue #472). An agent's `show` writes a named document instead
// of printing it in the chat; the transcript has a card where the call would be, never the
// document's text, and the session's documents are a fold over `scratch_updated`, so a
// client that attaches late has them all from the replay. The text is read with `fs.read`
// on the document's `scratch:/` path, and `scratch.list` lists them.

import assert from "node:assert/strict";
import { after, afterEach, before, beforeEach, describe, it } from "node:test";
import { DaemonClient, emptyTranscript, fold, scratchLine, scratchSize } from "../src/index.js";
import type { DurableEvent, Entry, TranscriptState, TroupeEvent } from "../src/index.js";
import { FakeDaemon } from "./support/daemon.js";
import { startHarness, type Harness } from "./support/harness.js";
import { sleep } from "./support/worker.js";

let seq = 0;
function durable(type: string, data: Record<string, unknown> = {}, agent = ["root"]): DurableEvent {
  seq += 1;
  return { seq, prev_hash: null, ts: new Date(Date.UTC(2026, 9, 11, 9, 0, seq)).toISOString(), actor: { kind: "agent" }, agent, type, v: 1, data };
}
const foldAll = (events: TroupeEvent[], from: TranscriptState = emptyTranscript) => events.reduce((s, e) => fold(s, e), from);
const cards = (state: TranscriptState) => state.entries.filter((e): e is Extract<Entry, { kind: "scratch" }> => e.kind === "scratch");

const PLAN = "# Migration plan\n\n" + "- move the ledger table\n".repeat(97);
const PLAN_SIZE = Buffer.byteLength(PLAN);

/** A `show` as the harness writes it: the call, the document's event, the answer. */
function show(callId: string, args: { name: string; title: string; kind?: string; content: string }, version: number, hash = `sha256:${callId}`): DurableEvent[] {
  const size = Buffer.byteLength(args.content);
  return [
    durable("tool_call_started", { call_id: callId, name: "show", args }),
    durable("scratch_updated", { name: args.name, path: `scratch:/${args.name}`, kind: args.kind ?? "markdown", title: args.title, size, hash, version, call_id: callId }),
    durable("tool_call_completed", { call_id: callId, name: "show", ok: true, content: `shown at scratch:/${args.name}, version ${version}` }),
  ];
}

describe("the scratchpad in the fold (issue #472)", () => {
  it("makes a show call one card with its title, name, size and version, and none of its text", () => {
    seq = 0;
    const [started, updated, completed] = show("c1", { name: "plan.md", title: "Migration plan", kind: "markdown", content: PLAN }, 1);

    // Before its event, the card is what the call's arguments said, without the count.
    const running = foldAll([started!]);
    assert.deepEqual(running.entries.map((e) => e.kind), ["scratch"]);
    const early = cards(running)[0]!;
    assert.equal(early.version, undefined);
    assert.equal(early.size, PLAN_SIZE);
    assert.equal(scratchLine(early), `Migration plan · plan.md · ${scratchSize(PLAN_SIZE)}`);

    const state = foldAll([updated!, completed!], running);
    assert.deepEqual(state.entries.map((e) => e.kind), ["scratch"], "one card, and no tool call beside it");
    const card = cards(state)[0]!;
    assert.equal(card.ok, true);
    assert.equal(card.version, 1);
    assert.equal(scratchLine(card), "Migration plan · plan.md · 2.3 KB · new");
    assert.ok(!JSON.stringify(state.entries).includes("move the ledger table"), "the document's text is in no entry");

    // Written again under the same name: the next card says which write it was.
    const again = foldAll(show("c2", { name: "plan.md", title: "Migration plan, revised", content: "# Migration plan\n\nDone.\n" }, 2), state);
    assert.equal(scratchLine(cards(again)[1]!), "Migration plan, revised · plan.md · 24 bytes · updated 2 times");
    assert.equal(scratchLine(cards(again)[0]!), "Migration plan · plan.md · 2.3 KB · new", "the first card still says the first write");
  });

  it("keeps the documents in the order each name was first written, at the latest version", () => {
    seq = 0;
    const state = foldAll([
      ...show("c1", { name: "plan.md", title: "Migration plan", content: PLAN }, 1, "sha256:aaa"),
      ...show("c2", { name: "rows.csv", title: "Rows moved", kind: "csv", content: "table,rows\nledger,12\n" }, 1, "sha256:bbb"),
      ...show("c3", { name: "plan.md", title: "Migration plan, revised", content: "# Plan\n" }, 2, "sha256:ccc"),
    ]);
    assert.deepEqual(
      state.scratch.map((d) => [d.name, d.title, d.size, d.hash, d.version, d.kind]),
      [
        ["plan.md", "Migration plan, revised", 7, "sha256:ccc", 2, "markdown"],
        ["rows.csv", "Rows moved", 21, "sha256:bbb", 1, "csv"],
      ],
    );
    assert.equal(state.scratch[0]!.path, "scratch:/plan.md");
    assert.equal(state.scratch[0]!.call_id, "c3");
  });

  it("gives a second client replaying from seq 0 the same documents and cards, and a replay folded twice changes nothing", () => {
    seq = 0;
    const log = [
      durable("user_input", { source: "user", text: "write the plan down" }),
      ...show("c1", { name: "plan.md", title: "Migration plan", content: PLAN }, 1),
      ...show("c2", { name: "rows.csv", title: "Rows moved", kind: "csv", content: "a,b\n" }, 1),
      ...show("c3", { name: "plan.md", title: "Migration plan", content: PLAN + "- done\n" }, 2),
    ];
    const first = foldAll(log);
    const second = foldAll(log);
    assert.deepEqual(second.scratch, first.scratch);
    assert.deepEqual(second.entries, first.entries);
    assert.deepEqual(foldAll(log, first).scratch, first.scratch, "an older version arriving again does not replace a newer one");
  });

  it("fills a card whose event was written first, one whose event names no call, and says why one failed", () => {
    seq = 0;
    const content = "x".repeat(10);
    const state = foldAll([
      // The event ahead of its call.
      durable("scratch_updated", { name: "a.md", path: "scratch:/a.md", kind: "markdown", title: "A", size: 10, hash: "sha256:a", version: 3, call_id: "c1" }),
      durable("tool_call_started", { call_id: "c1", name: "show", args: { name: "a.md", title: "A", content } }),
      // An event from a log that named no call.
      durable("tool_call_started", { call_id: "c2", name: "show", args: { name: "b.txt", title: "B", kind: "text", content } }),
      durable("scratch_updated", { name: "b.txt", path: "scratch:/b.txt", kind: "text", title: "B", size: 10, hash: "sha256:b", version: 1 }),
      // A name the scratchpad refuses.
      durable("tool_call_started", { call_id: "c3", name: "show", args: { name: "Bad Name", title: "C", content } }),
      durable("tool_call_completed", { call_id: "c3", name: "show", ok: false, content: "not a scratchpad name: Bad Name" }),
    ]);
    const [a, b, c] = cards(state);
    assert.equal(scratchLine(a!), "A · a.md · 10 bytes · updated 3 times");
    assert.equal(scratchLine(b!), "B · b.txt · 10 bytes · new");
    assert.equal(c!.ok, false);
    assert.equal(c!.error, "not a scratchpad name: Bad Name");
    assert.deepEqual(state.scratch.map((d) => d.name), ["a.md", "b.txt"]);
  });

  it("says a size the way a person reads one", () => {
    assert.equal(scratchSize(1), "1 byte");
    assert.equal(scratchSize(512), "512 bytes");
    assert.equal(scratchSize(2_355), "2.3 KB");
    assert.equal(scratchSize(1_468_006), "1.4 MB");
  });
});

describe("the scratchpad over a socket (issue #472)", () => {
  let daemon: FakeDaemon;
  let client: DaemonClient;

  beforeEach(async () => {
    daemon = new FakeDaemon({ osUser: "ada" });
    await daemon.start();
    client = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
  });

  afterEach(async () => {
    client.disconnect();
    await daemon.stop();
  });

  it("lists what a client that attached late folds from the replay, and reads each through fs.read", async () => {
    const session = daemon.seed("/home/ada/repo");
    session.scratch.show(session.log, { name: "plan.md", title: "Migration plan", content: PLAN }, "c1");
    session.scratch.show(session.log, { name: "rows.csv", title: "Rows moved", content: "a,b\n" }, "c2");
    session.scratch.show(session.log, { name: "plan.md", title: "Migration plan", content: "# Plan\n\nDone.\n" }, "c3");

    let state = emptyTranscript;
    const listener = (e: TroupeEvent): void => void (state = fold(state, e));
    const view = await client.open(session.id, {}, listener);
    await until(() => state.lastSeq >= session.log.headSeq, "the replay");

    const listed = await view.scratchList();
    assert.deepEqual(
      listed.map((d) => [d.name, d.version, d.hash]),
      state.scratch.map((d) => [d.name, d.version, d.hash]),
      "the list and the fold agree",
    );
    assert.deepEqual(listed.map((d) => d.name), ["plan.md", "rows.csv"]);

    const plan = await view.scratchRead(state.scratch[0]!);
    assert.equal(plan.content, "# Plan\n\nDone.\n");
    assert.equal(plan.hash, state.scratch[0]!.hash, "the hash the event carried");
    assert.equal(cards(state).length, 3);
    await client.close(session.id, listener);
  });
});

describe("the scratchpad on a pod (issue #472)", () => {
  let h: Harness;
  before(async () => {
    h = await startHarness();
  });
  after(() => h.stop());

  it("makes a card of each show, a second version of the same name, and reads the latest through fs.read", async () => {
    const auth = await h.signIn();
    const row = h.plane.seed("alice@example.com");
    let state = emptyTranscript;
    const a = await h.attach(auth, row.id, { hooks: { onEvent: (e) => void (state = fold(state, e)) } });

    await a.view.send("show: Findings");
    await until(() => state.entries.some((e) => e.kind === "assistant"), "the first turn's answer");
    await a.view.send("show: Findings, revised");
    await until(() => cards(state).filter((c) => c.ok).length === 2, "the second show");

    assert.deepEqual(
      cards(state).map((c) => [c.title, c.version, c.ok]),
      [
        ["Findings", 1, true],
        ["Findings, revised", 2, true],
      ],
    );
    assert.ok(!state.entries.some((e) => e.kind === "tool"), "no show call is a tool entry");
    const [notes] = await a.view.scratchList();
    assert.equal(notes?.name, "notes.md");
    assert.equal(notes?.version, 2);
    const read = await a.view.scratchRead(notes!);
    assert.ok(read.content.startsWith("# Findings, revised\n"));
    assert.equal(read.hash, state.scratch[0]?.hash);
    await a.close();
  });
});

async function until(pred: () => boolean, what: string, timeoutMs = 5_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!pred()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await sleep(5);
  }
}
