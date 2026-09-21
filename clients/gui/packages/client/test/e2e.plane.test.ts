// End to end against a real plane, a real identity provider, Postgres and OpenBao.
//
// The rest of the suite runs against `test/support` — an identity provider, a plane and
// a worker written here. They prove this client behaves correctly when a server behaves
// as PROTOCOL.md says. They cannot prove a real server does, and `docs/developer/
// testing.md` says so under "What is not tested: the server's half".
//
// This is that half, for the plane: real discovery, a real device grant against Dex,
// real refresh-token rotation, a real `/auth/exchange`, and a real CORS allowlist.
// `dev/plane-stack.yml` brings it up without Kubernetes and without Elixir; docs/e2e.md
// has the commands. Without `TROUPE_E2E_PLANE` every test here skips, so `pnpm test`
// stays runnable anywhere.

import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { AuthSession, FleetStore, PlaneClient, PlaneSource, memoryTokenStore } from "../src/index.js";
import type { DeviceAuthorization, Discovery, TokenStore } from "../src/index.js";

const PLANE = process.env["TROUPE_E2E_PLANE"];
const USER = process.env["TROUPE_E2E_USER"] ?? "ada@example.test";
const PASSWORD = process.env["TROUPE_E2E_PASSWORD"] ?? "troupe";
const skip = PLANE ? false : "set TROUPE_E2E_PLANE to run against a real plane (docs/e2e.md)";

/**
 * Approve a device code at Dex the way a person would: type the code, sign in, and let
 * the approval screen be skipped. Three form posts and a redirect chain — doing it here
 * is what makes "sign in" a test rather than something somebody has to sit through.
 */
async function approveAtDex(issuer: string, device: DeviceAuthorization): Promise<void> {
  const base = new URL(issuer);
  const abs = (loc: string) => new URL(loc.replace(/&amp;/g, "&"), base).href;
  const form = { "content-type": "application/x-www-form-urlencoded" };

  let res = await fetch(abs("/dex/device/auth/verify_code"), {
    method: "POST",
    redirect: "manual",
    headers: form,
    body: new URLSearchParams({ user_code: device.user_code }),
  });

  // Follow the chain until a page renders; that page is the login form.
  let location = res.headers.get("location");
  let body = "";
  for (let hop = 0; hop < 8 && location; hop++) {
    res = await fetch(abs(location), { redirect: "manual" });
    location = res.headers.get("location");
    if (!location) body = await res.text();
  }
  assert.ok(body.includes('name="password"'), "reached Dex's login form");

  const action = /<form[^>]*action="([^"]+)"/.exec(body)?.[1];
  assert.ok(action, "the login form has an action");
  res = await fetch(abs(action), {
    method: "POST",
    redirect: "manual",
    headers: form,
    body: new URLSearchParams({ login: USER, password: PASSWORD }),
  });

  // …and on through the approval and the device callback.
  location = res.headers.get("location");
  for (let hop = 0; hop < 8 && location; hop++) {
    res = await fetch(abs(location), { redirect: "manual" });
    location = res.headers.get("location");
  }
  assert.ok(res.status < 400, `the device code was approved (last status ${res.status})`);
}

describe("against a real plane", { skip }, () => {
  let discovery: Discovery;

  before(async () => {
    if (!PLANE) return;
    discovery = await new PlaneClient(PLANE).discover();
  });

  /**
   * A real sign-in. The store's own device grant, approved out of band while it polls,
   * which is the shape of the real thing: the app waits, a person approves elsewhere.
   */
  async function signIn(store: TokenStore = memoryTokenStore()): Promise<AuthSession> {
    const auth = new AuthSession({ planeUrl: PLANE!, store, flow: "device" });
    let approving: Promise<void> | undefined;
    await auth.signIn({
      onDeviceCode: (device) => {
        approving = approveAtDex(discovery.issuer, device);
      },
    });
    await approving;
    return auth;
  }

  it("publishes a discovery document naming a provider a client can use", async () => {
    assert.equal(discovery.plane.protocol_version, "1");
    assert.ok(discovery.client_id, "a client id");
    assert.ok(discovery.device_authorization_endpoint.startsWith("http"), "a device endpoint");
    assert.ok(discovery.token_endpoint.startsWith("http"), "a token endpoint");

    // And the provider it names is really one: its own metadata has to answer, or the
    // grant fails later in a way that looks like this client's bug.
    const idp = await fetch(new URL("/dex/.well-known/openid-configuration", discovery.issuer).href);
    assert.equal(idp.status, 200, "the issuer answers its own discovery");
  });

  it("signs a person in with the device grant, and says who they are", async () => {
    const auth = await signIn();

    assert.equal(auth.signedIn, true);
    assert.ok(auth.me?.subject, "the credential carries a subject");
    const token = await auth.token();
    assert.ok(token.length > 20, "and buys a plane token");

    const me = await auth.rpc<{ subject?: string }>("me", {});
    assert.ok(me.subject, `me() answers over /rpc: ${JSON.stringify(me).slice(0, 200)}`);
  });

  it("comes back signed in from a stored refresh token, with no second approval", async () => {
    const store = memoryTokenStore();
    await signIn(store);

    // A new process, the same store, and nothing to approve a device code with.
    const relaunched = new AuthSession({ planeUrl: PLANE!, store, flow: "device" });
    const credential = await relaunched.restore();

    assert.ok(credential, "restored without asking the person");
    assert.ok((await relaunched.token()).length > 20, "and can mint a plane token");
  });

  it("keeps a refresh token and never a plane token", async () => {
    const store = memoryTokenStore();
    const auth = await signIn(store);
    const planeToken = await auth.token();

    const kept = await store.read(`refresh:${PLANE!.replace(/\/+$/, "")}`);
    assert.ok(kept, "a refresh token was stored");
    assert.notEqual(kept, planeToken, "and it is not the plane token");
    assert.ok(!kept!.includes(planeToken.slice(0, 24)), "nor does it contain one");
  });

  it("answers a browser only from an origin on its allowlist", async () => {
    // `PlaneUnreachableError` tells people to add their origin to TROUPE_CORS_ORIGINS.
    // This asserts that the setting it names really is the one that decides — against a
    // real plane, where Node's fetch does not enforce CORS and so cannot flatter us.
    const allowed = await fetch(`${PLANE}/.well-known/troupe`, { headers: { origin: "http://localhost:5173" } });
    assert.equal(
      allowed.headers.get("access-control-allow-origin"),
      "http://localhost:5173",
      "an origin on the list is allowed by name",
    );

    const refused = await fetch(`${PLANE}/.well-known/troupe`, { headers: { origin: "http://evil.example" } });
    assert.notEqual(refused.headers.get("access-control-allow-origin"), "http://evil.example");
    assert.notEqual(refused.headers.get("access-control-allow-origin"), "*", "and the list is not a wildcard");
  });

  it("lists sessions into the fleet store, in the shapes it parses", async () => {
    const auth = await signIn();
    const fleet = new FleetStore([new PlaneSource(auth.plane, () => auth.token())]);
    await fleet.refresh();
    const snapshot = fleet.current;

    assert.equal(snapshot.sources["plane"]?.error, null, `the plane source answered: ${snapshot.sources["plane"]?.error}`);
    assert.ok(Array.isArray(snapshot.rows), "and produced rows (an empty plane has none)");
    for (const row of snapshot.rows) {
      assert.ok(row.id, "every row has an id the session view can open");
      assert.equal(row.kind, "team");
    }
  });

  it("offers what a profile carries, before anything is created", async () => {
    const auth = await signIn();
    const { profiles } = await auth.rpc<{ profiles?: unknown[] }>("profiles.list", {});
    // A plane with no bundle published legitimately has none; what matters is that the
    // call is answered and shaped, not that this particular plane has any.
    for (const p of (profiles ?? []) as Array<Record<string, unknown>>) {
      assert.ok(typeof p["name"] === "string", "a profile has a name");
      assert.ok(Array.isArray(p["agents"]), "and the agents the dialog offers");
    }
  });

  it("refuses to place a session when there is nowhere to put it, and says why", async () => {
    // There is no worker in this stack. The interesting part is the failure mode: the
    // GUI renders whatever comes back, so it has to be a refusal with a reason rather
    // than a hang or a 500.
    const auth = await signIn();
    const profile = auth.me?.profiles?.[0] ?? "dev";
    await assert.rejects(
      auth.rpc("session.create", { profile }),
      (e: Error) => {
        assert.match(e.message, /capacity|not_found|forbidden|no worker|profile/i, `a stated reason: ${e.message}`);
        return true;
      },
    );
  });

  after(() => {
    /* nothing to tear down: every session here is HTTP */
  });
});
