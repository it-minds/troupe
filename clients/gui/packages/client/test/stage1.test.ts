// Stage 1's done items, each one a test.
//
// They run against the fakes in `support/`, which speak the protocol rather than
// imitate a screen: a real WebSocket, a real hash-chained log, a real device grant with
// a rotating refresh token, and a real CORS allowlist behind a fetch that enforces the
// same-origin policy. What is under test is the client, which is the part this
// repository owns.

import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import {
  addPending,
  awaitingApproval,
  dropPending,
  emptyTranscript,
  fold,
  FleetStore,
  isBlobRef,
  memoryTokenStore,
  PlaneSource,
  PlaneUnreachableError,
  rootState,
  AuthSession,
} from "../src/index.js";
import type { Entry, FleetRow, TranscriptState } from "../src/index.js";
import { startHarness, type Harness } from "./support/harness.js";
import { browserFetch } from "./support/plane.js";
import { sleep } from "./support/worker.js";

/** Drive a transcript the way the session view does, from the attachment's events. */
function transcriptOf(): { state: TranscriptState; onEvent: (e: Parameters<typeof fold>[1]) => void } {
  const box = {
    state: emptyTranscript,
    onEvent(e: Parameters<typeof fold>[1]) {
      box.state = fold(box.state, e);
    },
  };
  return box;
}

/** Send, waiting out a socket that is between lives. */
async function sendWhenConnected(a: { status: string; view: { send(text: string): Promise<unknown> } }, text: string): Promise<void> {
  const deadline = Date.now() + 15_000;
  let last: unknown;
  while (Date.now() < deadline) {
    if (a.status === "live") {
      try {
        await a.view.send(text);
        return;
      } catch (e) {
        last = e;
      }
    }
    await sleep(25);
  }
  throw new Error(`could not send after reconnecting: ${String(last)}`);
}

async function until(pred: () => boolean, timeoutMs = 5_000, what = "condition"): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (pred()) return;
    await sleep(5);
  }
  throw new Error(`timed out after ${timeoutMs}ms waiting for ${what}`);
}

describe("stage 1, done item 1: sign in, list, create, prompt, and stay signed in", () => {
  let h: Harness;
  before(async () => {
    h = await startHarness();
  });
  after(() => h.stop());

  it("goes from a clean profile to a streamed answer, and a relaunch needs no sign-in", async () => {
    // A clean profile: nothing stored anywhere.
    const store = memoryTokenStore();
    assert.equal(await store.read(`refresh:${h.plane.baseUrl}`), null);

    h.idp.slowDownOnce = true; // and the provider is awkward about it
    const auth = await h.signIn({ store });
    assert.equal(auth.me?.subject, "alice@example.com");

    // The rotated refresh token is persisted.
    const persisted = await store.read(`refresh:${h.plane.baseUrl}`);
    assert.ok(persisted, "the refresh token was not persisted");
    assert.equal(persisted, h.idp.issued.at(-1));

    // List: what the person can see before they have made anything.
    h.plane.seed("alice@example.com", { title: "an older session" });
    const listed = await auth.rpc<{ sessions: unknown[] }>("sessions.list", {});
    assert.equal(listed.sessions.length, 1);

    // What a profile carries, shown *before* creating anything on it.
    const { profiles } = await auth.rpc<{ profiles: Array<{ name: string; agents: string[]; skills: unknown[] }> }>(
      "profiles.list",
      {},
    );
    const dev = profiles.find((p) => p.name === "dev")!;
    assert.deepEqual(dev.agents, ["build", "plan", "explore"]);
    assert.ok(dev.skills.length > 0);

    // Create, choosing the plan agent from that list.
    const created = await auth.rpc<{ session_id: string }>("session.create", {
      profile: "dev",
      agent: "plan",
      title: "from the GUI",
    });

    const box = transcriptOf();
    let deltas = 0;
    const attachment = await h.attach(auth, created.session_id, {
      hooks: {
        onEvent: box.onEvent,
        onDelta: () => {
          deltas += 1;
        },
      },
    });
    await until(() => box.state.entries.length > 0, 5_000, "the log to replay");

    await attachment.view.send("hello");
    await until(() => box.state.entries.some((e) => e.kind === "assistant"), 5_000, "an answer");

    const answer = box.state.entries.find((e): e is Extract<Entry, { kind: "assistant" }> => e.kind === "assistant")!;
    assert.equal(answer.text, "You said: hello");
    assert.ok(deltas > 0, "the answer did not stream");
    await attachment.close();

    // The relaunch: a new AuthSession over the same store, and no interaction at all.
    // If this called the device endpoint it would hang, because nothing will approve it.
    const relaunched = new AuthSession({ planeUrl: h.plane.baseUrl, store });
    const restored = await relaunched.restore();
    assert.ok(restored, "a relaunch had to sign in again");
    assert.equal(restored.subject, "alice@example.com");
    const after = await relaunched.rpc<{ sessions: unknown[] }>("sessions.list", {});
    assert.equal(after.sessions.length, 2);
  });
});

describe("stage 1, done item 2: a plane that does not know this origin says so", () => {
  let h: Harness;
  const origin = "https://gui.example.com";
  before(async () => {
    h = await startHarness({ plane: { corsOrigins: [] } });
  });
  after(() => h.stop());

  it("names the exact origin to add, and adding it makes the same build work", async () => {
    const fetchImpl = browserFetch(origin);
    // The plane is up and correct; it simply does not allow this origin.
    h.plane.corsOrigins = ["https://someone-else.example.com"];

    const auth = new AuthSession({ planeUrl: h.plane.baseUrl, store: memoryTokenStore(), fetchImpl, origin });
    const refused = await auth.discover().then(
      () => null,
      (e: unknown) => e,
    );
    assert.ok(refused instanceof PlaneUnreachableError, `expected PlaneUnreachableError, got ${refused}`);
    assert.match(refused.message, /Add https:\/\/gui\.example\.com to TROUPE_CORS_ORIGINS/);
    assert.ok(refused.message.includes(h.plane.baseUrl));

    // Add it. Nothing else changes: same build, same store, same fetch.
    h.plane.corsOrigins = ["https://someone-else.example.com", origin];
    const same = new AuthSession({ planeUrl: h.plane.baseUrl, store: memoryTokenStore(), fetchImpl, origin });
    const discovery = await same.discover();
    assert.equal(discovery.plane.protocol_version, "1");
  });
});

describe("stage 1, done item 3: two clients on one session agree", () => {
  let h: Harness;
  before(async () => {
    h = await startHarness();
  });
  after(() => h.stop());

  it("shows the same order and the same authors, and every optimistic send reconciles", async () => {
    const alice = await h.signIn({ subject: "alice@example.com" });
    const bob = await h.signIn({ subject: "bob@example.com" });
    const row = h.plane.seed("alice@example.com", { title: "shared" });

    const a = transcriptOf();
    const b = transcriptOf();
    const one = await h.attach(alice, row.id, { hooks: { onEvent: a.onEvent } });
    const two = await h.attach(bob, row.id, { hooks: { onEvent: b.onEvent } });

    // Each sends 50 inputs, optimistically rendered and reconciled on the
    // `input_accepted` that carries the very command id it sent.
    const sends: Promise<unknown>[] = [];
    for (let i = 0; i < 50; i++) {
      for (const [view, box] of [
        [one, a],
        [two, b],
      ] as const) {
        const commandId = view.view.conn.nextCommandId();
        box.state = addPending(box.state, commandId, `n${i}`);
        sends.push(
          view.view.send(`n${i}`, commandId).catch((e) => {
            box.state = dropPending(box.state, commandId);
            throw e;
          }),
        );
      }
    }
    await Promise.all(sends);

    const userEntries = (s: TranscriptState) => s.entries.filter((e) => e.kind === "user");
    await until(() => userEntries(a.state).length === 100 && userEntries(b.state).length === 100, 20_000, "100 inputs each");

    // Not one optimistic entry is left over: every send was reconciled.
    assert.deepEqual(a.state.pending, [], "an optimistic send on client one never reconciled");
    assert.deepEqual(b.state.pending, [], "an optimistic send on client two never reconciled");

    // The same order and the same authors, both folded from seq 0 on different sockets.
    const shape = (s: TranscriptState) =>
      userEntries(s).map((e) => `${e.seq}:${(e as Extract<Entry, { kind: "user" }>).author}:${(e as Extract<Entry, { kind: "user" }>).text}`);
    assert.deepEqual(shape(a.state), shape(b.state));

    const authors = new Set(shape(a.state).map((s) => s.split(":")[1]));
    assert.deepEqual([...authors].sort(), ["alice@example.com", "bob@example.com"]);

    await one.close();
    await two.close();
  });
});

describe("stage 1, done item 4: the approvals inbox", () => {
  let h: Harness;
  before(async () => {
    h = await startHarness();
  });
  after(() => h.stop());

  it("lists approvals from three sessions with none of them open, and the first answer wins", async () => {
    const alice = await h.signIn({ subject: "alice@example.com" });
    const bob = await h.signIn({ subject: "bob@example.com" });

    // Three sessions, each stopped on an approval. They are then closed: the inbox must
    // not need any of them open.
    const ids: string[] = [];
    for (let i = 0; i < 3; i++) {
      const row = h.plane.seed("alice@example.com", { title: `job ${i}` });
      ids.push(row.id);
      const a = await h.attach(alice, row.id);
      const asked = a.view.waitFor((e) => e.type === "approval_requested", 5_000, "approval_requested");
      await a.view.send(`approve: rm -rf /tmp/${i}`);
      await asked;
      await a.close();
    }
    await until(() => h.worker.connectionCount === 0, 5_000, "every session to be closed");

    // The inbox is a fold over the plane's index — no log was replayed to build it.
    const store = new FleetStore([new PlaneSource(alice.plane, () => alice.token())]);
    await store.refresh();
    const waiting: FleetRow[] = awaitingApproval(store.current.rows);
    assert.equal(waiting.length, 3);
    assert.deepEqual(waiting.map((r) => r.id).sort(), [...ids].sort());
    assert.ok(waiting.every((r) => r.pendingApprovals === 1));

    // Answering one from the inbox: open it, answer, and the turn continues.
    const target = ids[0]!;
    const box = transcriptOf();
    const fromInbox = await h.attach(alice, target, { hooks: { onEvent: box.onEvent } });
    const callId = box.state.entries.find((e) => e.kind === "approval")!.callId;
    await fromInbox.view.respondApproval(callId, "allow");
    await until(
      () => box.state.entries.some((e) => e.kind === "assistant" && e.text.startsWith("Ran shell")),
      5_000,
      "the turn to continue",
    );

    // A second answer, from another person: told who resolved it, and no second effect.
    const second = transcriptOf();
    const bobs = await h.attach(bob, target, { hooks: { onEvent: second.onEvent } });
    // Attaching resolves when the subscription is made, not when its replay has been
    // folded. Counting before the replay has caught up would read 0 and then see the
    // first turn's answer arrive, which looks exactly like the turn running twice —
    // so wait until this client has the answer that already happened.
    await until(
      () => second.state.entries.some((e) => e.kind === "assistant" && e.text.startsWith("Ran shell")),
      5_000,
      "the second client to catch up",
    );
    const before = second.state.entries.filter((e) => e.kind === "assistant").length;
    await bobs.view.respondApproval(callId, "deny");
    await until(
      () => second.state.entries.some((e) => e.kind === "approval" && e.resolvedBy === "alice@example.com"),
      5_000,
      "approval_resolved",
    );
    await sleep(100);
    assert.equal(
      second.state.entries.filter((e) => e.kind === "assistant").length,
      before,
      "the second answer ran the turn a second time",
    );
    const approval = second.state.entries.find((e) => e.kind === "approval") as Extract<Entry, { kind: "approval" }>;
    assert.equal(approval.decision, "allow", "the second answer changed the decision");

    await fromInbox.close();
    await bobs.close();
  });
});

describe("stage 1, done item 5: a pod token running out", () => {
  it("mints and refreshes on the open socket without interrupting a turn", async () => {
    // The warning comes two seconds in — during the turn below — and the token itself
    // is good for twenty. The gap is deliberately wide: what this test is about is that
    // a refresh happens on the open socket, not how close to `exp` it cuts it, and a
    // machine that stalls for a second should fail it for the first reason only.
    const h = await startHarness({
      worker: { sendAuthExpiring: true, expiringLeadMs: 18_000, deltaDelayMs: 30 },
      plane: { podTokenLifetime: 20 },
    });
    try {
      const auth = await h.signIn();
      const row = h.plane.seed("alice@example.com");
      const box = transcriptOf();
      const a = await h.attach(auth, row.id, { hooks: { onEvent: box.onEvent } });
      const firstToken = a.attachment?.token;

      // A turn long enough to still be running when the warning arrives.
      const long = "word ".repeat(120);
      const turn = a.view.prompt(long, 30_000);
      await until(() => h.worker.calls.some((c) => c.method === "auth.refresh"), 20_000, "auth.refresh");

      const result = await turn;
      assert.equal(result.endType.startsWith("agent_state") || result.endType === "agent_done", true);
      assert.ok(result.text.includes("word"), "the turn did not finish");

      // On the same socket: the pod never saw a second `initialize`.
      assert.equal(h.worker.calls.filter((c) => c.method === "initialize").length, 1);
      assert.notEqual(a.attachment?.token, firstToken, "the token was not replaced");
      assert.equal(a.status, "live");
      await a.close();
    } finally {
      await h.stop();
    }
  });

  it("reconnects from its cursor with no gap and no duplicate when refresh is disabled", async () => {
    // No warning is sent, so nothing is ever refreshed: the token simply runs out.
    const h = await startHarness({ worker: { sendAuthExpiring: false }, plane: { podTokenLifetime: 3 } });
    try {
      const auth = await h.signIn();
      const row = h.plane.seed("alice@example.com");

      const seqs: number[] = [];
      const a = await h.attach(auth, row.id, {
        hooks: {
          onEvent: (e) => {
            if ("seq" in e && typeof e.seq === "number") seqs.push(e.seq);
          },
        },
      });

      await a.view.send("before");
      await until(() => seqs.length >= 5, 5_000, "the first turn");
      await until(() => a.status === "reconnecting" || a.status === "live", 10_000, "the token to expire");
      await until(() => h.worker.calls.filter((c) => c.method === "initialize").length >= 2, 15_000, "a reconnection");
      await until(() => a.status === "live", 15_000, "the view to come back");

      // The token it came back with lasts three seconds too, so the send can race the
      // next expiry. Retrying is what a person pressing Send again would do, and what
      // is under test is the seq stream either way.
      await sendWhenConnected(a, "after");
      await until(() => seqs.length > 8, 15_000, "the second turn");

      // No gap and no duplicate across the boundary: one event per seq, in order.
      assert.deepEqual(seqs, [...seqs].sort((x, y) => x - y), `out of order: ${seqs}`);
      assert.equal(new Set(seqs).size, seqs.length, `duplicated seqs: ${seqs}`);
      assert.deepEqual(
        seqs,
        Array.from({ length: seqs.length }, (_, i) => i + 1),
        `a seq is missing: ${seqs}`,
      );
      await a.close();
    } finally {
      await h.stop();
    }
  });
});

describe("stage 1, done item 6: a large tool result", () => {
  let h: Harness;
  before(async () => {
    h = await startHarness();
  });
  after(() => h.stop());

  it("is a reference on load and is fetched by range only when expanded", async () => {
    const auth = await h.signIn();
    const row = h.plane.seed("alice@example.com");
    const box = transcriptOf();
    const a = await h.attach(auth, row.id, { hooks: { onEvent: box.onEvent } });

    await a.view.send("big: lorem");
    await until(() => box.state.entries.some((e) => e.kind === "tool" && e.ok !== undefined), 5_000, "the tool result");

    const tool = box.state.entries.find((e) => e.kind === "tool") as Extract<Entry, { kind: "tool" }>;
    assert.ok(isBlobRef(tool.content), "a result over 16 KiB was inlined");
    const ref = tool.content;
    assert.ok(ref.size > 16 * 1024);
    assert.ok(ref.preview && ref.preview.length <= 4096);

    // Loading the transcript fetched nothing.
    assert.equal(h.worker.calls.filter((c) => c.method === "blob.get").length, 0, "a blob was fetched on load");

    // Expanding it fetches by range, and keeps going until it has the whole thing —
    // the server caps each answer at 64 KiB and says so in the range it returns.
    const text = await a.view.blobText(ref.blob);
    const gets = h.worker.calls.filter((c) => c.method === "blob.get");
    assert.ok(gets.length > 1, "a capped blob was read in one call");
    assert.ok(gets.every((c) => Array.isArray(c.params["range"])), "a blob was fetched without a range");
    assert.equal(Buffer.byteLength(text), ref.size);
    assert.ok(text.startsWith("lorem\n"));

    // And a second expansion is the client's business, not the server's: nothing here
    // caches for it, so the count only ever grows with what the person asked for.
    assert.equal(rootState(box.state), "idle");
    await a.close();
  });
});
