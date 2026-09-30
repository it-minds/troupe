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
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import { ErrorCodes, TroupeRpcError } from "../src/index.js";

// The table is PROTOCOL.md's own, read from the page, as the TUI's contract test reads it:
// a code added there and not here fails, and so does one this client spells differently.
// -32014 and -32015 were added there and this table went on without them.
describe("the error codes are the contract's", () => {
  it("has every code in PROTOCOL.md §10, under the token the contract gives it, and no other", () => {
    const protocol = readFileSync(new URL("../../../../../PROTOCOL.md", import.meta.url), "utf8");
    const section = protocol.split("\n## 10. Errors\n")[1]?.split("\n## ")[0] ?? "";
    const contract: Record<string, number> = {};
    for (const [, code, token] of section.matchAll(/^\| (-\d+) \| `([a-z_]+)` \|/gm)) {
      if (code && token) contract[token] = Number(code);
    }

    assert.equal(contract["conflict"], -32006, "the table was not found in PROTOCOL.md");
    assert.deepEqual({ ...ErrorCodes }, contract);
  });
});

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
