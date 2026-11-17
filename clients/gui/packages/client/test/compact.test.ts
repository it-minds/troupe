// `session.compact` from the client (`/compact`): the session asks the daemon to compact
// its conversation now; the effect is `compacted` with `reason: "manual"` and the
// command's id, which the transcript says was asked for; a refusal is `conflict` with the
// daemon's sentence. The daemon is the fake the desktop app's tests use, over a real socket.

import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { DaemonClient, ErrorCodes, SessionView, TroupeRpcError } from "../src/index.js";
import { FakeDaemon } from "./support/daemon.js";

describe("session.compact", () => {
  let daemon: FakeDaemon;
  let client: DaemonClient;

  before(async () => {
    daemon = new FakeDaemon({ osUser: "ada" });
    await daemon.start();
    client = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
  });

  after(async () => {
    client.disconnect();
    await daemon.stop();
  });

  it("compacts now, and the event carries the command's id and says it was asked for", async () => {
    const session = daemon.seed("/home/ada/repo");
    const view = new SessionView(await client.connection(), session.id);
    await view.compact();

    const call = daemon.calls.find((c) => c.method === "session.compact")!;
    assert.equal(call.params["session_id"], session.id);
    const event = session.log.events.find((e) => e.type === "compacted")!;
    assert.equal(event.data["reason"], "manual");
    assert.equal(event.data["command_id"], call.params["command_id"]);
  });

  it("is refused as conflict, with the daemon's reason, while a turn runs", async () => {
    const session = daemon.seed("/home/ada/repo", { status: "thinking" });
    const view = new SessionView(await client.connection(), session.id);
    await assert.rejects(view.compact(), (e: unknown) => {
      assert.ok(e instanceof TroupeRpcError);
      assert.equal(e.code, ErrorCodes.conflict);
      assert.match(String(e.data?.["reason"]), /in the middle of a turn/);
      return true;
    });
    assert.equal(session.log.events.some((e) => e.type === "compacted"), false);
  });
});
