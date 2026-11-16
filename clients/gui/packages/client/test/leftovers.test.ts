// The fake plane answers what the plane does since #957: a person's name beside the owner
// in the three answers that lacked one, a limit's refusal in its setting's unit, a dry run
// of a client version policy, and a ceiling against what a profile's pods could run.

import { test } from "node:test";
import assert from "node:assert/strict";
import { ceilingAboveWords } from "../src/index.js";
import { exampleAdmin } from "./support/admin.js";

const ALICE = "alice@example.com";

test("the erasure's preview, Connections' sessions and the memory's readers carry the owner's name", async () => {
  const admin = exampleAdmin();
  const preview = (await admin.call(ALICE, "admin.session.erase.preview", { session_id: "s-7f3a9c22" })) as { result: Record<string, unknown> };
  assert.equal(preview.result["owner"], "dan@example.com");
  assert.equal(preview.result["owner_name"], "Dan");

  const connections = (await admin.call(ALICE, "admin.connections.list", {})) as { result: { sessions: Array<Record<string, unknown>> } };
  const carried = connections.result.sessions.find((s) => s["owner"] === "dan@example.com");
  assert.equal(carried?.["owner_name"], "Dan");

  const memory = (await admin.call(ALICE, "admin.memory.get", { scope: "organisation" })) as { result: { readers: { sessions: Array<Record<string, unknown>> } } };
  const reader = memory.result.readers.sessions.find((r) => r["session_id"] === "s-7f3a9c21");
  assert.equal(reader?.["owner_name"], "Alice");
});

test("a limit's refusal says the ceiling in its setting's unit, with the field's own beside it", async () => {
  const admin = exampleAdmin();
  const refused = (await admin.call(ALICE, "admin.team.update", { name: "core", attrs: { idle_timeout_seconds: 7200 } })) as { error: { message: string; data: Record<string, unknown> } };
  assert.equal(refused.error.message, "forbidden");
  assert.equal(refused.error.data["unit"], "minutes");
  assert.equal(refused.error.data["limit"], 30);
  assert.equal(refused.error.data["ceiling"], 1800);
});

test("a dry run of a client policy answers what the put would leave and writes and audits nothing", async () => {
  const admin = exampleAdmin();
  const recorded = admin.audit.length;
  const was = admin.policies["tui"]!.recommended;
  const dry = (await admin.call(ALICE, "admin.clients.put", { component: "tui", policy: { recommended: "0.40.0-beta" }, dry_run: true })) as { result: Record<string, unknown> };
  assert.equal(dry.result["dry_run"], true);
  assert.equal(dry.result["recommended"], "0.40.0-beta");
  assert.ok(dry.result["affected"]);
  assert.equal(admin.policies["tui"]!.recommended, was);
  assert.equal(admin.audit.length, recorded);
});

test("a profile's preview says its ceiling against the most its pods could run, and the sentence has both numbers", async () => {
  const admin = exampleAdmin();
  const preview = (await admin.call(ALICE, "admin.profile.preview", { profile: { name: "dev", image: "registry.example.com/troupe/worker:1", max_sessions: 40 } })) as {
    result: { capacity: { max_sessions: number; at_once: { sessions: number | null; by: "hosts" | "policy" | null }; above: boolean } };
  };
  assert.deepEqual(preview.result.capacity.at_once, { sessions: 16, by: "policy" });
  assert.equal(preview.result.capacity.above, true);
  assert.equal(
    ceilingAboveWords("dev", 40, preview.result.capacity.at_once),
    "dev allows 40 sessions at once, and its pods can run 16 at once (the cluster policy's most replicas): saved as a limit, not a promise, so no more than 16 run.",
  );
  assert.equal(ceilingAboveWords("dev", 16, preview.result.capacity.at_once), null);
  assert.equal(ceilingAboveWords("dev", 400, { sessions: null, by: null }), null);
});
