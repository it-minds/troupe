// The merge. One list from several sources, with the properties that matter when one
// of them is a plane on the other side of a network and the others are not.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { awaitingApproval, awaitingYou, filterRows, FleetStore, rowFromPlane, totalCostMicros } from "../src/index.js";
import type { FleetRow, FleetSource, SessionKind, SessionRow } from "../src/index.js";

function planeRow(id: string, over: Partial<SessionRow> = {}): SessionRow {
  return {
    id,
    owner: "alice",
    profile: "dev",
    visibility: "team",
    state: "active",
    epoch: 1,
    title: null,
    last_active_at: "2026-09-13T10:00:00Z",
    last_seq: 3,
    head_hash: null,
    object_bytes: null,
    workspace_bytes: null,
    pinned: false,
    status: "idle",
    done_reason: null,
    pending_approvals: 0,
    cost_micros: 0,
    origin: { kind: "user" },
    terms: null,
    reviewed_by: null,
    reviewed_at: null,
    your_role: "owner",
    ...over,
  };
}

class StubSource implements FleetSource {
  rows: FleetRow[] = [];
  fail: string | null = null;
  calls = 0;
  constructor(
    readonly id: string,
    readonly kind: SessionKind,
  ) {}
  async list(): Promise<FleetRow[]> {
    this.calls += 1;
    if (this.fail) throw new Error(this.fail);
    return this.rows;
  }
}

const row = (id: string, kind: SessionKind, over: Partial<FleetRow> = {}): FleetRow => ({
  ...rowFromPlane(planeRow(id)),
  kind,
  source: kind,
  ...over,
});

describe("the fleet store", () => {
  it("puts every source in one list, pinned first and newest next", async () => {
    const team = new StubSource("plane", "team");
    const local = new StubSource("daemon", "local");
    team.rows = [row("a", "team", { lastActiveAt: "2026-09-13T09:00:00Z" })];
    local.rows = [
      row("b", "local", { lastActiveAt: "2026-09-13T11:00:00Z" }),
      row("c", "local", { lastActiveAt: "2026-09-13T08:00:00Z", pinned: true }),
    ];

    const store = new FleetStore([team, local]);
    await store.refresh();
    assert.deepEqual(
      store.current.rows.map((r) => r.id),
      ["c", "b", "a"],
    );
    assert.deepEqual(
      store.current.rows.map((r) => r.kind),
      ["local", "local", "team"],
    );
  });

  it("keeps a failing source's last rows and records why", async () => {
    const team = new StubSource("plane", "team");
    const local = new StubSource("daemon", "local");
    team.rows = [row("a", "team")];
    local.rows = [row("b", "local")];

    const store = new FleetStore([team, local]);
    await store.refresh();
    assert.equal(store.current.rows.length, 2);

    // A plane that has gone away must not take the local sessions off the screen.
    team.fail = "the plane is unreachable";
    await store.refresh();
    assert.equal(store.current.rows.length, 2);
    assert.match(store.current.sources["plane"]!.error!, /unreachable/);
    assert.equal(store.current.sources["daemon"]!.error, null);
  });

  it("joins a private session's two rows, with the daemon's copy winning", async () => {
    // Stage 3's shape, proven now so the store does not have to change for it: the
    // plane lists a private session it cannot read, and the daemon has the real one.
    const plane = new StubSource("plane", "team");
    const daemon = new StubSource("daemon", "private");
    plane.rows = [row("p", "private", { source: "plane", title: null, status: null, sync: null })];
    daemon.rows = [row("p", "private", { source: "daemon", title: "a private thing", status: "thinking", sync: "pending" })];

    const store = new FleetStore([plane, daemon]);
    await store.refresh();
    assert.equal(store.current.rows.length, 1);
    const merged = store.current.rows[0]!;
    assert.equal(merged.title, "a private thing");
    assert.equal(merged.status, "thinking");
    assert.equal(merged.sync, "pending");
  });

  it("applies live news onto a row without a round trip", async () => {
    const team = new StubSource("plane", "team");
    team.rows = [row("a", "team", { status: "idle", pendingApprovals: 0 })];
    const store = new FleetStore([team]);
    await store.refresh();

    // What a worker's summary subscription says about a session that is open.
    store.patch("a", { status: "waiting", pendingApprovals: 1 });
    assert.equal(store.current.rows[0]!.status, "waiting");
    assert.equal(team.calls, 1, "a patch went back to the server");
  });

  it("filters, counts approvals and sums cost", () => {
    const rows = [
      row("a", "team", { status: "waiting", pendingApprovals: 2, costMicros: 100 }),
      row("b", "local", { status: "idle", pendingApprovals: 0, costMicros: 50, profile: "ux" }),
      row("c", "team", { status: "idle", pendingApprovals: 1, costMicros: null, title: "nightly build" }),
    ];

    assert.deepEqual(filterRows(rows, { kind: "team" }).map((r) => r.id), ["a", "c"]);
    assert.deepEqual(filterRows(rows, { profile: "ux" }).map((r) => r.id), ["b"]);
    assert.deepEqual(filterRows(rows, { needsApproval: true }).map((r) => r.id), ["a", "c"]);
    assert.deepEqual(filterRows(rows, { query: "NIGHTLY" }).map((r) => r.id), ["c"]);
    assert.deepEqual(awaitingApproval(rows).map((r) => r.id), ["a", "c"]);
    assert.equal(totalCostMicros(rows), 150);
  });

  // The inbox is every session waiting on its person, whichever way it asked.
  it("puts a session waiting on a question in the inbox beside one waiting on an approval", () => {
    const rows = [
      row("a", "team", { status: "waiting", pendingApprovals: 1 }),
      row("b", "local", { status: "waiting", pendingQuestions: 1 }),
      row("c", "local", { status: "idle" }),
      row("d", "team", { status: "waiting", pendingApprovals: 1, pendingQuestions: 2 }),
    ];

    assert.deepEqual(awaitingYou(rows).map((r) => r.id), ["a", "b", "d"]);
    assert.deepEqual(awaitingApproval(rows).map((r) => r.id), ["a", "d"]);
  });

  it("reads the plane's row without inventing anything", () => {
    const r = rowFromPlane(planeRow("z", { title: "t", pending_approvals: 3, pending_questions: 2, cost_micros: null, status: null }));
    assert.equal(r.kind, "team");
    assert.equal(r.pendingApprovals, 3);
    assert.equal(r.pendingQuestions, 2);
    // A plane from before the column says nothing, which is none open.
    assert.equal(rowFromPlane(planeRow("y")).pendingQuestions, 0);
    assert.equal(r.costMicros, null, "a cost nobody reported is not zero");
    assert.equal(r.status, null);
    assert.equal(r.sync, null, "a team session has no sync state");
  });
});
