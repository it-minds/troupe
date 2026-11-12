// The new-session screen's rules apart from any screen: the inline tokens, what the agent
// is left to read, the title the first line gives, the auto-pick and its sentence, how
// full a profile is, and who can open what it starts. The terminal holds the same
// examples (`clients/tui/test/troupe/ui/new_session_test.exs`).

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { autoPickProfile, cleanMessage, messageTokens, profileRoom, stripTokens, titleFromMessage, tokensSentence, whoCanOpen } from "../src/index.js";

const names = { profiles: ["dev", "standard", "research-let"], agents: ["build", "plan", "orchestrate"] };

describe("the message's tokens", () => {
  it("set the profile, the agent and where, at the start or after a space", () => {
    assert.deepEqual(messageTokens("@dev fix the loop #plan /local", names), { profile: "dev", agent: "plan", where: "local" });
    assert.deepEqual(messageTokens("/platform tidy", names), { where: "platform" });
  });

  it("are tokens only where they name something that exists, and only after a space", () => {
    assert.deepEqual(messageTokens("ask @someone about #123, mail a@dev", names), {});
    assert.equal(cleanMessage("ask @someone about #123", names), "ask @someone about #123");
    assert.deepEqual(messageTokens("see a/local file", names), {});
  });

  it("are taken out of what the agent reads, spaces closed up", () => {
    assert.equal(cleanMessage("@dev  rewrite the loop #plan\nthen /local test it", names), "rewrite the loop\nthen test it");
  });

  it("of a chip's kind leave when that chip is picked, so the chip holds", () => {
    assert.equal(stripTokens("fix it @dev #plan", { profile: "standard" }, names), "fix it #plan");
    assert.equal(stripTokens("fix it @dev #plan /local", { agent: "build", where: "platform" }, names), "fix it @dev");
  });

  it("are said back as the line under the sentence", () => {
    assert.equal(tokensSentence({ where: "local", profile: "dev", agent: "plan" }), "Set from your message: /local @dev #plan.");
    assert.equal(tokensSentence({}), null);
  });
});

describe("the title", () => {
  it("is the first sentence or line, at most sixty characters", () => {
    assert.equal(titleFromMessage("Rewrite the placement loop. Corners first."), "Rewrite the placement loop");
    assert.equal(titleFromMessage("one line\nanother"), "one line");
    assert.equal(titleFromMessage("x".repeat(80)).length, 60);
    assert.equal(titleFromMessage(""), "");
  });
});

describe("the auto-pick", () => {
  const rows = [
    { name: "dev", capacity: 6, active_sessions: 2 },
    { name: "standard", capacity: 6, active_sessions: 6 },
    { name: "research-let", capacity: 3, active_sessions: 1 },
  ];

  it("is the last profile used while it has room, and says so", () => {
    assert.deepEqual(autoPickProfile(rows, "research-let"), { name: "research-let", rule: "last", why: "Picked research-let because you used it last." });
  });

  it("is the first with room when the last is full, and says which is full", () => {
    assert.deepEqual(autoPickProfile(rows, "standard"), { name: "dev", rule: "instead", why: "Picked dev: standard is full right now." });
  });

  it("is the first with room when nothing was used yet", () => {
    assert.equal(autoPickProfile(rows, null).name, "dev");
    assert.equal(autoPickProfile(rows, null).rule, "first");
  });

  it("with every profile full still names one, to queue on", () => {
    const full = rows.map((r) => ({ ...r, active_sessions: r.capacity }));
    assert.deepEqual(autoPickProfile(full, "standard"), { name: "standard", rule: "none", why: "Every profile is full right now." });
  });
});

describe("a profile's room", () => {
  it("is full below the ceiling, and at the ceiling is refused rather than queued", () => {
    assert.deepEqual(profileRoom({ name: "dev", capacity: 4, active_sessions: 4, max_sessions: null }), { free: 0, capacity: 4, full: true, atCeiling: false, maxSessions: null });
    assert.equal(profileRoom({ name: "dev", capacity: 4, active_sessions: 4, max_sessions: 4 }).atCeiling, true);
    assert.equal(profileRoom({ name: "dev", capacity: 4, active_sessions: 4, max_sessions: 4 }).full, false);
    assert.equal(profileRoom({ name: "dev", capacity: 4, active_sessions: 1 }).full, false);
  });
});

describe("who can open it", () => {
  it("follows from where it runs", () => {
    assert.equal(whoCanOpen("local"), "only you can open it");
    assert.equal(whoCanOpen("platform", { teams: ["core"], private: true }), "only you can open it");
    assert.equal(whoCanOpen("platform", { teams: ["core"] }), "everyone on core can open it");
    assert.equal(whoCanOpen("platform", { teams: ["core", "salg", "ops"] }), "everyone on core, salg and ops can open it");
  });
});
