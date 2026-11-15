// People by name (troupe #931): what an event's actor and a row's owner carry beside the
// subject reaches the entry and the row, and initials come from the name, or from the
// subject's local part where there is none. A server from before sends no name, and the
// entry and the row are what they were.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { emptyTranscript, fold, initials, named, nameOrSubject, rowFromInvite, rowFromPlane, rowFromRemote } from "../src/index.js";
import type { DurableEvent, Entry, Invitation, SessionRow } from "../src/index.js";

let seq = 0;
function event(type: string, data: Record<string, unknown>, actor: DurableEvent["actor"]): DurableEvent {
  seq += 1;
  return { seq, prev_hash: null, ts: new Date().toISOString(), actor, agent: ["root"], type, v: 1, data };
}

describe("a person by name in the transcript", () => {
  it("a user line carries the actor's name beside the subject", () => {
    const state = fold(emptyTranscript, event("user_input", { source: "user", text: "hi" }, { kind: "user", subject: "idp|7f3a", display_name: "Alice Example" }));
    const line = state.entries[0] as Extract<Entry, { kind: "user" }>;
    assert.equal(line.author, "idp|7f3a");
    assert.equal(line.authorName, "Alice Example");
  });

  it("an older server's line, and a name that is the subject again, carry none", () => {
    const old = fold(emptyTranscript, event("user_input", { source: "user", text: "hi" }, { kind: "user", subject: "bob@example.com" }));
    const echo = fold(emptyTranscript, event("user_input", { source: "user", text: "hi" }, { kind: "user", subject: "bob@example.com", display_name: "bob@example.com" }));
    for (const state of [old, echo]) {
      const line = state.entries[0] as Extract<Entry, { kind: "user" }>;
      assert.equal(line.author, "bob@example.com");
      assert.equal("authorName" in line, false);
    }
  });

  it("an approval names who decided it by name", () => {
    let state = fold(emptyTranscript, event("approval_requested", { call_id: "c1", tool: "shell", args: {}, agent_path: ["root"] }, { kind: "system" }));
    state = fold(state, event("approval_decided", { call_id: "c1", tool: "shell", decision: "allow" }, { kind: "user", subject: "idp|7f3a", display_name: "Alice Example" }));
    const approval = state.entries.find((e) => e.kind === "approval") as Extract<Entry, { kind: "approval" }>;
    assert.equal(approval.decidedBy, "idp|7f3a");
    assert.equal(approval.decidedByName, "Alice Example");
  });
});

describe("a session's owner by name", () => {
  const plane = { id: "s-1", owner: "idp|7f3a", profile: "dev", visibility: "team", state: "active", epoch: 1, title: null, last_active_at: null, last_seq: 0, head_hash: null } as unknown as SessionRow;

  it("a plane row carries owner_name as ownerName, and an older plane's none", () => {
    assert.equal(rowFromPlane({ ...plane, owner_name: "Alice Example" }).ownerName, "Alice Example");
    assert.equal(rowFromPlane(plane).ownerName, null);
    assert.equal(rowFromPlane({ ...plane, owner_name: "idp|7f3a" }).ownerName, null);
  });

  it("an offered laptop session and an invitation carry their owner's name", () => {
    assert.equal(rowFromRemote({ id: "s-l", owner: "ada@example.com", owner_name: "Ada" }).ownerName, "Ada");
    const invite = { session_id: "s-i", kind: "team", owner: "ada@example.com", owner_name: "Ada", role: "observe", invited_by: "ada@example.com", invited_at: "2026-11-15T10:00:00Z" } as unknown as Invitation;
    assert.equal(rowFromInvite(invite).ownerName, "Ada");
  });
});

describe("initials and names", () => {
  it("two letters from the name, else from the subject's local part", () => {
    assert.equal(initials("Alice Example"), "AE");
    assert.equal(initials("Bob"), "BO");
    assert.equal(initials("bob@example.com"), "BO");
    assert.equal(initials("ada.lovelace@example.com"), "AL");
    assert.equal(initials("idp|7f3a"), "7F");
  });

  it("a name worth showing, else the subject", () => {
    assert.equal(named("  Alice Example ", "idp|7f3a"), "Alice Example");
    assert.equal(named("idp|7f3a", "idp|7f3a"), undefined);
    assert.equal(named("", "x"), undefined);
    assert.equal(named(null, "x"), undefined);
    assert.equal(nameOrSubject("idp|7f3a", "Alice Example"), "Alice Example");
    assert.equal(nameOrSubject("idp|7f3a", undefined), "idp|7f3a");
    assert.equal(nameOrSubject(undefined, undefined), "somebody");
  });
});
