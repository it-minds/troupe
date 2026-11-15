// The sentence a person reads when the plane does not answer: what happened, and what
// they can do, with the plane's allowlist named only where it can be the reason.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AuthSession, PlaneUnreachableError, memoryReachedMarks, memoryTokenStore } from "../src/index.js";

const PLANE = "https://plane.example.com";
const DISCOVERY = {
  plane: { protocol_version: "1" },
  issuer: "https://idp.example.com",
  client_id: "troupe",
  token_endpoint: "https://plane.example.com/token",
  scopes: ["openid"],
};

/** A fetch that answers discovery until `down` is set, and fails as a dead plane does after. */
function flaky(): { fetchImpl: typeof fetch; down: () => void } {
  let up = true;
  const fetchImpl = (async () => {
    if (!up) throw new TypeError("Failed to fetch");
    return new Response(JSON.stringify(DISCOVERY), { status: 200, headers: { "content-type": "application/json" } });
  }) as unknown as typeof fetch;
  return { fetchImpl, down: () => void (up = false) };
}

const dead = (async () => {
  throw new TypeError("Failed to fetch");
}) as unknown as typeof fetch;

async function failure(p: Promise<unknown>): Promise<PlaneUnreachableError> {
  const e = await p.then(
    () => null,
    (err: unknown) => err,
  );
  assert.ok(e instanceof PlaneUnreachableError, `expected PlaneUnreachableError, got ${String(e)}`);
  return e;
}

describe("the plane did not answer", () => {
  it("starts with a capital and says the plane did not answer", () => {
    const e = new PlaneUnreachableError(PLANE, null, new TypeError("x"));
    assert.match(e.message, /^The plane at https:\/\/plane\.example\.com did not answer\. /);
  });

  it("asks a first attempt to check the address, and names no allowlist outside a browser", () => {
    const e = new PlaneUnreachableError(PLANE, null, new TypeError("x"));
    assert.match(e.message, /Check the address and try again\./);
    assert.match(e.message, /ask your administrator/);
    assert.doesNotMatch(e.message, /TROUPE_CORS_ORIGINS/);
  });

  it("names no allowlist to a page on the plane's own origin", () => {
    const e = new PlaneUnreachableError(PLANE, PLANE, new TypeError("x"));
    assert.match(e.message, /Check the address and try again\./);
    assert.doesNotMatch(e.message, /TROUPE_CORS_ORIGINS/);
  });

  it("names the allowlist, and the origin to add, to a cross-origin page that has never reached this plane", () => {
    const e = new PlaneUnreachableError(PLANE, "http://localhost:5173", new TypeError("x"));
    assert.match(e.message, /Check the address and try again\./);
    assert.match(e.message, /an administrator adds http:\/\/localhost:5173 to TROUPE_CORS_ORIGINS/);
  });

  it("names no allowlist to a cross-origin page that has reached this plane before", () => {
    const e = new PlaneUnreachableError(PLANE, "http://localhost:5173", new TypeError("x"), { reachedBefore: true });
    assert.match(e.message, /Check the address and try again\./);
    assert.doesNotMatch(e.message, /TROUPE_CORS_ORIGINS/);
  });

  it("tells a session that had reached the plane that it answered a moment ago, and names no address or allowlist", () => {
    const e = new PlaneUnreachableError(PLANE, "http://localhost:5173", new TypeError("x"), { reached: true });
    assert.match(e.message, /It answered a moment ago; try again in a moment/);
    assert.doesNotMatch(e.message, /Check the address|TROUPE_CORS_ORIGINS/);
    assert.equal(e.reached, true);
  });

  it("knows on its own that a session had reached the plane before it stopped answering", async () => {
    const { fetchImpl, down } = flaky();
    const store = memoryTokenStore();
    await store.write(`refresh:${PLANE}`, "a-refresh-token");
    const auth = new AuthSession({ planeUrl: PLANE, store, fetchImpl, origin: "http://localhost:5173", reachedMarks: memoryReachedMarks() });
    await auth.discover();
    down();
    const e = await failure(auth.restore());
    assert.equal(e.reached, true);
    assert.match(e.message, /It answered a moment ago/);
  });

  it("remembers, across sessions on this origin, that the plane answered once, and stops naming the allowlist", async () => {
    const marks = memoryReachedMarks();
    const origin = "http://localhost:5173";
    const first = await failure(new AuthSession({ planeUrl: PLANE, fetchImpl: dead, origin, reachedMarks: marks }).discover());
    assert.match(first.message, /TROUPE_CORS_ORIGINS/, "never reached: the allowlist may be why");

    await new AuthSession({ planeUrl: PLANE, fetchImpl: flaky().fetchImpl, origin, reachedMarks: marks }).discover();
    assert.ok(marks.has(PLANE), "an answer marks the plane reached");

    const later = await failure(new AuthSession({ planeUrl: PLANE, fetchImpl: dead, origin, reachedMarks: marks }).discover());
    assert.equal(later.reached, false, "a new session has not reached it yet");
    assert.match(later.message, /Check the address and try again\./);
    assert.doesNotMatch(later.message, /TROUPE_CORS_ORIGINS/, "it answered this origin once, so the allowlist is not the reason");
  });
});
