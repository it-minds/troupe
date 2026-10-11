// What a plane says about the desktop app's version (#66, Decisions 868 and 874): its
// `initialize` over `/rpc`, with the app's name and version, and every component's policy
// from `me.client_versions`, against the fake plane.

import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";
import { askPlane, suggestion, updateRequiredSentence } from "../src/index.js";
import { startHarness, type Harness } from "./support/harness.js";

let h: Harness | null = null;

afterEach(async () => {
  await h?.stop();
  h = null;
});

describe("the plane's word on the desktop app's version", () => {
  it("is asked at initialize, as troupe-gui with its version, and says suggest below the recommended one", async () => {
    h = await startHarness({ plane: { clientVersions: { desktop: { recommended: "0.15.0-beta", minimum: "0.13.0-beta" } } } });
    const auth = await h.signIn();

    const word = await askPlane(auth, "0.14.0-beta");
    assert.deepEqual(h.plane.initialized, [{ name: "troupe-gui", version: "0.14.0-beta" }]);
    assert.equal(word.state, "served");
    assert.ok(word.state === "served");
    assert.equal(word.clientUpdate?.action, "suggest");
    assert.equal(word.versions?.["desktop"]?.recommended, "0.15.0-beta");
    assert.equal(suggestion(word.clientUpdate, "0.14.0-beta"), "This plane recommends the desktop app 0.15.0-beta, and this is 0.14.0-beta.");

    // At the recommended version there is nothing to say.
    const current = await askPlane(auth, "0.15.0-beta");
    assert.ok(current.state === "served");
    assert.equal(current.clientUpdate?.action, "none");
    assert.equal(suggestion(current.clientUpdate, "0.15.0-beta"), null);
  });

  it("below the minimum, or on a blocked version, is update_required as a sentence, with the policy still asked", async () => {
    h = await startHarness({ plane: { clientVersions: { desktop: { recommended: "0.15.0-beta", minimum: "0.15.0-beta", blocked: ["0.16.0-beta"] } } } });
    const auth = await h.signIn();

    const below = await askPlane(auth, "0.14.0-beta");
    assert.ok(below.state === "required");
    assert.equal(below.sentence, "This plane needs the desktop app 0.15.0-beta or later, and this is 0.14.0-beta: update it now, which installs 0.15.0-beta.");
    assert.equal(below.versions?.["desktop"]?.minimum, "0.15.0-beta");

    const blocked = await askPlane(auth, "0.16.0-beta");
    assert.ok(blocked.state === "required");
    assert.equal(blocked.sentence, "This plane does not serve the desktop app 0.16.0-beta, which its administrators have blocked: update it now, which installs 0.15.0-beta.");
  });

  it("a plane from before the policy says nothing either way", async () => {
    h = await startHarness({ plane: { beforePolicy: true } });
    const auth = await h.signIn();
    assert.deepEqual(await askPlane(auth, "0.14.0-beta"), { state: "unknown" });
  });

  it("a refusal from a plane that sent only a reason is that reason", () => {
    assert.equal(updateRequiredSentence({ reason: "Ask your administrator." }), "Ask your administrator.");
    assert.equal(updateRequiredSentence(undefined), "This plane needs a newer version of this client: update it now.");
  });
});
