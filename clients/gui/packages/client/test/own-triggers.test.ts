// A person's own triggers (troupe #1235): the words both apps say them in, the methods the
// client asks by name, whether a plane has them, and the fake plane answering as the real
// one does: the owner's own switched off, on and removed, anybody else's refused.

import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import {
  PlaneClient,
  TroupeRpcError,
  knowsOwnTriggers,
  lastRunWords,
  ownTriggerRefusal,
  ownTriggerState,
  planeKnowsOwnTriggers,
  proposalTriggerLine,
  removeConfirm,
  triggerOfProposal,
  utcWords,
} from "../src/index.js";
import type { OwnTrigger } from "../src/index.js";
import { FakeIdp } from "./support/idp.js";
import { nextCronRun } from "./support/ownTriggers.js";
import { FakePlane } from "./support/plane.js";
import { FakeWorker } from "./support/worker.js";

const own: OwnTrigger = {
  id: "trg-1",
  team: "core",
  name: "rerun-weekly-numbers",
  principal: "svc:core/own-ada",
  enabled: true,
  source: { kind: "schedule", cron: "0 6 * * 1" },
  cron: "0 6 * * 1",
  next_run_at: "2026-11-30T06:00:00Z",
  last_run: { fired_at: "2026-11-23T06:00:00Z", state: "done", session_id: "s-run" },
  budget_micros: 1_000_000,
  profile: "dev",
  session_id: "s-1",
  artifact_id: "art-1",
};

describe("a person's own triggers, in words", () => {
  it("say whether each is on, when it runs next and how its last run went, in UTC", () => {
    assert.equal(utcWords("2026-11-30T06:00:00Z"), "Mon 30 Nov, 06:00 UTC");
    assert.equal(ownTriggerState(own), "On, every Monday at 06:00 UTC; next Mon 30 Nov, 06:00 UTC");
    assert.equal(ownTriggerState({ ...own, enabled: false, next_run_at: null }), "Off: it does not run until you switch it on");
    assert.equal(lastRunWords(own), "Last ran Mon 23 Nov, 06:00 UTC: finished");
    assert.equal(lastRunWords({ last_run: { fired_at: "2026-11-23T06:00:00Z", state: "skipped", session_id: null, reason: "one at a time" } }), "Last ran Mon 23 Nov, 06:00 UTC: skipped, one at a time");
    assert.equal(lastRunWords({ last_run: null }), "Not run yet");
    assert.match(removeConfirm(own), /^Remove “rerun-weekly-numbers”\? .*cannot be undone\.$/);
  });

  it("put the trigger's state on the proposal's record line, and nothing where the list is not known", () => {
    const accepted = { result: { team: "core", name: "rerun-weekly-numbers" } };
    assert.equal(triggerOfProposal(accepted, [own]), own);
    assert.equal(triggerOfProposal({ result: { team: "eng", name: "rerun-weekly-numbers" } }, [own]), undefined);
    assert.equal(proposalTriggerLine(own), "It is on; next run Mon 30 Nov, 06:00 UTC.");
    assert.equal(proposalTriggerLine({ ...own, enabled: false }), "It is switched off.");
    assert.equal(proposalTriggerLine(null), "It has been removed.");
    assert.equal(proposalTriggerLine(undefined), null);
  });

  it("say why a change did not go through, and what to do on a plane without them", () => {
    const older = new TroupeRpcError("trigger.own.disable", { code: -32601, message: "method_not_found", data: { method: "trigger.own.disable" } });
    assert.match(ownTriggerRefusal(older, "off"), /^It was not switched off: this plane does not let you change your own triggers yet; a team admin can/);
    const theirs = new TroupeRpcError("trigger.own.delete", { code: -32004, message: "forbidden", data: { reason: "core/nightly runs as svc:core/nightly, not as your own principal svc:core/own-ada" } });
    assert.equal(ownTriggerRefusal(theirs, "remove"), "It was not removed: core/nightly runs as svc:core/nightly, not as your own principal svc:core/own-ada.");
  });

  it("are offered only where the plane's initialize says own_triggers", async () => {
    assert.equal(knowsOwnTriggers({ own_triggers: true }), true);
    assert.equal(knowsOwnTriggers({ lifespans: true }), false);
    assert.equal(await planeKnowsOwnTriggers({ rpc: async <T,>(): Promise<T> => ({ capabilities: { own_triggers: true } }) as T }), true);
    assert.equal(await planeKnowsOwnTriggers({ rpc: async <T,>(): Promise<T> => ({ capabilities: {} }) as T }), false);
  });

  it("are asked of the plane by their names", async () => {
    const asked: unknown[] = [];
    const fetchImpl = (async (_url: string, init: { body: string }) => {
      const body = JSON.parse(init.body) as { id: number; method: string; params: unknown };
      asked.push([body.method, body.params]);
      return new Response(JSON.stringify({ jsonrpc: "2.0", id: body.id, result: {} }), { status: 200 });
    }) as unknown as typeof fetch;
    const plane = new PlaneClient("http://plane.test", fetchImpl);
    await plane.listOwnTriggers("t");
    await plane.switchOwnTrigger("t", "trg-1", false);
    await plane.switchOwnTrigger("t", "trg-1", true);
    await plane.removeOwnTrigger("t", "trg-1");
    assert.deepEqual(asked, [
      ["trigger.own.list", {}],
      ["trigger.own.disable", { trigger: "trg-1" }],
      ["trigger.own.enable", { trigger: "trg-1" }],
      ["trigger.own.delete", { trigger: "trg-1" }],
    ]);
  });
});

describe("the fake plane's own triggers", () => {
  let idp: FakeIdp;
  let worker: FakeWorker;
  let plane: FakePlane;
  let older: FakePlane;

  before(async () => {
    idp = await FakeIdp.start();
    worker = await FakeWorker.start();
    plane = await FakePlane.start({ idp, worker });
    older = await FakePlane.start({ idp, worker, beforeOwnTriggers: true });
  });
  after(async () => {
    await older.stop();
    await plane.stop();
    await worker.stop();
    await idp.stop();
  });

  it("lists the owner's own, switches them and removes them, and refuses anybody else", () => {
    plane.seedOwnTrigger("ada@example.com", { name: "weekly", team: "core" });
    plane.seedOwnTrigger("bea@example.com", { name: "beas", team: "core" });

    const listed = plane.rpcAs("ada@example.com", "trigger.own.list", {}) as { result: { triggers: OwnTrigger[] } };
    assert.deepEqual(
      listed.result.triggers.map((t) => t.name),
      ["weekly"],
    );
    assert.ok(listed.result.triggers[0]?.next_run_at);

    const off = plane.rpcAs("ada@example.com", "trigger.own.disable", { trigger: "core/weekly" }) as { result: { trigger: OwnTrigger } };
    assert.equal(off.result.trigger.enabled, false);
    assert.equal(off.result.trigger.next_run_at, null);

    const theirs = plane.rpcAs("ada@example.com", "trigger.own.delete", { trigger: "beas" }) as { error: { message: string; data: { reason: string } } };
    assert.equal(theirs.error.message, "forbidden");
    assert.match(theirs.error.data.reason, /runs as svc:core\/own-bea-example-com, not as your own principal/);

    assert.deepEqual((plane.rpcAs("ada@example.com", "trigger.own.delete", { trigger: "weekly" }) as { result: unknown }).result, { team: "core", name: "weekly", deleted: true });
    assert.deepEqual(
      plane.ownTriggerAudit.map((a) => [a.action, a.subject, a.detail["via"]]),
      [
        ["trigger.put", "core/weekly", "own"],
        ["trigger.delete", "core/weekly", "own"],
      ],
    );
  });

  it("is a method the older plane does not have", () => {
    assert.equal((older.rpcAs("ada@example.com", "trigger.own.list", {}) as { error: { message: string } }).error.message, "method_not_found");
  });

  it("works a schedule's next minute out as the plane does", () => {
    assert.equal(nextCronRun("0 6 * * 1", new Date("2026-11-28T10:15:30Z")), "2026-11-30T06:00:00Z");
    assert.equal(nextCronRun("*/15 * * * *", new Date("2026-11-28T23:59:00Z")), "2026-11-29T00:00:00Z");
    assert.equal(nextCronRun("0 6 * * 1-5", new Date("2026-11-28T10:00:00Z")), "2026-11-30T06:00:00Z");
  });
});
