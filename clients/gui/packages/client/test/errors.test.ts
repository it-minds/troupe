/**
 * What a failed call tells the person who made it.
 *
 * This exists because of a real morning: a session refused to start and the whole of
 * what the GUI could say was `session.create: unavailable (-32010)`. The plane had said
 * considerably more than that — which component, and what it answered — and the client
 * dropped all of it on the floor. The code and the word name a category; the category
 * is never the thing that needs fixing.
 */

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { TroupeRpcError } from "../src/index.js";

describe("a JSON-RPC error says why, not just what kind", () => {
  it("puts the server's reason in the message", () => {
    const err = new TroupeRpcError("session.create", {
      code: -32010,
      message: "unavailable",
      data: { reason: "the pod did not accept the session" },
    });

    assert.equal(
      err.message,
      "session.create: unavailable (-32010) — the pod did not accept the session",
    );
  });

  it("carries the detail too, because that is the component's own answer", () => {
    const err = new TroupeRpcError("session.create", {
      code: -32010,
      message: "unavailable",
      data: {
        reason: "the pod did not accept the session",
        detail: "bundle 1 is not on this pod: not_found",
      },
    });

    assert.match(err.message, /bundle 1 is not on this pod/);
    // And the structure is still there for anything that wants to branch on it.
    assert.equal(err.code, -32010);
    assert.equal(err.data?.reason, "the pod did not accept the session");
  });

  it("says the same as before when there is nothing more to say", () => {
    const bare = new TroupeRpcError("sessions.list", { code: -32003, message: "unauthenticated" });
    assert.equal(bare.message, "sessions.list: unauthenticated (-32003)");

    // An empty reason is not a reason, and a dangling em dash is worse than no dash.
    const empty = new TroupeRpcError("sessions.list", {
      code: -32003,
      message: "unauthenticated",
      data: { reason: "" },
    });
    assert.equal(empty.message, "sessions.list: unauthenticated (-32003)");
  });

  it("ignores a reason that is not a string, rather than printing [object Object]", () => {
    const err = new TroupeRpcError("session.create", {
      code: -32602,
      message: "invalid_params",
      data: { reason: { choose: "a team" }, teams: ["engineering", "design"] },
    });

    assert.equal(err.message, "session.create: invalid_params (-32602)");
    assert.deepEqual(err.data?.teams, ["engineering", "design"]);
  });
});
