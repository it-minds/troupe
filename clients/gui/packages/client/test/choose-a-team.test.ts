// A new session on a profile two of the person's teams may use (troupe #992). The plane
// does not guess whose budget pays: with several candidates and no `team` it refuses with
// `invalid_params`, `reason: "choose a team"` and the names. The client reads the names
// off the refusal, asks, and sends the create again with `team`; and where the listing
// already names several, the screen asks before sending. The terminal holds the same
// examples (`clients/tui/test/troupe/new_session_team_test.exs`).

import assert from "node:assert/strict";
import { describe, it, test } from "node:test";
import { TroupeRpcError, chosenTeam, teamQuestion, teamsToChoose } from "../src/index.js";
import { startHarness } from "./support/harness.js";

describe("the refusal that asks which team", () => {
  it("carries the names the person chooses between", () => {
    const err = new TroupeRpcError("session.create", { code: -32602, message: "invalid_params", data: { reason: "choose a team", teams: ["core", "design"] } });
    assert.deepEqual(teamsToChoose(err), ["core", "design"]);
  });

  it("is no other refusal, and not one that names fewer than two", () => {
    assert.equal(teamsToChoose(new TroupeRpcError("session.create", { code: -32602, message: "invalid_params", data: { field: "agent", reason: "no primary agent named x" } })), null);
    assert.equal(teamsToChoose(new TroupeRpcError("session.create", { code: -32602, message: "invalid_params", data: { reason: "choose a team", teams: ["core"] } })), null);
    assert.equal(teamsToChoose(new Error("choose a team")), null);
    assert.equal(teamsToChoose(null), null);
  });
});

describe("the team a session is for", () => {
  it("is the one picked, else the one remembered, while it is still a candidate", () => {
    assert.equal(chosenTeam(["core", "design"], "design", "core"), "design");
    assert.equal(chosenTeam(["core", "design"], null, "core"), "core");
    // A remembered team that may no longer use the profile is dropped, and the person asked.
    assert.equal(chosenTeam(["core", "design"], null, "ops"), null);
    assert.equal(chosenTeam(["core", "design"], "ops", null), null);
  });

  it("is no choice with one candidate or none: the create names no team", () => {
    assert.equal(chosenTeam(["core"], "core", "core"), null);
    assert.equal(chosenTeam([], null, "core"), null);
    assert.equal(chosenTeam(undefined, null, null), null);
  });

  it("is asked in words that say what it decides", () => {
    assert.equal(teamQuestion("dev", ["core", "design"]), "core and design can both use dev. Choose the team it is for: its budget pays, and everyone on it can open it.");
    assert.equal(teamQuestion("dev", ["core", "design", "ops"]), "core, design and ops can all use dev. Choose the team it is for: its budget pays, and everyone on it can open it.");
  });
});

test("the fake plane asks which team, and takes the create that names one", async (t) => {
  const h = await startHarness({ plane: { profiles: ["dev"], teams: ["core", "design"] } });
  t.after(() => h.stop());
  const auth = await h.signIn();

  const refused = await auth.rpc("session.create", { profile: "dev", prompt: "hello" }).then(
    () => null,
    (e: unknown) => e,
  );
  assert.ok(refused instanceof TroupeRpcError, "refused");
  assert.equal(refused.message, "session.create: invalid_params (-32602) — choose a team");
  assert.deepEqual(teamsToChoose(refused), ["core", "design"]);

  // Sent again with the team chosen, nothing else changed: it is made, for that team.
  const made = await auth.rpc<{ session_id: string }>("session.create", { profile: "dev", prompt: "hello", team: "design" });
  assert.match(made.session_id, /^s-p-/);
  assert.deepEqual(h.plane.createdFor, ["design"]);

  // A team that is not one of theirs is refused, not taken as a choice.
  await assert.rejects(auth.rpc("session.create", { profile: "dev", team: "ops" }), /forbidden/);
});

test("a person in one team is never asked", async (t) => {
  const h = await startHarness({ plane: { profiles: ["dev"], teams: ["core"] } });
  t.after(() => h.stop());
  const auth = await h.signIn();
  const made = await auth.rpc<{ session_id: string }>("session.create", { profile: "dev" });
  assert.match(made.session_id, /^s-p-/);
  assert.deepEqual(h.plane.createdFor, []);
});
