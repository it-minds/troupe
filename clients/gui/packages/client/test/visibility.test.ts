// Whose a pod session is, in the words both web apps say it (troupe #1169), and what a
// refusal to give it to the team or take it back says.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { ErrorCodes, TroupeRpcError, giveLine, sessionWhose, visibilityRefusal, whoseSentence } from "../src/index.js";

describe("whose a session is", () => {
  it("is the team's, only you to its owner, and by invitation to anybody else", () => {
    assert.equal(sessionWhose("team", true), "the team's");
    assert.equal(sessionWhose("team", false), "the team's");
    assert.equal(sessionWhose("private", true), "only you");
    assert.equal(sessionWhose("private", false), "by invitation");
    assert.equal(sessionWhose(undefined, true), null);
  });

  it("names the team where the row does", () => {
    assert.equal(giveLine("eng"), "Everyone on the eng team can open it, and steer it where the team allows");
    assert.equal(giveLine(null), "Everyone on the team can open it, and steer it where the team allows");
    assert.equal(whoseSentence("private", "eng"), "Only its owner and the people they invited can open it.");
  });

  it("says a refusal in words", () => {
    const refused = (code: number, data?: Record<string, unknown>) =>
      new TroupeRpcError("session.visibility.set", { code, message: "x", ...(data ? { data } : {}) });
    assert.equal(visibilityRefusal(refused(ErrorCodes.forbidden, { required_role: "owner" }), true), "It was not given to the team: only the session's owner gives it to the team or takes it back.");
    assert.equal(visibilityRefusal(refused(ErrorCodes.conflict, { reason: "this session has no team to give it to" }), true), "It was not given to the team: this session has no team to give it to.");
    assert.equal(visibilityRefusal(refused(ErrorCodes.method_not_found), false), "It was not taken back: this plane does not give a session to a team after it started yet.");
  });
});
