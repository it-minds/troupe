// A session woken on a profile with no room waits for a place as a new one does (issue
// #1149): the plane answers `pending` with `retry_after_ms` and no endpoint, and the
// attachment says it is waiting and asks again with `token.mint` until there is a pod.

import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { SessionAttachment } from "../src/index.js";
import type { AttachStatus, Attachment } from "../src/index.js";
import { FakeWorker, encodeToken } from "./support/worker.js";

const SESSION = "s-waking";

const waiting: Attachment = {
  session_id: SESSION,
  epoch: 2,
  state: "pending",
  mode: "waiting",
  reason: "the profile is full and another worker is coming up",
  retry_after_ms: 1,
  endpoint: undefined as unknown as string,
  worker_id: undefined as unknown as string,
  role: "owner",
  token: null,
};

function placedOn(worker: FakeWorker): Attachment {
  return {
    session_id: SESSION,
    epoch: 2,
    state: "active",
    mode: "activate",
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

describe("a wake that waits for a place", () => {
  let worker: FakeWorker;

  before(async () => {
    worker = await FakeWorker.start({ workerId: "w-room" });
    worker.createSession(SESSION);
  });

  after(async () => {
    await worker.stop();
  });

  it("says it is waiting, in the plane's words, and asks again until the session is placed", async () => {
    const statuses: [AttachStatus, string | undefined][] = [];
    let mints = 0;

    const a = await SessionAttachment.open({
      sessionId: SESSION,
      mode: "activate",
      open: async () => waiting,
      mint: async () => (++mints < 2 ? waiting : placedOn(worker)),
      onStatus: (s, d) => statuses.push([s, d]),
    });

    try {
      assert.equal(a.status, "live");
      assert.equal(mints, 2);
      assert.deepEqual(
        statuses.filter(([s]) => s === "waiting"),
        [
          ["waiting", "the profile is full and another worker is coming up"],
          ["waiting", "the profile is full and another worker is coming up"],
        ],
      );
      assert.equal(a.attachment?.worker_id, "w-room");
    } finally {
      await a.close();
    }
  });

  it("stops asking once whoever opened it has gone", async () => {
    let mints = 0;
    let wanted = true;

    const opened = SessionAttachment.open({
      sessionId: SESSION,
      mode: "activate",
      open: async () => waiting,
      mint: async () => {
        mints += 1;
        return waiting;
      },
      alive: () => wanted,
    });
    wanted = false;

    await assert.rejects(opened, /stopped waiting for a place/);
    assert.equal(mints, 0);
  });
});
