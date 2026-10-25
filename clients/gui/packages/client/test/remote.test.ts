// A laptop's session offered to the plane for steering from another device (troupe #58), as the client library reads it: the plane's `remote.list` row, the
// daemon's word on its own offer, the one list where this computer's row wins, and
// `remote.open` with an endpoint taken against the plane and a refusal said in words.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { FleetStore, offerRestartWords, onThisComputer, openRemote, remoteOffer, remoteRefusal, rowFromDaemon, rowFromRemote, TroupeRpcError } from "../src/index.js";
import type { FleetRow, FleetSource } from "../src/index.js";

const listed = {
  id: "s-1",
  kind: "remote",
  owner: "ada@example.com",
  owner_name: "Ada",
  workspace: "billing",
  state: "offline",
  offline_since: "2026-10-18T07:30:00Z",
  offered_at: "2026-10-18T07:00:00Z",
  your_role: "control",
  shares: null,
};

describe("a relayed session", () => {
  it("is a remote row, offline with since when, reached through the plane", () => {
    const row = rowFromRemote(listed);
    assert.equal(row.kind, "remote");
    assert.equal(row.title, "billing");
    assert.equal(row.state, "offline");
    assert.equal(row.yourRole, "control");
    // The plane says nothing of a restart: that is the laptop's own listing's to say.
    assert.deepEqual(row.remote, {
      state: "offline",
      since: "2026-10-18T07:30:00Z",
      owner: "ada@example.com",
      ownerName: "Ada",
      shares: [],
      steering: [],
      lasts: null,
      restored: false,
    });
    assert.deepEqual(offerRestartWords(row.remote!), []);
    assert.equal(onThisComputer(row.kind), false);
    assert.equal(onThisComputer("local"), true);
    assert.equal(onThisComputer("private"), true);
  });

  it("is this computer's own row where this computer offered it", async () => {
    const offered = rowFromDaemon({ id: "s-1", workspace: "/home/ada/billing", kind: "local", remote: { state: "online", owner: "ada@example.com", shares: [], steering: [{ subject: "bea@example.com", role: "control" }] } } as never);
    assert.equal(offered.remote?.steering[0]?.subject, "bea@example.com");

    // What it says of a restart, in the terminal's words.
    const back = rowFromDaemon({ id: "s-2", workspace: "/w", kind: "local", remote: { state: "online", lasts: "across_restarts", restored: true, shares: [], steering: [] } } as never);
    assert.deepEqual(offerRestartWords(back.remote!), ["back after a restart"]);
    const once = rowFromDaemon({ id: "s-3", workspace: "/w", kind: "local", remote: { state: "online", lasts: "until_restart", shares: [], steering: [] } } as never);
    assert.deepEqual(offerRestartWords(once.remote!), ["until this machine restarts"]);

    const source = (kind: FleetRow["kind"], id: string, rows: FleetRow[]): FleetSource => ({ id, kind, list: async () => rows });
    const store = new FleetStore([source("local", "daemon", [offered]), source("remote", "remote", [rowFromRemote(listed)])]);
    await store.refresh();
    assert.equal(store.current.rows.length, 1);
    assert.equal(store.current.rows[0]!.kind, "local");
  });

  it("is opened with an endpoint against the plane, and an away laptop is said in words", async () => {
    const rpc = async <T>(method: string, params?: unknown): Promise<T> => {
      assert.equal(method, "remote.open");
      assert.deepEqual(params, { session_id: "s-1" });
      return { session_id: "s-1", endpoint: "/v1/relay/session", role: "collaborator", token: "t" } as T;
    };
    const opened = await openRemote(rpc, "https://plane.example.com", "s-1");
    assert.equal(opened.endpoint, "wss://plane.example.com/v1/relay/session");

    const away = async <T>(): Promise<T> => {
      throw new TroupeRpcError("remote.open", { code: -32010, message: "unavailable", data: { offline_since: "2026-10-18T07:30:00Z" } });
    };
    await assert.rejects(openRemote(away, "https://plane.example.com", "s-1"), /The laptop is offline since/);
    assert.equal(remoteRefusal(new TroupeRpcError("remote.open", { code: -32005, message: "not_found" })), "It is no longer offered to you");
    assert.equal(remoteOffer(null), null);
  });
});
