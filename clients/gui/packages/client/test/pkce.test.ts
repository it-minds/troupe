// The authorization code flow with PKCE.
//
// The parts worth pinning down are the ones a provider will not forgive: the challenge
// really is the SHA-256 of the verifier, the state is checked, the verifier is spent
// once, and a provider's error comes back as an error rather than as a hang.

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { afterEach, beforeEach, describe, it } from "node:test";
import { beginRedirect, completeRedirect, hasRedirectAnswer, idpMetadata, pkcePair } from "../src/index.js";
import type { Discovery } from "../src/index.js";

/** `sessionStorage` is a browser thing; the flow only needs these three methods. */
function fakeSessionStorage(): Storage & { map: Map<string, string> } {
  const map = new Map<string, string>();
  return {
    map,
    get length() {
      return map.size;
    },
    clear: () => map.clear(),
    getItem: (k: string) => map.get(k) ?? null,
    key: (i: number) => [...map.keys()][i] ?? null,
    removeItem: (k: string) => void map.delete(k),
    setItem: (k: string, v: string) => void map.set(k, v),
  } as Storage & { map: Map<string, string> };
}

const ISSUER = "https://idp.example.com/tenant/v2.0";
const AUTHORIZE = "https://idp.example.com/tenant/oauth2/v2.0/authorize";
const TOKEN = "https://idp.example.com/tenant/oauth2/v2.0/token";

const discovery: Discovery = {
  issuer: ISSUER,
  client_id: "the-client",
  device_authorization_endpoint: "https://idp.example.com/tenant/oauth2/v2.0/devicecode",
  token_endpoint: TOKEN,
  scopes: ["openid", "profile", "offline_access"],
  plane: { name: "troupe", rpc: "/rpc", jwks: "/.well-known/jwks.json", protocol_version: "1" },
};

/** A provider that publishes metadata and answers the token endpoint. */
function fakeIdpFetch(over: { tokenStatus?: number; tokenBody?: unknown } = {}): typeof fetch & { seen: Array<{ url: string; body: URLSearchParams }> } {
  const seen: Array<{ url: string; body: URLSearchParams }> = [];
  const impl = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    const body = new URLSearchParams(typeof init?.body === "string" ? init.body : (init?.body as URLSearchParams)?.toString() ?? "");
    seen.push({ url, body });

    if (url.endsWith("/.well-known/openid-configuration")) {
      return new Response(JSON.stringify({ issuer: ISSUER, authorization_endpoint: AUTHORIZE, token_endpoint: TOKEN }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }
    if (url === TOKEN) {
      const status = over.tokenStatus ?? 200;
      const payload = over.tokenBody ?? { id_token: "an.id.token", refresh_token: "rt-1", expires_in: 3600 };
      return new Response(JSON.stringify(payload), { status, headers: { "content-type": "application/json" } });
    }
    return new Response("not found", { status: 404 });
  }) as typeof fetch & { seen: typeof seen };
  impl.seen = seen;
  return impl;
}

const globals = globalThis as unknown as { sessionStorage?: Storage };
let storage: ReturnType<typeof fakeSessionStorage>;

beforeEach(() => {
  storage = fakeSessionStorage();
  globals.sessionStorage = storage;
});
afterEach(() => {
  delete globals.sessionStorage;
});

describe("PKCE", () => {
  it("makes a challenge that is really the SHA-256 of the verifier", async () => {
    const { verifier, challenge, method } = await pkcePair();
    assert.equal(method, "S256");
    assert.ok(verifier.length >= 43 && verifier.length <= 128, `verifier was ${verifier.length} characters`);
    assert.match(verifier, /^[A-Za-z0-9\-._~]+$/, "the verifier used a character outside the unreserved set");

    const expected = createHash("sha256").update(verifier).digest("base64url");
    assert.equal(challenge, expected);
  });

  it("two pairs are not the same pair", async () => {
    const [a, b] = await Promise.all([pkcePair(), pkcePair()]);
    assert.notEqual(a.verifier, b.verifier);
    assert.notEqual(a.challenge, b.challenge);
  });
});

describe("the authorization endpoint", () => {
  it("is taken from the provider's own metadata when the plane does not publish one", async () => {
    const http = fakeIdpFetch();
    const metadata = await idpMetadata(discovery, http);
    assert.equal(metadata.authorization_endpoint, AUTHORIZE);
    assert.ok(http.seen.some((r) => r.url.endsWith("/.well-known/openid-configuration")));
  });

  it("is taken from the plane when it does publish one, with no second request", async () => {
    const http = fakeIdpFetch();
    const published = { ...discovery, authorization_endpoint: "https://idp.example.com/elsewhere/authorize" };
    const metadata = await idpMetadata(published, http);
    assert.equal(metadata.authorization_endpoint, "https://idp.example.com/elsewhere/authorize");
    assert.equal(http.seen.length, 0, "the provider was asked for metadata it did not need to be asked for");
  });
});

describe("the redirect", () => {
  it("sends everything the provider needs and keeps the verifier at home", async () => {
    const { url, state } = await beginRedirect({
      discovery,
      redirectUri: "http://localhost:5173",
      planeUrl: "https://plane.example.com",
      fetchImpl: fakeIdpFetch(),
      prompt: "select_account",
    });

    const parsed = new URL(url);
    assert.equal(parsed.origin + parsed.pathname, AUTHORIZE);
    const q = parsed.searchParams;
    assert.equal(q.get("client_id"), "the-client");
    assert.equal(q.get("response_type"), "code");
    assert.equal(q.get("redirect_uri"), "http://localhost:5173");
    assert.equal(q.get("code_challenge_method"), "S256");
    assert.equal(q.get("state"), state);
    assert.equal(q.get("prompt"), "select_account");
    assert.equal(q.get("scope"), "openid profile offline_access");

    // The verifier is the one thing that must never be in that URL.
    const held = JSON.parse(storage.getItem("troupe.auth.pending")!) as { verifier: string };
    assert.ok(held.verifier);
    assert.equal(url.includes(held.verifier), false, "the verifier was sent to the provider");
    assert.equal(q.get("code_challenge"), createHash("sha256").update(held.verifier).digest("base64url"));
  });

  it("redeems the code with the verifier it kept, and only once", async () => {
    const http = fakeIdpFetch();
    const { state } = await beginRedirect({
      discovery,
      redirectUri: "http://localhost:5173",
      planeUrl: "https://plane.example.com",
      fetchImpl: http,
    });
    const held = JSON.parse(storage.getItem("troupe.auth.pending")!) as { verifier: string };
    const back = `http://localhost:5173/?code=the-code&state=${state}`;

    assert.equal(hasRedirectAnswer(back), true);
    const answer = await completeRedirect(back, http);
    assert.equal(answer?.tokens.refresh_token, "rt-1");
    assert.equal(answer?.planeUrl, "https://plane.example.com");

    const exchange = http.seen.find((r) => r.url === TOKEN)!;
    assert.equal(exchange.body.get("grant_type"), "authorization_code");
    assert.equal(exchange.body.get("code"), "the-code");
    assert.equal(exchange.body.get("code_verifier"), held.verifier);
    assert.equal(exchange.body.get("redirect_uri"), "http://localhost:5173");
    assert.equal(exchange.body.has("client_secret"), false, "a public client sent a secret");

    // A verifier is spent: replaying the same URL answers from what was already
    // redeemed rather than asking the provider a second time.
    assert.deepEqual(await completeRedirect(back, http), answer);
    assert.equal(http.seen.filter((r) => r.url === TOKEN).length, 1, "the code was redeemed twice");

    // A *different* code has nothing stored for it and says so.
    await assert.rejects(
      () => completeRedirect(`http://localhost:5173/?code=another&state=${state}`, http),
      /did not start in this browser/,
    );
  });

  it("tells a tenant-scoped Microsoft picker to stop offering personal accounts", async () => {
    // An issuer naming one tenant admits that tenant's work accounts and nothing else,
    // so a personal account fails *after* the password. The hint says so beforehand.
    const entra: Discovery = {
      ...discovery,
      issuer: "https://login.microsoftonline.com/9c5bd6eb-62ce-4a2d-97c6-0acc1ccfec55/v2.0",
    };
    const http = fakeIdpFetch();
    const { url } = await beginRedirect({ discovery: entra, redirectUri: "http://localhost:5173", planeUrl: "https://p", fetchImpl: http });
    assert.equal(new URL(url).searchParams.get("domain_hint"), "organizations");

    // `common` is deliberately for everybody, so it is left alone.
    const common = { ...entra, issuer: "https://login.microsoftonline.com/common/v2.0" };
    const one = await beginRedirect({ discovery: common, redirectUri: "http://localhost:5173", planeUrl: "https://p", fetchImpl: http });
    assert.equal(new URL(one.url).searchParams.has("domain_hint"), false);

    // A provider that is not Microsoft gets no Microsoft-specific parameter invented.
    const other = await beginRedirect({ discovery, redirectUri: "http://localhost:5173", planeUrl: "https://p", fetchImpl: http });
    assert.equal(new URL(other.url).searchParams.has("domain_hint"), false);

    // And a caller who knows the domain can skip the picker altogether.
    const hinted = await beginRedirect({
      discovery: entra,
      redirectUri: "http://localhost:5173",
      planeUrl: "https://p",
      fetchImpl: http,
      domainHint: "itminds.dk",
    });
    assert.equal(new URL(hinted.url).searchParams.get("domain_hint"), "itminds.dk");
  });

  it("redeems one code once, however many callers ask at once", async () => {
    // React's StrictMode runs an effect twice in development: the first call takes the
    // verifier and waits on the provider, and the second lands while it is still in the
    // air. Before this was shared, the second found nothing stored and reported that the
    // sign-in had begun somewhere else — so a sign-in that had in fact just succeeded
    // was shown to the person as a failure.
    const http = fakeIdpFetch();
    const { state } = await beginRedirect({ discovery, redirectUri: "http://localhost:5173", planeUrl: "https://p", fetchImpl: http });
    const back = `http://localhost:5173/?code=strict-mode&state=${state}`;

    const [first, second] = await Promise.all([completeRedirect(back, http), completeRedirect(back, http)]);
    assert.equal(first?.tokens.refresh_token, "rt-1");
    assert.deepEqual(second, first, "the second caller was told a different story");
    assert.equal(http.seen.filter((r) => r.url === TOKEN).length, 1, "the code was redeemed twice");

    // And one that arrives afterwards is still told what happened, rather than that its
    // own successful sign-in never took place.
    assert.deepEqual(await completeRedirect(back, http), first);
    assert.equal(http.seen.filter((r) => r.url === TOKEN).length, 1);
  });

  it("lets a failed exchange be tried again", async () => {
    const http = fakeIdpFetch({ tokenStatus: 500, tokenBody: { error: "server_error" } });
    const { state } = await beginRedirect({ discovery, redirectUri: "http://localhost:5173", planeUrl: "https://p", fetchImpl: http });
    const back = `http://localhost:5173/?code=flaky&state=${state}`;

    await assert.rejects(() => completeRedirect(back, http), /server_error/);
    // The verifier is spent, so the retry fails for that reason rather than silently
    // handing back the first failure — what matters is that it is not memoised.
    await assert.rejects(() => completeRedirect(back, http), /did not start in this browser/);
  });

  it("refuses a state this tab did not send", async () => {
    const http = fakeIdpFetch();
    await beginRedirect({ discovery, redirectUri: "http://localhost:5173", planeUrl: "https://p", fetchImpl: http });
    await assert.rejects(
      () => completeRedirect("http://localhost:5173/?code=c&state=somebody-elses", http),
      /state this browser did not send/,
    );
    // And it is still spent, so a stolen code cannot be retried against a fresh state.
    assert.equal(storage.getItem("troupe.auth.pending"), null);
  });

  it("turns the provider's refusal into an error naming what to register", async () => {
    const http = fakeIdpFetch();
    const { state } = await beginRedirect({ discovery, redirectUri: "http://localhost:5173", planeUrl: "https://p", fetchImpl: http });
    const back = `http://localhost:5173/?error=invalid_request&error_description=AADSTS50011%3A%20The%20redirect%20URI%20is%20not%20registered&state=${state}`;
    await assert.rejects(() => completeRedirect(back, http), /AADSTS50011/);
  });

  it("is not confused by a URL that is not a sign-in coming back", async () => {
    assert.equal(hasRedirectAnswer("http://localhost:5173/"), false);
    assert.equal(hasRedirectAnswer("http://localhost:5173/?code=c"), false, "a code with no state is not an answer");
    assert.equal(await completeRedirect("http://localhost:5173/", fakeIdpFetch()), null);
  });

  it("reports a token endpoint that refuses rather than returning nothing", async () => {
    const http = fakeIdpFetch({ tokenStatus: 400, tokenBody: { error: "invalid_grant" } });
    const { state } = await beginRedirect({ discovery, redirectUri: "http://localhost:5173", planeUrl: "https://p", fetchImpl: http });
    await assert.rejects(() => completeRedirect(`http://localhost:5173/?code=c&state=${state}`, http), /invalid_grant/);
  });
});
