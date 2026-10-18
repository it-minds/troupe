// A call that never hears its answer gives up (troupe #739's follow-up, D131): every call on
// a connection has a stated wait, a method known to take longer has its own, a caller may
// name another for one call, and a call past its wait rejects with a sentence that says
// what was not answered, for how long, and that it may still have been done. An answer
// that comes after is not taken.

import assert from "node:assert/strict";
import { after, afterEach, before, describe, it } from "node:test";
import { DaemonClient, TroupeCallTimedOut, callTimeout, callTimeouts, waitWords } from "../src/index.js";
import type { DaemonEndpoint } from "../src/index.js";
import { FakeDaemon } from "./support/daemon.js";

const endpointOf = (daemon: FakeDaemon): DaemonEndpoint => ({ transport: "ws", port: daemon.port, token: daemon.token });

describe("the wait each call has", () => {
  it("is stated: one for every call, longer for the methods known to take longer", () => {
    assert.equal(callTimeout("config.set"), callTimeouts.defaultMs);
    assert.equal(callTimeouts.defaultMs, 60_000);
    assert.equal(callTimeout("session.create"), 180_000);
    assert.equal(callTimeout("session.erase"), 300_000);
    assert.equal(waitWords(60_000), "60 seconds");
    assert.equal(waitWords(180_000), "3 minutes");
    assert.equal(waitWords(400), "1 second");
  });
});

// Not about waiting, but about what two calls send (D50): the shapes the daemon reads.
describe("offering tools from the daemon client", () => {
  it("sends consent as the challenge answered, and names the tools to take back as tools", async () => {
    const daemon = new FakeDaemon();
    await daemon.start();
    const client = new DaemonClient(endpointOf(daemon));
    try {
      await client.registerTools("s-1", [], { challenge: "n-1", confirmed_by: "ada" }).catch(() => undefined);
      await client.unregisterTools("s-1", ["notes.search"]).catch(() => undefined);
      const sent = (method: string) => daemon.calls.find((c) => c.method === method)?.params;
      assert.deepEqual(sent("tools.register")?.["consent"], { challenge: "n-1", confirmed_by: "ada" });
      assert.deepEqual(sent("tools.unregister")?.["tools"], ["notes.search"]);
      assert.equal(sent("tools.unregister")?.["names"], undefined);
    } finally {
      client.disconnect();
      await daemon.stop();
    }
  });
});

describe("a call whose answer never comes", () => {
  let daemon: FakeDaemon;
  let client: DaemonClient;
  const defaultMs = callTimeouts.defaultMs;

  before(async () => {
    daemon = new FakeDaemon();
    await daemon.start();
    client = new DaemonClient(endpointOf(daemon));
  });

  afterEach(() => {
    callTimeouts.defaultMs = defaultMs;
  });

  after(async () => {
    client.disconnect();
    await daemon.stop();
  });

  it("rejects past the call's own wait with a sentence", async () => {
    daemon.loseReply["config.set"] = "hold";
    const started = Date.now();
    await assert.rejects(client.setSetting("max_turns", 9, "user", undefined, { timeoutMs: 300 }), (e: unknown) => {
      assert.ok(e instanceof TroupeCallTimedOut);
      assert.equal(e.method, "config.set");
      assert.equal(e.message, "No answer to config.set in 1 second. It may still have been done; look again before trying once more.");
      return true;
    });
    assert.ok(Date.now() - started < 5_000);

    // The connection carries on.
    assert.ok(await client.identity());
  });

  it("rejects past the stated wait when the call names none", async () => {
    callTimeouts.defaultMs = 300;
    daemon.loseReply["setup.answer"] = "hold";
    await assert.rejects(client.answerSetup("where", { choice: "local" }), TroupeCallTimedOut);
  });

  it("is not taken when it comes late, and an answer in time clears the wait", async () => {
    daemon.delayMs["identity.get"] = 600;
    callTimeouts.defaultMs = 300;
    await assert.rejects(client.identity(), TroupeCallTimedOut);
    delete daemon.delayMs["identity.get"];
    // The late answer arrives and is dropped; this one is the one taken.
    await new Promise((r) => setTimeout(r, 400));
    callTimeouts.defaultMs = defaultMs;
    const identity = await client.identity();
    assert.ok(identity);
  });
});
