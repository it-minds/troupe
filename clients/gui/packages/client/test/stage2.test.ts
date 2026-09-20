// Stage 2's done items, as far as a client can prove them.
//
// The three that are about the daemon's own behaviour — the `ws` entry in `daemon.json`,
// the refused origin, the actor after `identity.link` — are proved in the server's
// repository, where the daemon is, by `Troupe.Gateway.LoopbackTest`. What is proved here
// is the half that is this repository's: that the client multiplexes several sessions
// over one socket, that one list contains both kinds and each says which it is, and that
// the local-only commands go where they should.

import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { DaemonClient, DaemonSource, FleetStore, filterRows, rowFromDaemon } from "../src/index.js";
import type { DaemonEndpoint, FleetRow, FleetSource } from "../src/index.js";
import { FakeDaemon } from "./support/daemon.js";

describe("stage 2, done item 2: one list, two kinds, each labelled", () => {
  let daemon: FakeDaemon;
  let client: DaemonClient;

  before(async () => {
    daemon = new FakeDaemon();
    await daemon.start();
    client = new DaemonClient(endpointOf(daemon));
    daemon.seed("/home/ada/project");
    daemon.seed("/home/ada/other");
  });

  after(async () => {
    client.disconnect();
    await daemon.stop();
  });

  it("merges the daemon's sessions with a plane's, and the kind survives the merge", async () => {
    // A plane source that answers with one team session, which is all the fleet store
    // needs to know about it.
    const plane: FleetSource = {
      id: "plane",
      kind: "team",
      list: async () => [teamRow("t-1")],
    };

    const store = new FleetStore([plane, new DaemonSource(client)]);
    await store.refresh();

    const rows = store.current.rows;
    assert.equal(rows.length, 3);
    assert.equal(rows.filter((r) => r.kind === "team").length, 1);
    assert.equal(rows.filter((r) => r.kind === "local").length, 2);

    // The filter the list's "where it runs" control uses.
    assert.equal(filterRows(rows, { kind: "local" }).length, 2);
    assert.equal(filterRows(rows, { kind: "team" }).length, 1);

    // A local row's title is its directory: nobody names the work in their own checkout.
    const local = rows.find((r) => r.kind === "local");
    assert.equal(local?.title, "/home/ada/other");
    assert.equal(local?.source, "daemon");
  });

  it("keeps the local sessions when the plane stops answering", async () => {
    const failing: FleetSource = {
      id: "plane",
      kind: "team",
      list: async () => {
        throw new Error("the plane is not answering");
      },
    };

    const store = new FleetStore([failing, new DaemonSource(client)]);
    await store.refresh();

    assert.equal(store.current.rows.length, 2);
    assert.match(store.current.sources["plane"]?.error ?? "", /not answering/);
    assert.equal(store.current.sources["daemon"]?.error, null);
  });

  it("reports a daemon's whole-unit cost as micros, the way the plane reports it", () => {
    const row = rowFromDaemon({
      id: "s-9",
      workspace: "/w",
      branch: null,
      profile: "build",
      state: "active",
      status: "idle",
      cost: 0.25,
      created_at: null,
      last_active_at: null,
    });
    assert.equal(row.costMicros, 250_000);
  });
});

describe("stage 2: several sessions on one socket", () => {
  let daemon: FakeDaemon;
  let client: DaemonClient;

  before(async () => {
    daemon = new FakeDaemon();
    await daemon.start();
    client = new DaemonClient(endpointOf(daemon));
  });

  after(async () => {
    client.disconnect();
    await daemon.stop();
  });

  it("routes each session's events to its own view, and opens the socket exactly once", async () => {
    const first = daemon.seed("/home/ada/one");
    const second = daemon.seed("/home/ada/two");

    const heard: Record<string, string[]> = { [first.id]: [], [second.id]: [] };
    const a = await client.open(first.id, { onEvent: (e) => heard[first.id]!.push(e.type) });
    const b = await client.open(second.id, { onEvent: (e) => heard[second.id]!.push(e.type) });

    // One socket. Two `initialize`s would mean the multiplexer is not one.
    assert.equal(daemon.calls.filter((c) => c.method === "initialize").length, 1);

    daemon.say(first.id, "for the first");
    daemon.say(second.id, "for the second");
    await settle();

    assert.deepEqual(heard[first.id], ["session_created", "llm_response"]);
    assert.deepEqual(heard[second.id], ["session_created", "llm_response"]);

    // Each view folded only its own, and the cursors are independent.
    assert.equal(a.lastSeq, 2);
    assert.equal(b.lastSeq, 2);
  });

  it("opening the same session twice at once makes one view and one subscription", async () => {
    const fourth = daemon.seed("/home/ada/four");
    const before = daemon.calls.filter((c) => c.method === "subscribe").length;

    const heard: string[] = [];
    const [a, b] = await Promise.all([
      client.open(fourth.id, { onEvent: (e) => heard.push(e.type) }),
      client.open(fourth.id),
    ]);

    assert.equal(a, b, "both callers got the same view");
    assert.equal(daemon.calls.filter((c) => c.method === "subscribe").length, before + 1);

    // And the hooks the first caller registered are the ones that fire.
    daemon.say(fourth.id, "once");
    await settle();
    assert.deepEqual(heard, ["session_created", "llm_response"]);
  });

  it("a session two callers hold is let go by the last of them, and a joiner hears the replay", async () => {
    const session = daemon.seed("/home/ada/shared");
    daemon.say(session.id, "already said");

    const first = await client.open(session.id);
    const second = await client.open(session.id);
    assert.equal(first, second, "one view for one session");
    assert.equal(client.holdersOf(session.id), 2);

    // The first opener leaves. The second is still reading.
    await client.close(session.id);
    assert.equal(client.holdersOf(session.id), 1);

    const heard: string[] = [];
    const stop = second.listen((e) => {
      if ("seq" in e && e.type === "llm_response") heard.push(String(e.seq));
    });
    const said = daemon.say(session.id, "still here");
    await second.waitFor((e) => "seq" in e && e.seq === said.seq, 5_000, "the second opener's event");
    assert.equal(heard.length, 1, "the surviving holder still receives events");
    stop();

    await client.close(session.id);
    assert.equal(client.holdersOf(session.id), 0);
    // A fresh open after the last close starts a new subscription from the beginning.
    const again = await client.open(session.id);
    assert.notEqual(again, first);
    await client.close(session.id);
  });

  it("closing one session leaves the other's socket alone", async () => {
    const third = daemon.seed("/home/ada/three");
    const view = await client.open(third.id, {});
    await client.close(third.id);

    daemon.say(third.id, "nobody is listening");
    await settle();

    assert.equal(view.lastSeq, 1, "the closed view stopped folding");
    assert.equal(client.connected, true, "the socket is still up for the others");
  });
});

describe("stage 2, done item 3: who the daemon records", () => {
  let daemon: FakeDaemon;
  let client: DaemonClient;

  before(async () => {
    daemon = new FakeDaemon({ osUser: "ada" });
    await daemon.start();
    client = new DaemonClient(endpointOf(daemon));
  });

  after(async () => {
    client.disconnect();
    await daemon.stop();
  });

  it("goes from the machine's login to the person, and back", async () => {
    assert.deepEqual(await client.identity(), { linked: false });

    const linked = await client.linkIdentity({
      subject: "ada@example.test",
      display_name: "Ada",
      plane_url: "https://troupe.example",
    });
    assert.equal(linked.linked, true);
    assert.equal(linked.subject, "ada@example.test");

    // What the link is *for*: the actor on everything after it.
    const session = daemon.seed("/home/ada/project");
    const view = await client.open(session.id, {});
    await view.send("hello");
    await settle();

    const accepted = session.log.events.find((e) => e.type === "input_accepted");
    assert.equal(accepted?.actor.subject, "ada@example.test");

    // And the row it lists carries the owner, which is what a plane would bill.
    const rows = await new DaemonSource(client).list();
    assert.equal(rows[0]?.owner, "ada@example.test");

    assert.deepEqual(await client.unlinkIdentity(), { linked: false });
  });

  it("refuses to link nobody", async () => {
    await assert.rejects(() => client.linkIdentity({ subject: "" }), /invalid_params|subject/);
  });
});

describe("stage 2: the commands only a local session has", () => {
  let daemon: FakeDaemon;
  let client: DaemonClient;

  before(async () => {
    daemon = new FakeDaemon();
    await daemon.start();
    client = new DaemonClient(endpointOf(daemon));
  });

  after(async () => {
    client.disconnect();
    await daemon.stop();
  });

  it("creates a session in a directory, and watch mode follows the workspace", async () => {
    const created = await client.createSession({ workspace: "/home/ada/watched", worktree: "auto" });
    assert.ok(created.session_id);

    const on = await client.setWatch("/home/ada/watched", true);
    assert.equal(on.enabled, true);

    const recent = await client.recentWorkspaces();
    assert.ok(recent.workspaces.some((w) => w.path === "/home/ada/watched"));
  });

  it("a daemon that cannot seal does not claim it can", async () => {
    await client.connection();
    assert.equal(client.supportsPrivateSessions, false);

    const sealing = new FakeDaemon({ capabilities: { blobs: true, private_sessions: true } });
    await sealing.start();
    const other = new DaemonClient(endpointOf(sealing));
    await other.connection();
    assert.equal(other.supportsPrivateSessions, true);
    other.disconnect();
    await sealing.stop();
  });
});

function endpointOf(daemon: FakeDaemon): DaemonEndpoint {
  return { transport: "ws", port: daemon.port, token: daemon.token };
}

function teamRow(id: string): FleetRow {
  return {
    id,
    kind: "team",
    source: "plane",
    title: "On the platform",
    profile: "build",
    owner: "ada@example.test",
    state: "active",
    status: "idle",
    doneReason: null,
    pendingApprovals: 0,
    costMicros: 1_000,
    lastActiveAt: new Date().toISOString(),
    pinned: false,
    yourRole: "owner",
    origin: null,
    reviewedBy: null,
    sync: null,
    raw: {},
  };
}

/** Events are pushed, so a test that asserts on them has to let the socket drain. */
function settle(ms = 60): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

describe("phase 4: a question on a local session is answered where the daemon listens", () => {
  let daemon: FakeDaemon;
  let client: DaemonClient;

  before(async () => {
    daemon = new FakeDaemon();
    await daemon.start();
    client = new DaemonClient(endpointOf(daemon));
  });

  after(async () => {
    client.disconnect();
    await daemon.stop();
  });

  it("sends question.answer with the session and call ids, and the answer comes back folded", async () => {
    const session = daemon.seed("/home/ada/project");
    const view = await client.open(session.id);
    daemon.ask(session.id, { call_id: "budget-1", question: "turns 40/40 (100%) — continue?", options: [{ label: "allow" }, { label: "always" }, { label: "deny" }] });

    await view.waitFor((e) => "seq" in e && e.type === "question_asked", 5_000, "question_asked");
    // The waiter first: the daemon writes the answer before it acknowledges the command.
    const answered = view.waitFor((e) => "seq" in e && e.type === "question_answered", 5_000, "question_answered");
    await view.answerQuestion("budget-1", "allow");

    const sent = daemon.calls.find((c) => c.method === "question.answer");
    assert.ok(sent, "the daemon heard question.answer");
    assert.equal(sent!.params["session_id"], session.id);
    assert.equal(sent!.params["call_id"], "budget-1");
    assert.equal(sent!.params["text"], "allow");

    assert.equal(((await answered) as { data: Record<string, unknown> }).data["text"], "allow");
  });
});
