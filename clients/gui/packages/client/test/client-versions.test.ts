// The order a version policy is judged in, as the plane judges it: SemVer's, with a
// pre-release before its release, and a version SemVer cannot read held to `blocked` alone.

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { clientStanding, releaseVersion, versionOlder } from "../src/index.js";

describe("client versions, as the plane orders them", () => {
  it("reads a version as releases are numbered, and nothing else", () => {
    assert.equal(releaseVersion("0.38.0-beta"), "0.38.0-beta");
    assert.equal(releaseVersion("v0.38.0"), "0.38.0");
    assert.equal(releaseVersion(" 1.2.3+abc "), "1.2.3");
    assert.equal(releaseVersion("dev"), null);
    assert.equal(releaseVersion("0.38"), null);
  });

  it("orders the numbers, then a pre-release before its release", () => {
    assert.equal(versionOlder("0.16.0-beta", "0.38.0-beta"), true);
    assert.equal(versionOlder("0.9.0", "0.10.0"), true);
    assert.equal(versionOlder("0.38.0-beta", "0.38.0"), true);
    assert.equal(versionOlder("0.38.0", "0.38.0-beta"), false);
    assert.equal(versionOlder("0.38.0-beta.2", "0.38.0-beta.10"), true);
    assert.equal(versionOlder("0.38.0-beta", "0.38.0-beta"), false);
    assert.equal(versionOlder("dev", "0.38.0"), false);
  });

  it("judges a client against a policy: refused, behind or current", () => {
    const policy = { recommended: "0.38.0-beta", minimum: "0.14.0-beta", blocked: ["0.15.0-beta"] };
    assert.equal(clientStanding(policy, "0.13.0-beta"), "refused");
    assert.equal(clientStanding(policy, "0.15.0-beta"), "refused");
    assert.equal(clientStanding(policy, "0.16.0-beta"), "behind");
    assert.equal(clientStanding(policy, "0.38.0-beta"), "current");
    assert.equal(clientStanding(policy, "dev"), "current");
  });
});
