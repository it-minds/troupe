// The break-glass door: a plane token for the break-glass token, and a session that is
// nothing but that token. It leans on the identity provider for nothing, which is the
// point on the day the provider signs nobody in, and it ends when the token does.

import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { AuthSession, PlaneHttpError, memoryTokenStore } from "../src/index.js";
import { FakeIdp } from "./support/idp.js";
import { BREAKGLASS_SUBJECT, FakePlane } from "./support/plane.js";
import { FakeWorker } from "./support/worker.js";

const GLASS = "glass-7a1f";

describe("the break-glass door", () => {
  let idp: FakeIdp;
  let worker: FakeWorker;
  let withDoor: FakePlane;
  let shortLived: FakePlane;
  let noDoor: FakePlane;

  before(async () => {
    idp = await FakeIdp.start();
    worker = await FakeWorker.start();
    withDoor = await FakePlane.start({ idp, worker, breakglass: GLASS });
    shortLived = await FakePlane.start({ idp, worker, breakglass: GLASS, breakglassLifetime: 1 });
    noDoor = await FakePlane.start({ idp, worker });
  });
  after(async () => {
    await noDoor.stop();
    await shortLived.stop();
    await withDoor.stop();
    await worker.stop();
    await idp.stop();
  });

  it("discovery says whether the plane has one", async () => {
    assert.equal((await new AuthSession({ planeUrl: withDoor.baseUrl }).discover()).breakglass, true);
    assert.equal((await new AuthSession({ planeUrl: noDoor.baseUrl }).discover()).breakglass, false);
  });

  it("signs in as the break-glass subject, a platform admin with no teams, and nothing is kept for a reload", async () => {
    const auth = await AuthSession.breakGlass(withDoor.baseUrl, GLASS);
    assert.equal(auth.isBreakGlass, true);
    assert.equal(auth.signedIn, true);
    assert.equal(auth.me?.subject, BREAKGLASS_SUBJECT);
    assert.equal(auth.me?.breakglass, true);
    assert.deepEqual(auth.me?.teams, []);
    assert.ok((auth.me?.expires_at ?? 0) * 1000 > Date.now(), "the credential carries when it ends");

    // The token works over `/rpc`, and the plane's `me` marks the session.
    const me = await auth.rpc<{ subject: string; platform_admin?: boolean; breakglass?: boolean; teams: unknown[] }>("me");
    assert.equal(me.subject, BREAKGLASS_SUBJECT);
    assert.equal(me.platform_admin, true);
    assert.equal(me.breakglass, true);
    assert.deepEqual(me.teams, []);
    assert.equal(withDoor.asked.filter((m) => m === "me").length, 2, "me is asked once at the exchange and once here");

    // Nothing to restore: a new session over any store on this plane finds nothing.
    assert.equal(await new AuthSession({ planeUrl: withDoor.baseUrl, store: memoryTokenStore() }).restore(), null);
    assert.equal(await auth.restore(), null);

    await auth.signOut();
    assert.equal(auth.signedIn, false);
    await assert.rejects(auth.token(), /break-glass session has been signed out/);
  });

  it("says in a sentence that a wrong token was refused", async () => {
    await assert.rejects(AuthSession.breakGlass(withDoor.baseUrl, "not-the-token"), (e: unknown) => {
      assert.ok(e instanceof Error);
      assert.match(e.message, /refused this break-glass token/);
      assert.ok(!(e instanceof PlaneHttpError), "the refusal is said, not passed through as a status");
      return true;
    });
  });

  it("says in a sentence that a plane without a door has none", async () => {
    await assert.rejects(AuthSession.breakGlass(noDoor.baseUrl, GLASS), /no break-glass door/);
  });

  it("answers the token until it expires, then throws that the session ended, and tells whoever listens", async () => {
    let clock = Date.now();
    const auth = await AuthSession.breakGlass(shortLived.baseUrl, GLASS, { now: () => clock });
    const heard: string[] = [];
    auth.onEnded((why) => heard.push(why));
    const token = await auth.token();
    assert.ok(token.startsWith("bg-"));

    clock = (auth.me!.expires_at + 1) * 1000;
    await assert.rejects(auth.token(), /The break-glass session ended at .*: nothing renews it/);
    assert.equal(heard.length, 1, "the listener heard once");
    assert.match(heard[0]!, /break-glass session ended/);
    assert.equal(auth.signedIn, false);
    // Said again on every call, without another word to the listener.
    await assert.rejects(auth.token(), /break-glass session/);
    assert.equal(heard.length, 1);
  });

  it("is refused by the plane once the token has really expired", async () => {
    const auth = await AuthSession.breakGlass(shortLived.baseUrl, GLASS);
    await new Promise((r) => setTimeout(r, 1100));
    await assert.rejects(auth.rpc("me"), /break-glass session ended/);
  });
});
