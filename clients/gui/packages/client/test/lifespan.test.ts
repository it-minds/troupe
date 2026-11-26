// How long a session lasts, in the words both web apps say it (troupe #1209): the marks a
// row and a head show, the plane's word on a row, what the log's change folds to, and
// whether a server knows lifespans at all, which is when a client offers the choice.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  ErrorCodes,
  TroupeRpcError,
  emptyTranscript,
  fold,
  knowsLifespans,
  lifespanMark,
  lifespanOf,
  lifespanRefusal,
  planeKnowsLifespans,
  rowFromPlane,
  untilWords,
} from "../src/index.js";
import type { SessionRow } from "../src/index.js";

const NOW = Date.parse("2026-11-25T12:00:00Z");

describe("a lifespan's words", () => {
  it("marks a throwaway session with when it goes, a persistent one by its word, and a normal one not at all", () => {
    assert.equal(lifespanMark({ lifespan: "throwaway", erasesAt: "2026-11-26T06:00:00Z" }, NOW), "throwaway · goes in 18 h");
    assert.equal(lifespanMark({ lifespan: "throwaway", erasesAt: "2026-11-25T12:40:00Z" }, NOW), "throwaway · goes in 40 min");
    assert.equal(lifespanMark({ lifespan: "throwaway", erasesAt: "2026-11-25T11:00:00Z" }, NOW), "throwaway · goes soon");
    assert.equal(lifespanMark({ lifespan: "throwaway", erasesAt: null }, NOW), "throwaway");
    assert.equal(lifespanMark({ lifespan: "persistent", erasesAt: null }, NOW), "persistent");
    assert.equal(lifespanMark({ lifespan: "normal", erasesAt: null }, NOW), null);
    assert.equal(untilWords("2026-11-28T12:00:00Z", NOW), "3 days");
  });

  it("is normal where nothing says otherwise, as every session from before lifespans is", () => {
    assert.equal(lifespanOf(undefined), "normal");
    assert.equal(lifespanOf("kept"), "normal");
    assert.equal(lifespanOf("persistent"), "persistent");
  });

  it("says a refusal in words", () => {
    const refused = (code: number, data?: Record<string, unknown>) => new TroupeRpcError("session.lifespan.set", { code, message: "x", ...(data ? { data } : {}) });
    assert.equal(lifespanRefusal(refused(ErrorCodes.forbidden, { required_role: "owner" })), "How long it lasts was not changed: only the session's owner says how long it lasts.");
    assert.equal(lifespanRefusal(refused(ErrorCodes.method_not_found)), "How long it lasts was not changed: this server does not know lifespans yet.");
  });
});

describe("a plane's row", () => {
  it("carries the lifespan and when a throwaway one goes, and is normal from an older plane", () => {
    const row = { id: "s-1", owner: "ada", profile: "dev", visibility: "team", state: "dormant", epoch: 1, title: null, last_active_at: null, last_seq: 0, head_hash: null, object_bytes: null, workspace_bytes: null, pinned: false, status: null, done_reason: null } as unknown as SessionRow;
    const quick = rowFromPlane({ ...row, lifespan: "throwaway", erases_at: "2026-11-26T06:00:00Z" });
    assert.equal(quick.lifespan, "throwaway");
    assert.equal(quick.erasesAt, "2026-11-26T06:00:00Z");
    assert.equal(rowFromPlane(row).lifespan, "normal");
    assert.equal(rowFromPlane(row).erasesAt, null);
  });
});

describe("the log", () => {
  it("says the lifespan its session was made with, then each change, in a line", () => {
    const at = (seq: number, type: string, data: Record<string, unknown>) => ({ seq, prev_hash: null, ts: "2026-11-25T12:00:00Z", agent: ["root"], type, v: 1, data, actor: { kind: "user", subject: "ada" } });
    let state = fold(emptyTranscript, at(1, "session_created", { profile: "dev", lifespan: "throwaway" }) as never);
    assert.equal(state.lifespan, "throwaway");
    state = fold(state, at(2, "session_lifespan_changed", { from: "throwaway", to: "persistent", actor: "ada" }) as never);
    assert.equal(state.lifespan, "persistent");
    assert.ok(state.entries.some((e) => "text" in e && e.text === "This session is persistent now: it is kept until its owner erases it"));
  });
});

describe("whether a server knows lifespans", () => {
  it("is what its initialize says, asked once a sign-in and naming no client", async () => {
    assert.equal(knowsLifespans({ lifespans: true }), true);
    assert.equal(knowsLifespans({ branches: true }), false);
    assert.equal(knowsLifespans(undefined), false);

    const asked: unknown[] = [];
    const plane = { rpc: async <T,>(method: string, params?: unknown): Promise<T> => (asked.push([method, params]), { capabilities: { lifespans: true } } as T) };
    assert.equal(await planeKnowsLifespans(plane), true);
    assert.equal(await planeKnowsLifespans(plane), true);
    assert.deepEqual(asked, [["initialize", { protocol_version: "1" }]]);

    const older = { rpc: async <T,>(): Promise<T> => ({ protocol_version: "1" }) as T };
    assert.equal(await planeKnowsLifespans(older), false);
    const away = { rpc: async <T,>(): Promise<T> => Promise.reject(new Error("unreachable")) };
    assert.equal(await planeKnowsLifespans(away), false);
  });
});
