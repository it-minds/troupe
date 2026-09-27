// A session that moves to another pod (PROTOCOL.md §6, "A session that moves").
//
// Two fake pods and a plane that is only a function: where the session is. The first
// pod stays up after the session has left it and answers `not_found` for it, which is
// what a pod that a drain, a fence or the idle timeout took the session from does.

import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { SessionAttachment } from "../src/index.js";
import type { Attachment } from "../src/index.js";
import { FakeWorker, encodeToken } from "./support/worker.js";

const SESSION = "s-moving";

function attachmentFor(worker: FakeWorker, mode: string): Attachment {
  return {
    session_id: SESSION,
    mode,
    endpoint: worker.endpoint,
    worker_id: worker.workerId,
    role: "owner",
    token: encodeToken({
      sub: "alice@example.com",
      name: "Alice",
      session_id: SESSION,
      role: "owner",
      scopes: ["observe", "control", "admin"],
      aud: worker.workerId,
      exp: Math.floor(Date.now() / 1000) + 900,
    }),
  };
}

function sends(...workers: FakeWorker[]): unknown[] {
  return workers.flatMap((w) => w.calls.filter((c) => c.method === "input.send").map((c) => c.params["command_id"]));
}

describe("a session that moves to another pod", () => {
  let first: FakeWorker;
  let second: FakeWorker;

  before(async () => {
    first = await FakeWorker.start({ workerId: "w-first" });
    second = await FakeWorker.start({ workerId: "w-second" });
  });

  after(async () => {
    await first.stop();
    await second.stop();
  });

  it("is reopened through the plane when its pod says it is not there, and the command runs once, with the same id", async () => {
    first.createSession(SESSION);
    second.createSession(SESSION);
    let holder = first;
    const opens: string[] = [];

    const a = await SessionAttachment.open({
      sessionId: SESSION,
      mode: "activate",
      open: async (mode) => {
        opens.push(mode);
        return attachmentFor(holder, mode);
      },
      mint: async () => attachmentFor(holder, "activate"),
      backoffMs: [10, 20, 40],
    });

    try {
      // Placed on the second pod; the first is still up and no longer has it.
      first.sessions.delete(SESSION);
      holder = second;

      const commandId = "c-moved-1";
      await a.retrying(() => a.view.send("still there?", commandId));

      assert.deepEqual(sends(first, second), [commandId, commandId]);
      assert.deepEqual(sends(second), [commandId]);
      assert.deepEqual(opens, ["activate", "activate"]);
      assert.equal(a.status, "live");
      assert.equal(a.attachment?.worker_id, "w-second");

      // The socket left behind closes without starting another reconnection.
      await new Promise((r) => setTimeout(r, 100));
      assert.equal(opens.length, 2);
      assert.equal(first.connectionCount, 0);
    } finally {
      await a.close();
    }
  });

  it("follows a dropped socket in read mode, which wakes nothing, and activates only for a command", async () => {
    first.createSession(SESSION);
    first.calls.length = 0;
    second.calls.length = 0;
    let holder = first;
    const opens: string[] = [];

    const a = await SessionAttachment.open({
      sessionId: SESSION,
      mode: "activate",
      open: async (mode) => {
        opens.push(mode);
        return attachmentFor(holder, mode);
      },
      mint: async () => attachmentFor(holder, "activate"),
      backoffMs: [10, 20, 40],
    });

    try {
      // The socket goes, and nothing the person did asked for the session to run: the
      // plane is asked where it is, in read mode (PROTOCOL.md §6), so a session that had
      // gone to sleep stays asleep.
      const doomed = a.conn!;
      (doomed as unknown as { ws: { close(code: number, reason: string): void } }).ws.close(4000, "dropped");
      const deadline = Date.now() + 5_000;
      while (!(a.conn && a.conn !== doomed && a.status === "live") && Date.now() < deadline) await new Promise((r) => setTimeout(r, 10));
      assert.equal(a.status, "live");
      assert.deepEqual(opens, ["activate", "read"]);

      // A command is what activates: the pod that only serves its history refuses it, and
      // it is followed in activate mode and sent once more.
      first.sessions.delete(SESSION);
      holder = second;
      await a.retrying(() => a.view.send("wake up", "c-moved-3"));
      assert.deepEqual(opens, ["activate", "read", "activate"]);
      assert.deepEqual(sends(second), ["c-moved-3"]);
    } finally {
      await a.close();
      second.sessions.delete(SESSION);
    }
  });

  it("a session that cannot be reached again fails the command with the pod's answer, sent once", async () => {
    first.createSession(SESSION);
    first.calls.length = 0;
    second.calls.length = 0;
    const opens: string[] = [];

    const a = await SessionAttachment.open({
      sessionId: SESSION,
      mode: "activate",
      open: async (mode) => {
        opens.push(mode);
        return attachmentFor(first, mode);
      },
      mint: async () => attachmentFor(first, "activate"),
      backoffMs: [10, 20, 40],
    });

    try {
      // Nobody has it: the plane keeps naming the first pod, which keeps refusing.
      first.sessions.delete(SESSION);
      await assert.rejects(
        a.retrying(() => a.view.send("anyone?", "c-moved-2")),
        (e: Error) => e.message.includes("not_found"),
      );
      assert.deepEqual(sends(first), ["c-moved-2"]);
      assert.equal(a.status, "failed");
      // The first open, and one for each step of the backoff.
      assert.equal(opens.length, 1 + 3);
    } finally {
      await a.close();
    }
  });
});
