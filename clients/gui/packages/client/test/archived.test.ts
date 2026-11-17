// Archived sessions: hidden from the one list by their owner, for everyone who sees them,
// and listed only when somebody asks for the archived ones, from every source that has any.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { archiveRefusal, DaemonSource, FleetStore, mayArchive, PlaneSource, rowFromDaemon, rowFromPlane, TroupeRpcError } from "../src/index.js";
import type { DaemonClient, DaemonSessionRow, FleetRow, FleetSource, PlaneClient, SessionKind, SessionRow, SessionsFilter } from "../src/index.js";

function planeRow(id: string, over: Partial<SessionRow> = {}): SessionRow {
  return {
    id,
    owner: "alice",
    profile: "dev",
    visibility: "team",
    state: "dormant",
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
    archived: false,
    ...over,
  };
}

function daemonRow(id: string, over: Partial<DaemonSessionRow> = {}): DaemonSessionRow {
  return { id, workspace: "/w", branch: null, profile: null, state: "dormant", status: "idle", created_at: null, last_active_at: "2026-09-13T09:00:00Z", ...over };
}

class StubSource implements FleetSource {
  rows: FleetRow[] = [];
  archivedRows: FleetRow[] = [];
  fail: string | null = null;
  constructor(
    readonly id: string,
    readonly kind: SessionKind,
  ) {}
  async list(): Promise<FleetRow[]> {
    return this.rows;
  }
  async listArchived(): Promise<FleetRow[]> {
    if (this.fail) throw new Error(this.fail);
    return this.archivedRows;
  }
}

describe("archived sessions", () => {
  it("are carried on a plane's and a daemon's row", () => {
    assert.equal(rowFromPlane(planeRow("a", { archived: true })).archived, true);
    assert.equal(rowFromPlane(planeRow("a")).archived, false);
    // A plane before archiving says nothing, which is not archived.
    const { archived: _, ...older } = planeRow("a");
    assert.equal(rowFromPlane(older as SessionRow).archived, false);
    assert.equal(rowFromDaemon(daemonRow("l", { archived: true })).archived, true);
    assert.equal(rowFromDaemon(daemonRow("l")).archived, false);
  });

  it("are asked of the plane with archived: true, and of the daemon with filter.archived", async () => {
    const asked: SessionsFilter[] = [];
    const plane = {
      listSessions: async (_t: string, filter: SessionsFilter) => {
        asked.push(filter);
        return { sessions: filter.archived ? [planeRow("p-old", { archived: true })] : [planeRow("p-now")] };
      },
    } as unknown as PlaneClient;
    const filters: Record<string, unknown>[] = [];
    const daemon = {
      listSessions: async (filter: Record<string, unknown> = {}) => {
        filters.push(filter);
        return { sessions: filter["archived"] ? [daemonRow("l-old", { archived: true })] : [daemonRow("l-now")] };
      },
    } as unknown as DaemonClient;
    const store = new FleetStore([new PlaneSource(plane, async () => "t"), new DaemonSource(daemon)]);

    await store.refresh();
    assert.deepEqual(store.current.rows.map((r) => r.id).sort(), ["l-now", "p-now"]);
    // The default list asks for nothing archived, which is what the servers give by default.
    assert.deepEqual(asked, [{}]);
    assert.deepEqual(filters, [{}]);

    const archived = await store.archived();
    assert.deepEqual(archived.rows.map((r) => r.id), ["p-old", "l-old"]);
    assert.deepEqual(asked[1], { archived: true });
    assert.deepEqual(filters[1], { archived: true });
    assert.deepEqual(archived.sources["plane"]?.error, null);
    // Asking for the archived ones leaves the list as it was.
    assert.deepEqual(store.current.rows.map((r) => r.id).sort(), ["l-now", "p-now"]);
  });

  it("drops what a source from before archiving answers, since none of it is archived", async () => {
    const plane = { listSessions: async () => ({ sessions: [planeRow("a"), planeRow("b")] }) } as unknown as PlaneClient;
    const store = new FleetStore([new PlaneSource(plane, async () => "t")]);
    assert.deepEqual((await store.archived()).rows, []);
  });

  it("keeps the list's order, pinned first, and records a source that fails", async () => {
    const team = new StubSource("plane", "team");
    const local = new StubSource("daemon", "local");
    team.archivedRows = [
      { ...rowFromPlane(planeRow("a", { archived: true, last_active_at: "2026-09-13T08:00:00Z" })) },
      { ...rowFromPlane(planeRow("b", { archived: true, last_active_at: "2026-09-13T07:00:00Z", pinned: true })) },
    ];
    local.fail = "the daemon is not running";
    const store = new FleetStore([team, local]);
    const archived = await store.archived();
    assert.deepEqual(archived.rows.map((r) => r.id), ["b", "a"]);
    assert.equal(archived.sources["daemon"]?.error, "the daemon is not running");
  });

  it("never shows an archived row in the list, and drop takes one off it at once", async () => {
    const team = new StubSource("plane", "team");
    team.rows = [rowFromPlane(planeRow("a")), rowFromPlane(planeRow("b", { archived: true }))];
    const store = new FleetStore([team]);
    await store.refresh();
    assert.deepEqual(store.current.rows.map((r) => r.id), ["a"]);
    store.drop("a");
    assert.deepEqual(store.current.rows, []);
  });

  it("are the owner's to archive, on the platform or on this computer", () => {
    assert.equal(mayArchive({ kind: "team", yourRole: "owner" }), true);
    assert.equal(mayArchive({ kind: "local", yourRole: "owner" }), true);
    assert.equal(mayArchive({ kind: "private", yourRole: "owner" }), true);
    assert.equal(mayArchive({ kind: "team", yourRole: "collaborator" }), false);
    assert.equal(mayArchive({ kind: "team", yourRole: "viewer" }), false);
    assert.equal(mayArchive({ kind: "remote", yourRole: "owner" }), false);
    assert.equal(mayArchive(undefined), false);
  });

  it("say a forbidden in words", () => {
    const forbidden = new TroupeRpcError("session.archive", { code: -32004, message: "forbidden", data: { required_role: "owner" } });
    assert.equal(archiveRefusal(forbidden), "Only its owner can archive this session");
    assert.equal(archiveRefusal(forbidden, false), "Only its owner can unarchive this session");
    assert.equal(archiveRefusal(new Error("gone")), "gone");
  });
});
