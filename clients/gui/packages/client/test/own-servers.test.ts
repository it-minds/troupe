// The person's own signed-in servers, offered to a session on a pod (PROTOCOL.md §8;
// troupe Decision 748).
//
// A fake pod and a fake daemon on real sockets. The pod asks the client that registered a
// tool to run it, the client asks the daemon, and the daemon calls the server with the
// sign-in it keeps. What is asserted is the traffic: what the pod was sent, and what the
// daemon sent the server.

import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { DaemonClient, ServerOffer, SessionAttachment } from "../src/index.js";
import type { Attachment, OfferAsk, OfferState } from "../src/index.js";
import { FakeDaemon } from "./support/daemon.js";
import { FakeWorker, encodeToken } from "./support/worker.js";

const SESSION = "s-team";

function attachmentFor(worker: FakeWorker, mode: string, scopes = ["observe", "control", "admin"]): Attachment {
  return {
    session_id: SESSION,
    mode,
    endpoint: worker.endpoint,
    worker_id: worker.workerId,
    role: "owner",
    token: encodeToken({ sub: "alice@example.com", name: "Alice", session_id: SESSION, role: "owner", scopes, aud: worker.workerId, exp: Math.floor(Date.now() / 1000) + 900 }),
  };
}

async function until(what: string, ok: () => boolean, timeoutMs = 5_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!ok()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 10));
  }
}

let worker: FakeWorker;
let daemon: FakeDaemon;
let client: DaemonClient;
let attachment: SessionAttachment | null = null;
let asks: OfferAsk[];
let states: OfferState[];

beforeEach(async () => {
  worker = await FakeWorker.start({ workerId: "w-team" });
  worker.createSession(SESSION);
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  daemon.servers.push(
    { name: "notes", layer: "user", source: "/home/ada/.config/troupe/mcp.json", url: "https://mcp.example.test/notes", oauth: { client_id: "troupe-test-client" } },
    { name: "wiki", layer: "user", source: "/home/ada/.config/troupe/mcp.json", url: "https://mcp.example.test/wiki", oauth: { client_id: "troupe-test-client" } },
    { name: "fs", layer: "user", source: "/home/ada/.config/troupe/mcp.json", command: "npx", args: ["fs"] },
  );
  daemon.finishSignIn("notes");
  client = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
  asks = [];
  states = [];
});

afterEach(async () => {
  await attachment?.close();
  attachment = null;
  client.disconnect();
  await daemon.stop();
  await worker.stop();
});

async function attach(opts: { allow?: boolean; scopes?: string[] } = {}): Promise<SessionAttachment> {
  const offer = new ServerOffer(client, {
    sessionId: SESSION,
    confirmedBy: "alice@example.com",
    confirm: async (ask) => {
      asks.push(ask);
      return opts.allow ?? true;
    },
    onState: (s) => states.push(s),
  });
  attachment = await SessionAttachment.open({
    sessionId: SESSION,
    mode: "activate",
    open: async (mode) => attachmentFor(worker, mode, opts.scopes),
    mint: async () => attachmentFor(worker, "activate", opts.scopes),
    backoffMs: [10, 20, 40],
    onToolInvoke: offer.invoke,
    onLive: (conn) => void offer.offer(conn),
  });
  return attachment;
}

function settled(state: OfferState["state"], times = 1): () => boolean {
  return () => states.filter((s) => s.state === state).length >= times;
}

/** Drop the socket the way a network does, and wait for the attachment to be back on another. */
async function drop(a: SessionAttachment): Promise<void> {
  const doomed = a.conn!;
  (doomed as unknown as { ws: { close(code: number, reason: string): void } }).ws.close(4000, "dropped");
  await until("the socket to come back", () => Boolean(a.conn && a.conn !== doomed && a.status === "live"));
}

describe("the person's own servers, offered to a pod session", () => {
  it("are called by the person's daemon when the pod's agent calls one, and no token reaches the pod", async () => {
    await attach();
    await until("the offer", settled("offered"));

    // Asked once, in the session's words, about the signed-in server's tools alone.
    assert.equal(asks.length, 1);
    assert.deepEqual(asks[0]!.tools, ["notes.search"]);
    assert.deepEqual(asks[0]!.servers, ["notes"]);
    assert.match(asks[0]!.prompt, /notes\.search/);
    assert.deepEqual([...worker.tools.keys()], [`${SESSION}/client.notes.search`]);

    // The pod's agent calls it; the daemon makes the call with the person's sign-in.
    const answer = await worker.invokeTool(SESSION, "client.notes.search", { topic: "the plan" }, "call-1");
    assert.deepEqual(answer, { content: 'search on notes for ada@example.test: {"topic":"the plan"}' });
    const token = daemon.signInTokens["notes"]!;
    assert.deepEqual(daemon.serverCalls, [{ server: "notes", tool: "search", arguments: { topic: "the plan" }, authorization: `Bearer ${token}` }]);
    const call = daemon.calls.find((c) => c.method === "mcp.call")!;
    assert.equal(call.params["command_id"], `call-${SESSION}-call-1`);

    // What the pod was sent: the registration and the answer, and nothing of the sign-in.
    const registration = worker.calls.filter((c) => c.method === "tools.register").at(-1)!;
    assert.deepEqual(registration.params["tools"], [
      { name: "notes.search", description: "Search my notes.", schema: { type: "object", properties: { topic: { type: "string" } } } },
    ]);
    const consent = registration.params["consent"] as { challenge: string; confirmed_by: string };
    assert.deepEqual(Object.keys(consent).sort(), ["challenge", "confirmed_by"]);
    assert.equal(consent.confirmed_by, "alice@example.com");
    assert.ok(worker.frames.some((f) => f.includes('search on notes for ada@example.test')), "the answer reached the pod");
    for (const frame of worker.frames) {
      assert.ok(!frame.includes(token), `a frame carried the token: ${frame}`);
      assert.ok(!/bearer|access_token|refresh_token|authorization/i.test(frame), `a frame carried something token-shaped: ${frame}`);
    }
  });

  it("are offered again on a socket that comes back, without asking twice, and a call sent again is made once", async () => {
    const a = await attach();
    await until("the offer", settled("offered"));
    await worker.invokeTool(SESSION, "client.notes.search", { topic: "first" }, "call-7");

    await drop(a);
    await until("the offer on the new socket", settled("offered", 2));
    assert.equal(asks.length, 1, "the person was asked again for what they had allowed");
    assert.deepEqual([...worker.tools.keys()], [`${SESSION}/client.notes.search`]);

    // The pod sends a call again after the drop, as it does for one its client left
    // mid-way; the daemon answers it from the first and calls the server once.
    const again = await worker.invokeTool(SESSION, "client.notes.search", { topic: "first" }, "call-7");
    assert.deepEqual(again, { content: 'search on notes for ada@example.test: {"topic":"first"}' });
    assert.equal(daemon.serverCalls.length, 1);
  });

  it("are not registered when the person says no, and not asked about again on the next socket", async () => {
    const a = await attach({ allow: false });
    await until("the refusal", settled("declined"));
    assert.equal(worker.tools.size, 0);

    await drop(a);
    await until("the next socket's answer", settled("declined", 2));
    assert.equal(asks.length, 1);
    assert.equal(worker.calls.filter((c) => c.method === "tools.register").length, 1, "only the first socket asked for the challenge");
  });

  it("are not offered by somebody who may only read the session", async () => {
    await attach({ scopes: ["observe"] });
    await until("the answer", settled("none"));
    assert.equal(asks.length, 0);
    assert.equal(worker.calls.filter((c) => c.method === "tools.register").length, 0);
  });
});
