// A session's name and its place at the top of the list (troupe #1032): neither the daemon
// nor the plane pushes a change of them, so a client puts the answer on the row itself, and
// the list moves at once; a refusal is said in words.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { ErrorCodes, FleetStore, markRefusal, rowFromDaemon, TroupeRpcError } from "../src/index.js";
import type { FleetRow, FleetSource, SessionKind } from "../src/index.js";

class StubSource implements FleetSource {
  rows: FleetRow[] = [];
  constructor(
    readonly id: string,
    readonly kind: SessionKind,
  ) {}
  async list(): Promise<FleetRow[]> {
    return this.rows;
  }
}

const row = (id: string, at: string): FleetRow =>
  rowFromDaemon({ id, workspace: `/w/${id}`, branch: null, profile: null, state: "dormant", status: "idle", created_at: null, last_active_at: at });

describe("a session's name and its place at the top", () => {
  it("are put on the row by the store at once: a kept one listed first, a renamed one under its name", async () => {
    const daemon = new StubSource("daemon", "local");
    daemon.rows = [row("old", "2026-11-01T09:00:00Z"), row("new", "2026-11-17T09:00:00Z")];
    const store = new FleetStore([daemon]);
    let seen: string[] = [];
    store.subscribe((s) => (seen = s.rows.map((r) => `${r.id}:${r.title}${r.pinned ? ":kept" : ""}`)));
    await store.refresh();
    assert.deepEqual(seen, ["new:/w/new", "old:/w/old"]);

    store.patch("old", { pinned: true, title: "Ledger notes" });
    assert.deepEqual(seen, ["old:Ledger notes:kept", "new:/w/new"]);

    store.patch("old", { pinned: false });
    assert.deepEqual(seen, ["new:/w/new", "old:Ledger notes"]);
  });

  it("refused, says whose they are, or the server's reason", () => {
    const forbidden = new TroupeRpcError("session.pin", { code: ErrorCodes.forbidden, message: "forbidden", data: { required_role: "owner" } });
    assert.equal(markRefusal(forbidden, "rename"), "Only its owner can rename this session");
    assert.equal(markRefusal(forbidden, "keep"), "Only its owner can keep this session at the top");
    assert.equal(markRefusal(forbidden, "let go"), "Only its owner can let this session go from the top");
    const long = new TroupeRpcError("session.title.set", { code: ErrorCodes.invalid_params, message: "invalid_params", data: { field: "title", reason: "a title is at most 200 bytes" } });
    assert.equal(markRefusal(long, "rename"), "a title is at most 200 bytes");
  });
});
