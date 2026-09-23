// A reload keeps you signed in.
//
// A reload is a new `AuthSession` over the store the last one wrote to, calling
// `restore()`. The provider rotates the refresh token on every use and refuses the old
// one from then on, so the ways this goes wrong are all about two callers holding the
// same token — React's StrictMode running the load effect twice, a remount, two tabs
// coming back together — and about what is thrown away when the provider says no.

import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import type { TestContext } from "node:test";
import { AuthSession, memoryTokenStore } from "../src/index.js";
import type { TokenStore } from "../src/index.js";
import { startHarness, type Harness } from "./support/harness.js";

/** What went to `console.warn` while the test ran, instead of into the test's output. */
function warnings(t: TestContext): () => string[] {
  const warn = t.mock.method(console, "warn", () => {});
  return () => warn.mock.calls.map((c) => String(c.arguments[0]));
}

/** `fetch`, with the token endpoint's refresh grant passed through `f` first. */
function onRefresh(tokenEndpoint: string, f: (next: () => Promise<Response>) => Promise<Response>): typeof fetch {
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    const isRefresh = String(input) === tokenEndpoint && String(init?.body ?? "").includes("grant_type=refresh_token");
    return isRefresh ? f(() => fetch(input, init)) : fetch(input, init);
  }) as typeof fetch;
}

describe("a reload keeps you signed in", () => {
  let h: Harness;
  before(async () => {
    h = await startHarness();
  });
  after(() => h.stop());

  const key = () => `refresh:${h.plane.baseUrl}`;
  const reload = (store: TokenStore, fetchImpl?: typeof fetch) =>
    new AuthSession({ planeUrl: h.plane.baseUrl, store, ...(fetchImpl ? { fetchImpl } : {}) });

  it("comes back signed in, reload after reload", async () => {
    const store = memoryTokenStore();
    await h.signIn({ store });

    for (let i = 0; i < 3; i += 1) {
      const restored = await reload(store).restore();
      assert.ok(restored, `reload ${i + 1} had to sign in again`);
      assert.equal(restored.subject, "alice@example.com");
      assert.ok(h.idp.refreshTokens.has((await store.read(key()))!), "the stored token is not one the provider still honours");
    }
  });

  it("survives a reload that restores twice at once", async () => {
    // StrictMode's double effect: two sessions over one store, both asking at once.
    // Each read the same token; the provider honoured one and refused the other, and
    // the refused one cleared the store — taking the token the first had just been
    // given with it.
    const store = memoryTokenStore();
    await h.signIn({ store });

    const [first, second] = await Promise.all([reload(store).restore(), reload(store).restore()]);
    assert.ok(first, "the first restore was refused");
    assert.ok(second, "the second restore was refused");

    const stored = await store.read(key());
    assert.ok(stored, "the store was emptied");
    assert.ok(h.idp.refreshTokens.has(stored), "the stored token is not one the provider still honours");
    assert.ok(await reload(store).restore(), "the next reload had to sign in again");
  });

  it("takes turns within the page where the host has no Web Locks", async (t) => {
    // An origin that is not a secure context has no `navigator.locks`; Node has them,
    // so without this the test above only ever proves the Web Locks path.
    const real = Object.getOwnPropertyDescriptor(globalThis, "navigator");
    Object.defineProperty(globalThis, "navigator", { value: {}, configurable: true });
    t.after(() => {
      if (real) Object.defineProperty(globalThis, "navigator", real);
    });

    const store = memoryTokenStore();
    await h.signIn({ store });
    const all = await Promise.all([1, 2, 3].map(() => reload(store).restore()));
    assert.ok(all.every(Boolean), "a restore was refused");
    assert.ok(h.idp.refreshTokens.has((await store.read(key()))!));
  });

  it("says why the provider refused, and forgets only the token it refused", async (t) => {
    const logged = warnings(t);
    const store = memoryTokenStore();
    await h.signIn({ store });
    const refused = (await store.read(key()))!;
    h.idp.revoke(refused);

    // A sign-in in another tab lands while the refused refresh is on its way back.
    const elsewhere = onRefresh(h.idp.tokenEndpoint, async (next) => {
      await store.write(key(), "rt-from-another-tab");
      return next();
    });
    assert.equal(await reload(store, elsewhere).restore(), null);
    assert.equal(await store.read(key()), "rt-from-another-tab", "a token nobody refused was thrown away");
    assert.match(logged().join("\n"), /refused the stored sign-in .* \(HTTP 400 invalid_grant\)/);

    // With nobody else writing, the refused one goes.
    await store.write(key(), refused);
    assert.equal(await reload(store).restore(), null);
    assert.equal(await store.read(key()), null);
  });

  it("puts the provider's reason in the error a renewal fails with", async (t) => {
    warnings(t);
    const store = memoryTokenStore();
    await h.signIn({ store });
    // An hour on, so the plane token in hand is due and the next call renews.
    const later = new AuthSession({ planeUrl: h.plane.baseUrl, store, now: () => Date.now() + 3_600_000 });
    assert.ok(await later.restore());
    h.idp.revoke((await store.read(key()))!);

    await assert.rejects(() => later.rpc("sessions.list"), /signed out: the identity provider would not renew this session \(HTTP 400 invalid_grant\)/);
  });

  it("keeps the token when the provider fails to answer", async () => {
    const store = memoryTokenStore();
    await h.signIn({ store });
    const held = await store.read(key());

    const down = onRefresh(h.idp.tokenEndpoint, async () => new Response("upstream connect error", { status: 503 }));
    await assert.rejects(() => reload(store, down).restore(), /HTTP 503/);
    assert.equal(await store.read(key()), held, "a provider's bad minute cost the person their sign-in");
    assert.ok(await reload(store).restore(), "and once it answers again, the reload signs back in");
  });

  it("says so when a sign-in brings no refresh token, since the next reload will ask again", async (t) => {
    const logged = warnings(t);
    h.idp.offlineAccess = false;
    t.after(() => {
      h.idp.offlineAccess = true;
    });

    const store = memoryTokenStore();
    const auth = await h.signIn({ store });
    assert.ok(auth.signedIn);
    assert.equal(await store.read(key()), null);
    assert.match(logged().join("\n"), /issued no refresh token .* "offline_access"/);
  });
});
