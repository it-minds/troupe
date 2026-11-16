// An artifact kept at the top of a person's own gallery (troupe #978): `artifact.keep {id,
// on}`, said as `kept` on each row. It is the person's, on the plane, so a second sign-in of
// theirs reads it back and another person's list does not show it; and the daemon forwards
// it, so the desktop app keeps one whether it asks the plane or this computer's daemon.

import assert from "node:assert/strict";
import { after, afterEach, before, beforeEach, describe, it } from "node:test";
import { ArtifactApi, DaemonClient, PlaneOwn } from "../src/index.js";
import type { AuthSession, TroupeRpcError } from "../src/index.js";
import { FakeDaemon } from "./support/daemon.js";
import { startHarness, type Harness } from "./support/harness.js";
import { artifact } from "./support/plane.js";

const ada = { subject: "ada@example.com", display_name: "Ada" };

function apiOf(auth: AuthSession): ArtifactApi {
  return new ArtifactApi((m, p) => auth.rpc(m, p));
}

const kept = async (api: ArtifactApi): Promise<string[]> => (await api.list()).artifacts.filter((a) => a.kept === true).map((a) => a.id);

describe("an artifact kept at the top, on the fake plane", () => {
  let h: Harness;

  before(async () => {
    h = await startHarness({ plane: { memberOf: { "ada@example.com": ["core"], "erin@example.com": ["core"] } } });
  });
  after(() => h.stop());

  beforeEach(() => {
    h.plane.artifacts.clear();
    h.plane.kept.clear();
    h.plane.artifacts.set("art-a", artifact("art-a", ada, { title: "Figures", visibility: "team:core", team: "core" }));
    h.plane.artifacts.set("art-b", artifact("art-b", ada, { title: "Runbook", visibility: "team:core", team: "core" }));
  });

  it("is kept and let go by the person, read back by another sign-in of theirs, and nobody else's", async () => {
    const erin = apiOf(await h.signIn({ subject: "erin@example.com" }));
    const answer = await erin.keep("art-b", true);
    assert.equal(answer.kept, true);
    assert.deepEqual(await kept(erin), ["art-b"]);

    // Another device of Erin's: a second sign-in, the same answer, since the plane keeps it.
    const again = apiOf(await h.signIn({ subject: "erin@example.com" }));
    assert.deepEqual(await kept(again), ["art-b"]);
    assert.equal((await again.get("art-b")).kept, true);

    const owner = apiOf(await h.signIn({ subject: "ada@example.com" }));
    assert.deepEqual(await kept(owner), [], "Ada's gallery does not show what Erin keeps");

    assert.equal((await again.keep("art-b", false)).kept, false);
    assert.deepEqual(await kept(erin), []);
  });

  it("is refused for one the person may not open, and the plane-direct client asks it as the daemon does", async () => {
    h.plane.artifacts.set("art-p", artifact("art-p", ada, { title: "Ada's draft", visibility: "private" }));
    const erin = await h.signIn({ subject: "erin@example.com" });
    const theirs = new PlaneOwn((m, p) => erin.rpc(m, p), h.plane.baseUrl);
    await assert.rejects(theirs.keepArtifact("art-p", true), (e: TroupeRpcError) => e.code === -32005);

    assert.equal((await theirs.keepArtifact("art-a", true)).kept, true);
    assert.deepEqual(await kept(apiOf(erin)), ["art-a"]);
  });
});

describe("an artifact kept at the top, through the fake daemon", () => {
  let daemon: FakeDaemon;
  let client: DaemonClient;

  beforeEach(async () => {
    daemon = new FakeDaemon({ osUser: "ada" });
    await daemon.start();
    daemon.artifacts = [{ id: "art-a", title: "Figures", kind: "html", visibility: "organisation", version: 1, mine: false, owner: ada }];
    client = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
  });

  afterEach(async () => {
    client.disconnect();
    await daemon.stop();
  });

  it("forwards artifact.keep with its id and on, and the list says kept after", async () => {
    assert.equal((await client.keepArtifact("art-a", true)).kept, true);
    const call = daemon.artifactCalls.find((c) => c.method === "artifact.keep");
    assert.equal(call?.params["id"], "art-a");
    assert.equal(call?.params["on"], true);
    assert.equal((await client.artifacts({})).artifacts[0]?.kept, true);
    assert.equal((await client.keepArtifact("art-a", false)).kept, false);
  });
});
