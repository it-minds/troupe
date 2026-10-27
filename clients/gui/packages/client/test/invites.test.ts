// What a private session's invitation to steer says it lets a person do now (troupe #765):
// steer it while its owner offers it, read it otherwise, and, where the plane still holds
// an offer whose laptop is gone, since when it is offline, as `remote.list` says it.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { remoteWhen, steerWords } from "../src/index.js";
import type { Invitation } from "../src/index.js";

const invitation = (over: Partial<Invitation>): Invitation => ({
  session_id: "s-private",
  kind: "private",
  owner: "ada@example.test",
  role: "control",
  invited_by: "ada@example.test",
  invited_at: "2026-10-26T08:00:00Z",
  ...over,
});

describe("steerWords", () => {
  it("says an offered one is steered, and one never offered is read", () => {
    assert.equal(steerWords(invitation({ offered: true })), "offered · you can steer");
    assert.equal(steerWords(invitation({ offered: false })), "not offered · read-only");
    assert.equal(steerWords(invitation({ offered: false, offline_since: null })), "not offered · read-only");
  });

  it("says since when an offer whose laptop went is offline, and that it is read meanwhile", () => {
    const since = "2026-10-26T09:30:00Z";
    assert.equal(steerWords(invitation({ offered: false, offline_since: since })), `offline since ${remoteWhen(since)} · read-only`);
  });

  it("says nothing for an invitation to follow, or a pod session's", () => {
    assert.equal(steerWords(invitation({ role: "observe", offered: true })), null);
    assert.equal(steerWords(invitation({ kind: "team" })), null);
  });
});
