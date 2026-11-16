// What agents propose for a team's or the organisation's memory (troupe #55): the admin
// client's three methods by name, the fake admin's answers as the plane's (who decides, a
// decline needs its sentence, decided once, the entry under its topic), and a person's own
// `me.memory` carrying their proposals through `PlaneOwn`.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AdminApi, PlaneOwn } from "../src/index.js";
import { appendEntry, exampleAdmin } from "./support/admin.js";

describe("memory proposals", () => {
  it("are asked of the plane by name", async () => {
    const calls: Array<{ method: string; params: unknown }> = [];
    const api = new AdminApi(async <T,>(method: string, params: unknown): Promise<T> => {
      calls.push({ method, params });
      return {} as T;
    });
    await api.memoryProposals();
    await api.memoryAccept("p-1");
    await api.memoryDecline("p-2", "Not for everyone.");
    assert.deepEqual(calls, [
      { method: "admin.memory.proposals", params: {} },
      { method: "admin.memory.accept", params: { id: "p-1" } },
      { method: "admin.memory.decline", params: { id: "p-2", reason: "Not for everyone." } },
    ]);
  });

  it("are decided in the fake as the plane decides them", async () => {
    const admin = exampleAdmin();
    const ask = (who: string, method: string, params: Record<string, unknown> = {}) => admin.call(who, method, params);

    // A team admin sees their team's; a platform admin every one.
    const dan = await ask("dan@example.com", "admin.memory.proposals");
    assert.ok("result" in dan);
    assert.deepEqual((dan.result as { proposals: Array<{ id: string }> }).proposals.map((p) => p.id), ["p-core-1"]);
    const forbidden = await ask("dan@example.com", "admin.memory.accept", { id: "p-org-1" });
    assert.ok("error" in forbidden && forbidden.error.message === "forbidden");

    // A decline needs its sentence; then it is decided once.
    const bare = await ask("alice@example.com", "admin.memory.decline", { id: "p-org-1", reason: " " });
    assert.ok("error" in bare && bare.error.message === "invalid_params");
    const declined = await ask("alice@example.com", "admin.memory.decline", { id: "p-org-1", reason: "Imperative mood." });
    assert.ok("result" in declined);
    assert.match((declined.result as { message: string }).message, /declined by alice@example\.com: Imperative mood\.$/);
    const again = await ask("alice@example.com", "admin.memory.accept", { id: "p-org-1" });
    assert.ok("error" in again && again.error.message === "conflict");

    // Accepted, the entry is under its topic in the team's document, and audited.
    const accepted = await ask("dan@example.com", "admin.memory.accept", { id: "p-core-1" });
    assert.ok("result" in accepted);
    assert.equal(admin.memory.get("team/core")!.at(-1)!.text, "## Releases\n\n- Releases go out on Tuesdays after the freeze lifts.");
    assert.deepEqual(admin.audit.slice(-2).map((a) => a.action), ["memory.put", "memory.proposal.accept"]);
  });

  it("go under the section on their topic, or a new one at the end", () => {
    assert.equal(appendEntry("", "Tone", "Short."), "## Tone\n\n- Short.");
    assert.equal(appendEntry("## Tone\n\n- Short.\n\n## Dates\n\nISO.", "tone", "Plain."), "## Tone\n\n- Short.\n- Plain.\n\n## Dates\n\nISO.");
    assert.equal(appendEntry("Opening.", "Dates", "ISO."), "Opening.\n\n## Dates\n\n- ISO.");
  });

  it("reach a person's own app with their memory, and none from a plane from before them", async () => {
    const pending = { id: "p-1", scope: "team", team: "core", topic: "Releases", entry: "Tag first.", state: "pending" };
    const own = (proposals?: unknown[]) =>
      new PlaneOwn(async <T,>(): Promise<T> => ({ user: { version: 1, text: "", bytes: 0, limit: 8192 }, documents: [], ...(proposals ? { proposals } : {}) }) as T, "https://plane.example.test");
    assert.deepEqual((await own([pending]).ownMemory()).proposals, [pending]);
    assert.deepEqual((await own().ownMemory()).proposals, []);
  });
});
