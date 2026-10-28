// A memory saved as entries on a plane from before them (0.28 and earlier), which reads a
// document as `text` alone and refuses `entries` with `invalid_params` naming `text` as
// missing: the client sends the same call again with the entries rendered as text, for the
// person's own and for a level they administer, saves and previews alike. Any other refusal
// is shown as it is and not sent again.

import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { DaemonClient, TroupeRpcError } from "../src/index.js";
import { FakeDaemon } from "./support/daemon.js";

const TONE = { topic: "Tone", body: "Short answers." };
const DATES = { topic: "Dates", body: "ISO dates." };

describe("a memory saved as entries on a plane that reads only text", () => {
  let daemon: FakeDaemon;
  let client: DaemonClient;

  beforeEach(async () => {
    daemon = new FakeDaemon({ osUser: "ada" });
    await daemon.start();
    daemon.own = { version: 2, text: "## Tone\n\nShort answers." };
    daemon.ownAbove = [{ scope: "team", name: "core", version: 3, text: "## Dates\n\nISO dates." }];
    daemon.memoryRoles = { platform_admin: false, team_admin: ["core"] };
    daemon.planeReadsOnlyText = true;
    client = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
  });

  afterEach(async () => {
    client.disconnect();
    await daemon.stop();
  });

  it("saves the person's own as text, over the same version", async () => {
    const saved = await client.putOwnMemoryEntries([TONE, { topic: "Language", body: "British English." }], 2);
    assert.equal(saved.changed, true);
    assert.equal(saved.user.version, 3);
    assert.equal(daemon.ownPuts.length, 2);
    assert.deepEqual(daemon.ownPuts[0]!["entries"], [TONE, { topic: "Language", body: "British English." }]);
    assert.deepEqual(daemon.ownPuts[1], { command_id: daemon.ownPuts[1]!["command_id"], text: "## Tone\n\nShort answers.\n\n## Language\n\nBritish English.", version: 2 });
    assert.equal(daemon.own?.text, "## Tone\n\nShort answers.\n\n## Language\n\nBritish English.");
  });

  it("saves and previews a level the person administers as text", async () => {
    const preview = await client.previewLevelMemory("team", "core", { entries: [DATES, TONE] });
    assert.equal(preview.unchanged, false);
    const saved = await client.putLevelMemory("team", "core", { entries: [DATES, TONE] }, 3);
    assert.equal(saved.document?.version, 4);
    assert.deepEqual(
      daemon.levelCalls.map((c) => [c["method"], "entries" in c ? "entries" : c["text"]]),
      [
        ["admin.memory.preview", "entries"],
        ["admin.memory.preview", "## Dates\n\nISO dates.\n\n## Tone\n\nShort answers."],
        ["admin.memory.put", "entries"],
        ["admin.memory.put", "## Dates\n\nISO dates.\n\n## Tone\n\nShort answers."],
      ],
    );
    assert.equal(daemon.ownAbove[0]?.text, "## Dates\n\nISO dates.\n\n## Tone\n\nShort answers.");
  });

  it("sends a save as text once, and any other refusal is shown as it is", async () => {
    await client.putOwnMemory("## Tone\n\nLonger answers.", 2);
    assert.equal(daemon.ownPuts.length, 1);

    daemon.planeReadsOnlyText = false;
    daemon.memoryRefusal = { field: "text", reason: "a memory document holds at most 8192 bytes" };
    await assert.rejects(client.putOwnMemoryEntries([TONE], 3), (e: unknown) => e instanceof TroupeRpcError && e.data?.["reason"] === "a memory document holds at most 8192 bytes");
    await assert.rejects(client.putLevelMemory("team", "core", { entries: [DATES] }, 3), (e: unknown) => e instanceof TroupeRpcError && e.data?.["field"] === "text");
    assert.equal(daemon.ownPuts.length, 2);
    assert.equal(daemon.levelCalls.length, 1);
  });
});
