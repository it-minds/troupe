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

  // #657: the policy is the plane's word only as its own key signed it.
  it("a signed policy is taken as the pinned key signed it, with where releases are", async () => {
    h = await startHarness({ plane: { clientVersions: { desktop: { recommended: "0.22.0-beta" } } } });
    const pinned = await h.plane.sign();
    h.plane.releaseUrl = "https://mirror.example.test/troupe";
    const auth = await h.signIn();

    const word = await askPlane(auth, "0.21.0-beta", pinned);
    assert.ok(word.state === "served");
    assert.deepEqual(word.signature, { state: "signed" });
    assert.equal(word.versions?.["desktop"]?.recommended, "0.22.0-beta");
    assert.equal(word.versions?.["release"], undefined);
    assert.equal(word.releaseUrl, "https://mirror.example.test/troupe");
  });

  it("a policy signed by another key is not acted on, and says which key signed it", async () => {
    h = await startHarness({ plane: { clientVersions: { desktop: { recommended: "0.22.0-beta" } } } });
    const pinned = await h.plane.sign();
    const rotated = await h.plane.sign();
    const auth = await h.signIn();

    const word = await askPlane(auth, "0.21.0-beta", pinned);
    assert.ok(word.state === "served");
    assert.equal(word.versions, null);
    assert.ok(word.signature?.state === "refused");
    assert.match(word.signature.sentence, new RegExp(`is signed by the key ${rotated.fingerprint.replace(/[+/]/g, "\\$&")}, not by`));
  });

  it("a plane that signs nothing is taken at its word, and that said; one with a key and none pinned here is unchecked", async () => {
    h = await startHarness({ plane: { clientVersions: { desktop: { recommended: "0.22.0-beta" } } } });
    const auth = await h.signIn();

    const unsigned = await askPlane(auth, "0.21.0-beta", null);
    assert.ok(unsigned.state === "served");
    assert.equal(unsigned.versions?.["desktop"]?.recommended, "0.22.0-beta");
    assert.ok(unsigned.signature?.state === "unsigned");
    assert.match(unsigned.signature.line, /signs nothing it tells clients/);

    await h.plane.sign();
    const unchecked = await askPlane(auth, "0.21.0-beta", null);
    assert.ok(unchecked.state === "served");
    assert.deepEqual(unchecked.signature, { state: "unchecked" });
    assert.equal(unchecked.versions?.["signed"], undefined);
  });

  it("keeps the signed policy as it came, for the shell to check again itself", async () => {
    h = await startHarness({ plane: { clientVersions: { desktop: { recommended: "0.22.0-beta" } } } });
    const pinned = await h.plane.sign();
    h.plane.releaseUrl = "https://mirror.example.test/troupe";
    const auth = await h.signIn();

    const word = await askPlane(auth, "0.21.0-beta", pinned);
    assert.ok(word.state === "served");
    assert.equal(word.signed?.fingerprint, pinned.fingerprint);
    assert.match(word.signed?.document ?? "", /"kind":"client_versions"/);

    // With no key pinned to check it by, there is nothing to hand on.
    const unchecked = await askPlane(auth, "0.21.0-beta", null);
    assert.ok(unchecked.state === "served");
    assert.equal(unchecked.signed, undefined);
  });

  it("a refusal of this version is acted on as the pinned key signed it, and not otherwise", async () => {
    h = await startHarness({ plane: { clientVersions: { desktop: { recommended: "0.15.0-beta", minimum: "0.15.0-beta" } } } });
    const pinned = await h.plane.sign();
    const auth = await h.signIn();

    const signed = await askPlane(auth, "0.14.0-beta", pinned);
    assert.ok(signed.state === "required");
    assert.equal(signed.sentence, "This plane needs the desktop app 0.15.0-beta or later, and this is 0.14.0-beta: update it now, which installs 0.15.0-beta.");
    assert.equal((signed.refusal as Record<string, unknown>)["signed"], undefined);

    // The same refusal unsigned, from a plane whose key is pinned here: not its word.
    h.plane.unsignedRefusals = true;
    const unsigned = await askPlane(auth, "0.14.0-beta", pinned);
    assert.ok(unsigned.state === "served");
    assert.equal(unsigned.clientUpdate, null);
    assert.ok(unsigned.signature?.state === "refused");
    assert.match(unsigned.signature.sentence, /^the plane's refusal of this version from .* is not signed, and this machine holds the plane's signing key/);

    // Signed by another key than the one pinned: not its word either.
    h.plane.unsignedRefusals = false;
    await h.plane.sign();
    const rotated = await askPlane(auth, "0.14.0-beta", pinned);
    assert.ok(rotated.state === "served");
    assert.ok(rotated.signature?.state === "refused");

    // A plane nothing is pinned for is taken at its word, as before.
    h.plane.unsignedRefusals = true;
    const unpinned = await askPlane(auth, "0.14.0-beta", null);
    assert.ok(unpinned.state === "required");
  });

  it("a refusal from a plane that sent only a reason is that reason", () => {
    assert.equal(updateRequiredSentence({ reason: "Ask your administrator." }), "Ask your administrator.");
    assert.equal(updateRequiredSentence(undefined), "This plane needs a newer version of this client: update it now.");
  });
});
